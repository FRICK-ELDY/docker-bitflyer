defmodule Bitflyer.OrderExecutor.LiveFills do
  @moduledoc """
  live 注文の約定を取引所照会から内部建玉へ反映する。

  - 建玉: `Positions.apply_fill` で差分反映（Risk が DB Position を見るため必須）
  - 残高: **触らない**。live の残高正本は `getbalance` 突合（紙の `Balances.apply_fill` は FX と矛盾する）
  - 発注認可前・発注後・取消後・定期突合前に呼ぶ
  """

  require Ash.Query

  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Trading.Order

  @doc """
  `pending` / `partially_filled` の live 注文を取引所状態に合わせて進める。

  ## Options
  - `:exchange` — 既定 `Bitflyer.Exchange`
  """
  @spec sync_open_orders(keyword()) :: :ok | {:error, atom(), map()}
  def sync_open_orders(opts \\ []) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    case list_open_live_orders() do
      {:ok, orders} ->
        Enum.reduce_while(orders, :ok, fn order, :ok ->
          case sync_order(order, exchange: exchange) do
            :ok -> {:cont, :ok}
            {:ok, _} -> {:cont, :ok}
            {:error, _, _} = error -> {:halt, error}
          end
        end)

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  @doc """
  1 注文を取引所状態へ寄せる。取消直後の fill 回収にも使う。
  """
  @spec sync_order(Order.t(), keyword()) :: :ok | {:ok, Order.t()} | {:error, atom(), map()}
  def sync_order(%Order{} = order, opts \\ []) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    if order.trade_mode != :live or is_nil(order.exchange_order_id) do
      :ok
    else
      do_sync(order, exchange)
    end
  end

  defp list_open_live_orders do
    Order
    |> Ash.Query.filter(
      trade_mode == :live and status in [:pending, :partially_filled] and
        not is_nil(exchange_order_id)
    )
    |> Ash.read()
  end

  defp do_sync(%Order{} = order, exchange) do
    request = %{
      product_code: order.product_code,
      exchange_order_id: order.exchange_order_id
    }

    case exchange.fetch_order(request) do
      {:ok, info} ->
        apply_order_info(order, info, exchange)

      {:error, :order_not_found} ->
        recover_missing_order(order, exchange)

      {:error, reason} ->
        {:error, :exchange_error, %{reason: reason, internal_order_id: order.internal_order_id}}
    end
  end

  # getchildorders に出ない（未約定取消・窓外など）。約定があれば載せてから終端化する。
  defp recover_missing_order(%Order{} = order, exchange) do
    Bitflyer.Telemetry.log(
      :warning,
      "live order not found on exchange; recovering via executions",
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        product_code: order.product_code,
        trade_mode: :live
      }
    )

    case exchange.fetch_executions(%{
           product_code: order.product_code,
           exchange_order_id: order.exchange_order_id
         }) do
      {:ok, executions} ->
        remote_filled =
          Enum.reduce(executions, Decimal.new("0"), fn exec, acc ->
            Decimal.add(acc, exec.size)
          end)

        local_filled = order.filled_size || Decimal.new("0")
        delta = Decimal.sub(remote_filled, local_filled)

        info = %{
          exchange_order_id: order.exchange_order_id,
          product_code: order.product_code,
          side: order.side,
          size: order.size,
          filled_size: remote_filled,
          average_price: average_price_from_executions(executions),
          # 一覧に無い = 板から消えている。fill 後は cancelled（全量なら filled）
          status: :canceled
        }

        cond do
          Decimal.compare(delta, 0) == :gt ->
            reflect_fill(order, info, delta, exchange)

          Decimal.compare(remote_filled, 0) == :gt ->
            # 既にローカルへ載せ済み。終端化のみ
            terminal =
              if Decimal.compare(remote_filled, order.size) != :lt,
                do: :filled,
                else: :cancelled

            mark_terminal(order, terminal, remote_filled)

          true ->
            # 約定なしで消えた → 未約定取消扱い
            mark_terminal(order, :cancelled, local_filled)
        end

      {:error, reason} ->
        # 照会不能は fail-closed（黙って open のままにしない）
        {:error, :exchange_error,
         %{
           reason: reason,
           internal_order_id: order.internal_order_id,
           cause: :order_not_found_recovery_failed
         }}
    end
  end

  defp average_price_from_executions([]), do: nil

  defp average_price_from_executions(executions) do
    case avg_from_executions(executions) do
      {:ok, price} -> price
      _ -> nil
    end
  end

  defp apply_order_info(%Order{} = order, info, exchange) do
    remote_filled = info.filled_size
    local_filled = order.filled_size || Decimal.new("0")
    delta = Decimal.sub(remote_filled, local_filled)

    cond do
      Decimal.compare(delta, 0) == :gt ->
        reflect_fill(order, info, delta, exchange)

      info.status in [:canceled, :expired, :rejected] ->
        mark_terminal(order, map_terminal_status(info.status), remote_filled)

      info.status == :completed and order.status != :filled ->
        mark_terminal(order, :filled, remote_filled)

      true ->
        :ok
    end
  end

  defp reflect_fill(%Order{} = order, info, delta, exchange) do
    case fill_price(order, info, exchange) do
      {:ok, price} ->
        apply_fill_transaction(order, info, delta, price)

      {:error, _, _} = error ->
        error
    end
  end

  defp fill_price(%Order{} = order, info, exchange) do
    cond do
      match?(%Decimal{}, info.average_price) and Decimal.positive?(info.average_price) ->
        {:ok, info.average_price}

      true ->
        case exchange.fetch_executions(%{
               product_code: order.product_code,
               exchange_order_id: order.exchange_order_id
             }) do
          {:ok, executions} ->
            avg_from_executions(executions)

          {:error, reason} ->
            {:error, :exchange_error, %{reason: reason}}
        end
    end
  end

  defp avg_from_executions([]), do: {:error, :fill_price_unavailable, %{}}

  defp avg_from_executions(executions) do
    {notional, size} =
      Enum.reduce(executions, {Decimal.new("0"), Decimal.new("0")}, fn exec, {n, s} ->
        {Decimal.add(n, Decimal.mult(exec.price, exec.size)), Decimal.add(s, exec.size)}
      end)

    if Decimal.equal?(size, Decimal.new("0")) do
      {:error, :fill_price_unavailable, %{}}
    else
      {:ok, Decimal.div(notional, size)}
    end
  end

  defp apply_fill_transaction(%Order{} = order, info, delta, fill_price) do
    new_filled = Decimal.add(order.filled_size || Decimal.new("0"), delta)
    status = status_after_fill(order.size, new_filled, info.status)

    # 差分サイズだけ建玉へ。残高は live では更新しない（getbalance 突合が正本）
    delta_order = %{order | size: delta, filled_size: delta}

    Bitflyer.OrderExecutor.DailyLossSync.around_fill(:live, fn ->
      case Bitflyer.Repo.transaction(fn ->
             with {:ok, updated, order_notifications} <-
                    update_order(order, %{status: status, filled_size: new_filled}),
                  {:ok, position_notifications, _fill_meta} <-
                    Positions.apply_fill(delta_order, fill_price) do
               {updated, order_notifications ++ position_notifications}
             else
               {:error, code, meta} when is_atom(code) and is_map(meta) ->
                 Bitflyer.Repo.rollback({code, meta})

               other ->
                 Bitflyer.Repo.rollback(other)
             end
           end) do
        {:ok, {updated, notifications}} ->
          _ = Ash.Notifier.notify(notifications)

          Bitflyer.Telemetry.execute(
            :order_filled,
            %{count: 1},
            %{
              internal_order_id: updated.internal_order_id,
              exchange_order_id: updated.exchange_order_id,
              product_code: updated.product_code,
              side: updated.side,
              trade_mode: :live,
              status: updated.status
            }
          )

          {:ok, updated}

        {:error, {code, meta}} when is_atom(code) and is_map(meta) ->
          {:error, code, meta}

        {:error, error} ->
          {:error, :persist_failed, %{error: error}}
      end
    end)
  end

  defp status_after_fill(order_size, filled_size, remote_status) do
    cond do
      remote_status in [:canceled, :expired, :rejected] ->
        # 取消・失効後に未反映 fill を載せた場合は open に残さない
        if Decimal.compare(filled_size, order_size) != :lt,
          do: :filled,
          else: map_terminal_status(remote_status)

      remote_status == :completed ->
        :filled

      Decimal.compare(filled_size, order_size) != :lt ->
        :filled

      true ->
        :partially_filled
    end
  end

  defp map_terminal_status(:canceled), do: :cancelled
  defp map_terminal_status(:expired), do: :expired
  defp map_terminal_status(:rejected), do: :rejected
  defp map_terminal_status(_), do: :cancelled

  defp mark_terminal(%Order{} = order, status, filled_size) do
    case update_order(order, %{status: status, filled_size: filled_size}) do
      {:ok, updated, notifications} ->
        _ = Ash.Notifier.notify(notifications)
        {:ok, updated}

      {:error, _, _} = error ->
        error
    end
  end

  defp update_order(%Order{} = order, attrs) do
    case order
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(return_notifications?: true) do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end
end
