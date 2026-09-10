defmodule Bitflyer.OrderExecutor.Live.Cancel do
  @moduledoc false

  alias Bitflyer.OrderExecutor.LiveFills
  alias Bitflyer.Trading.Order

  @definite_rejection_reasons [
    :exchange_unavailable,
    :rejected_by_exchange,
    :insufficient_funds,
    :invalid_order,
    :invalid_request,
    :rate_limited,
    :auth_failed,
    :order_not_found
  ]

  @doc """
  live 取消。発注ゲートが閉じていてもエクスポージャ削減のため REST 取消は許可する。
  取消成功後に fill 同期してから終端化する（部分約定の取りこぼし防止）。
  """
  @spec execute(Order.t(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, opts) do
    do_cancel(order, opts)
  end

  defp do_cancel(%Order{exchange_order_id: nil} = order, _opts) do
    mark_cancelled(order)
  end

  defp do_cancel(%Order{} = order, opts) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    request = %{
      product_code: order.product_code,
      exchange_order_id: order.exchange_order_id
    }

    case exchange.cancel_order(request) do
      :ok ->
        finalize_after_cancel(order, exchange)

      {:error, reason} ->
        if reason in @definite_rejection_reasons do
          _ = maybe_open_failure_circuit(reason, order)
          {:error, :exchange_error, %{reason: reason}}
        else
          Bitflyer.Telemetry.log(
            :critical,
            "live cancel result unknown",
            %{
              internal_order_id: order.internal_order_id,
              exchange_order_id: order.exchange_order_id,
              product_code: order.product_code,
              reason: reason,
              trade_mode: :live
            }
          )

          _ = Bitflyer.Risk.open_circuit(:submission_unknown)
          {:error, :submission_unknown, %{reason: reason}}
        end
    end
  end

  defp maybe_open_failure_circuit(reason, %Order{} = order) do
    case Bitflyer.Risk.FailureRate.evaluate(reason, trade_mode: order.trade_mode) do
      :ok ->
        :ok

      {:halt, halt_reason} ->
        case Bitflyer.Risk.open_circuit(halt_reason) do
          :ok ->
            :ok

          {:error, open_error} ->
            Bitflyer.Telemetry.log(
              :critical,
              "Failed to persist risk circuit after #{halt_reason}: #{inspect(open_error)}",
              %{
                internal_order_id: order.internal_order_id,
                exchange_order_id: order.exchange_order_id,
                product_code: order.product_code,
                reason: halt_reason,
                cancel_error: reason,
                open_error: open_error,
                trade_mode: order.trade_mode
              }
            )

            {:error, open_error}
        end
    end
  end

  # 取消 REST 成功後: 先に取引所の fill/状態を取り込む。
  # まだ open の場合は即 cancelled に落とさず、後続同期で遅延約定を回収できるように維持する。
  defp finalize_after_cancel(%Order{} = order, exchange) do
    case LiveFills.sync_order(order, exchange: exchange) do
      {:ok, %Order{} = updated} ->
        maybe_log_pending_after_cancel(updated)
        {:ok, updated}

      :ok ->
        # sync が何もしなかった場合も即終端化しない（cancel受付直後レースを考慮）
        case reload(order) do
          {:ok, %Order{} = current} ->
            maybe_log_pending_after_cancel(current)
            {:ok, current}

          {:error, _, _} = error ->
            error
        end

      {:error, _, _} = error ->
        error
    end
  end

  defp maybe_log_pending_after_cancel(%Order{} = order) do
    if order.status in [:pending, :partially_filled] do
      Bitflyer.Telemetry.log(
        :warning,
        "live cancel accepted; order remains open until terminal state is observed",
        %{
          internal_order_id: order.internal_order_id,
          exchange_order_id: order.exchange_order_id,
          product_code: order.product_code,
          status: order.status,
          trade_mode: :live
        }
      )
    end
  end

  defp reload(%Order{} = order) do
    case Ash.get(Order, order.id) do
      {:ok, %Order{} = current} -> {:ok, current}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp mark_cancelled(%Order{} = order) do
    case order
         |> Ash.Changeset.for_update(:update, %{status: :cancelled})
         |> Ash.update() do
      {:ok, updated} ->
        Bitflyer.Telemetry.log(
          :info,
          "live order cancelled",
          %{
            internal_order_id: order.internal_order_id,
            exchange_order_id: order.exchange_order_id,
            product_code: order.product_code,
            trade_mode: :live,
            status: :cancelled
          }
        )

        {:ok, updated}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end
end
