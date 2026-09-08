defmodule Bitflyer.OrderExecutor.DryRun do
  @moduledoc false

  alias Bitflyer.Trading.Order

  @doc """
  取引所へ送らず、擬似約定もしない。pending のまま返す。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, _command, _opts) do
    Bitflyer.Telemetry.log(
      :info,
      "dry_run order recorded (not sent, not filled)",
      %{
        internal_order_id: order.internal_order_id,
        product_code: order.product_code,
        side: order.side,
        trade_mode: :dry_run
      }
    )

    {:ok, order}
  end
end
