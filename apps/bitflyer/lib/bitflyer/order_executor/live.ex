defmodule Bitflyer.OrderExecutor.Live do
  @moduledoc false

  alias Bitflyer.Trading.Order

  @doc """
  `exchange_order_gate` 通過時のみ取引所 REST へ発注する。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, _command, _opts) do
    case Bitflyer.TradeMode.exchange_order_gate() do
      :ok ->
        place(order)

      {:halted, reason} ->
        _ = reject(order, reason)
        {:error, :exchange_halted, %{reason: reason}}
    end
  end

  defp place(%Order{} = order) do
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
        case order
             |> Ash.Changeset.for_update(:update, %{exchange_order_id: exchange_order_id})
             |> Ash.update() do
          {:ok, updated} ->
            {:ok, updated}

          {:error, error} ->
            # 取引所では受注済みなのに ID を見失うと照合不能になる
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

            {:error, :persist_failed,
             %{
               error: error,
               internal_order_id: order.internal_order_id,
               exchange_order_id: exchange_order_id
             }}
        end

      {:error, reason} ->
        _ = reject(order, reason)
        {:error, :exchange_error, %{reason: reason}}
    end
  end

  defp reject(%Order{} = order, reason) do
    case order
         |> Ash.Changeset.for_update(:update, %{status: :rejected})
         |> Ash.update() do
      {:ok, updated} ->
        Bitflyer.Telemetry.log(
          :warning,
          "live order rejected",
          %{
            internal_order_id: order.internal_order_id,
            product_code: order.product_code,
            side: order.side,
            trade_mode: :live,
            reason: reason,
            status: :rejected
          }
        )

        {:ok, updated}

      {:error, error} ->
        {:error, error}
    end
  end
end
