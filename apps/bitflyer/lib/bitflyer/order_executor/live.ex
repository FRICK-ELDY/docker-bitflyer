defmodule Bitflyer.OrderExecutor.Live do
  @moduledoc false

  alias Bitflyer.Trading.Order

  # 取引所に注文が存在しないと確定できる理由のみ。それ以外は提出不明として扱う。
  @definite_rejection_reasons [
    :exchange_unavailable,
    :rejected_by_exchange,
    :insufficient_funds,
    :invalid_order,
    :invalid_request
  ]

  @doc """
  `exchange_order_gate` 通過時のみ取引所 REST へ発注する。

  ## Options
  - `:persist_exchange_order_id` — `(Order.t(), String.t() -> {:ok, Order.t()} | {:error, term()})`。
    テスト用。未指定時は Ash で `exchange_order_id` を更新する。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, _command, opts) do
    case Bitflyer.TradeMode.exchange_order_gate() do
      :ok ->
        place(order, opts)

      {:halted, reason} ->
        # REST 前のゲート失敗は未送信のため確定拒否でよい
        _ = update_status(order, :rejected, reason)
        {:error, :exchange_halted, %{reason: reason}}
    end
  end

  defp place(%Order{} = order, opts) do
    request = %{
      product_code: order.product_code,
      side: order.side,
      size: order.size,
      order_type: order.order_type,
      price: order.price,
      internal_order_id: order.internal_order_id
    }

    case Bitflyer.Exchange.place_order(request) do
      {:ok, %{exchange_order_id: exchange_order_id}} ->
        case persist_exchange_order_id(order, exchange_order_id, opts) do
          {:ok, updated} ->
            {:ok, updated}

          {:error, error} ->
            # 取引所では受注済みなのに ID を見失うと照合不能になる。
            # 再送・追加発注を止め、起動突合で回収するまで Ready にしない。
            Bitflyer.Telemetry.log(
              :critical,
              "Failed to persist exchange_order_id after successful place_order: #{inspect(error)}",
              %{
                internal_order_id: order.internal_order_id,
                exchange_order_id: exchange_order_id,
                product_code: order.product_code,
                side: order.side,
                trade_mode: :live,
                status: order.status
              }
            )

            _ =
              open_circuit_or_log!(:persist_failed, %{
                internal_order_id: order.internal_order_id,
                exchange_order_id: exchange_order_id,
                product_code: order.product_code,
                side: order.side
              })

            {:error, :persist_failed,
             %{
               error: error,
               internal_order_id: order.internal_order_id,
               exchange_order_id: exchange_order_id
             }}
        end

      {:error, reason} ->
        handle_place_error(order, reason)
    end
  end

  defp persist_exchange_order_id(%Order{} = order, exchange_order_id, opts) do
    case Keyword.get(opts, :persist_exchange_order_id) do
      fun when is_function(fun, 2) ->
        fun.(order, exchange_order_id)

      _ ->
        order
        |> Ash.Changeset.for_update(:update, %{exchange_order_id: exchange_order_id})
        |> Ash.update()
    end
  end

  defp handle_place_error(%Order{} = order, reason) do
    if definite_rejection?(reason) do
      _ = update_status(order, :rejected, reason)
      {:error, :exchange_error, %{reason: reason}}
    else
      # timeout / 切断等: 受注不明。rejected にせず halt して再送を止める
      _ = update_status(order, :submission_unknown, reason)

      _ =
        open_circuit_or_log!(:submission_unknown, %{
          internal_order_id: order.internal_order_id,
          product_code: order.product_code,
          side: order.side,
          place_error: reason
        })

      {:error, :submission_unknown, %{reason: reason}}
    end
  end

  # Circuit.open は常に先に Readiness.halt する。{:error, _} は RiskState 永続化失敗のみ。
  # 稼働中の発注ゲートは閉じているが、再起動後に halt が消える危険があるため critical を残す。
  defp open_circuit_or_log!(reason, meta) when is_atom(reason) and is_map(meta) do
    case Bitflyer.Risk.open_circuit(reason) do
      :ok ->
        :ok

      {:error, open_error} ->
        Bitflyer.Telemetry.log(
          :critical,
          "Failed to persist risk circuit after #{reason}: #{inspect(open_error)}",
          # 関数固有キーを後勝ちにし、meta による上書きを防ぐ
          Map.merge(
            meta,
            %{
              reason: reason,
              open_error: open_error,
              trade_mode: :live
            }
          )
        )

        {:error, open_error}
    end
  end

  defp definite_rejection?(reason) when is_atom(reason) do
    reason in @definite_rejection_reasons
  end

  defp definite_rejection?(_reason), do: false

  defp update_status(%Order{} = order, status, reason)
       when status in [:rejected, :submission_unknown] do
    case order
         |> Ash.Changeset.for_update(:update, %{status: status})
         |> Ash.update() do
      {:ok, updated} ->
        level = if status == :submission_unknown, do: :critical, else: :warning

        Bitflyer.Telemetry.log(
          level,
          "live order #{status}",
          %{
            internal_order_id: order.internal_order_id,
            product_code: order.product_code,
            side: order.side,
            trade_mode: :live,
            reason: reason,
            status: status
          }
        )

        {:ok, updated}

      {:error, error} ->
        {:error, error}
    end
  end
end
