defmodule Bitflyer.OrderExecutor.Live do
  @moduledoc false

  alias Bitflyer.Trading.Order

  # 取引所に注文が存在しないと確定できる理由のみ。それ以外は提出不明として扱う。
  @definite_rejection_reasons [
    :exchange_unavailable,
    :rejected_by_exchange,
    :insufficient_funds,
    :invalid_order,
    :invalid_request,
    :rate_limited,
    :auth_failed
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
            # 成行即時約定などを取り込む。失敗は成功と分け、halt して盲目継続しない。
            case sync_fills_after_place(updated, opts) do
              :ok ->
                {:ok, updated}

              {:error, reason, meta} ->
                # 取引所は受注済み。成功と分離し halt。呼び出し元は meta.order_accepted を見る。
                _ =
                  open_circuit_or_log!(:fill_sync_failed, %{
                    internal_order_id: updated.internal_order_id,
                    exchange_order_id: updated.exchange_order_id,
                    product_code: updated.product_code,
                    side: updated.side,
                    sync_error: reason
                  })

                {:error, :fill_sync_failed,
                 Map.merge(meta || %{}, %{
                   reason: reason,
                   internal_order_id: updated.internal_order_id,
                   exchange_order_id: updated.exchange_order_id,
                   order_accepted: true
                 })}
            end

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

  defp sync_fills_after_place(%Order{} = order, opts) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    case Bitflyer.OrderExecutor.LiveFills.sync_order(order, exchange: exchange) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason, meta} ->
        Bitflyer.Telemetry.log(
          :error,
          "live fill sync after place_order failed; halting",
          Map.merge(
            %{
              internal_order_id: order.internal_order_id,
              exchange_order_id: order.exchange_order_id,
              trade_mode: :live
            },
            meta || %{}
          )
        )

        {:error, reason, meta}
    end
  end

  defp persist_exchange_order_id(%Order{} = order, exchange_order_id, opts) do
    case Keyword.get(opts, :persist_exchange_order_id) do
      fun when is_function(fun, 2) ->
        fun.(order, exchange_order_id)

      _ ->
        case reload_order(order) do
          {:ok, %Order{} = current} ->
            attrs = persist_attrs(current, exchange_order_id)

            case current
                 |> Ash.Changeset.for_update(:update, attrs)
                 |> Ash.update() do
              {:ok, _updated} = ok ->
                if current.status == :submission_unknown do
                  Bitflyer.Telemetry.log(
                    :warning,
                    "live order recovered from submission_unknown after place_order id persist",
                    %{
                      internal_order_id: current.internal_order_id,
                      exchange_order_id: exchange_order_id,
                      product_code: current.product_code,
                      side: current.side,
                      trade_mode: :live,
                      status: :pending
                    }
                  )
                end

                ok

              {:error, _} = error ->
                error
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  # place 成功で ID を埋めるときは status も pending に揃える。
  # reload 後〜update 前に drain が unknown 化しても、unknown+ID にならないようにする。
  defp persist_attrs(%Order{status: status}, exchange_order_id)
       when status in [:filled, :partially_filled, :cancelled, :rejected, :expired] do
    %{exchange_order_id: exchange_order_id}
  end

  defp persist_attrs(_order, exchange_order_id) do
    %{exchange_order_id: exchange_order_id, status: :pending}
  end

  defp reload_order(%Order{} = order) do
    case Ash.get(Order, order.id) do
      {:ok, %Order{} = current} -> {:ok, current}
      {:error, error} -> {:error, error}
    end
  end

  defp handle_place_error(%Order{} = order, reason) do
    if definite_rejection?(reason) do
      _ = update_status(order, :rejected, reason)
      _ = maybe_open_failure_circuit(reason, order)
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

  defp maybe_open_failure_circuit(reason, %Order{} = order) do
    case Bitflyer.Risk.FailureRate.evaluate(reason, trade_mode: order.trade_mode) do
      :ok ->
        :ok

      {:halt, halt_reason} ->
        open_circuit_or_log!(halt_reason, %{
          internal_order_id: order.internal_order_id,
          product_code: order.product_code,
          side: order.side,
          place_error: reason
        })
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
