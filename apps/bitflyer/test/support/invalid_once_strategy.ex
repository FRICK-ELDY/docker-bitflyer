defmodule Bitflyer.TestSupport.InvalidOnceStrategy do
  @moduledoc false
  @behaviour Bitflyer.Strategy

  @impl true
  def evaluate(market, _positions, _params) do
    [
      %{
        internal_order_id: "strategy-invalid-once-#{market.product_code}",
        product_code: market.product_code,
        side: :buy,
        size: Decimal.new("-1"),
        market_key: market.market_key,
        order_type: :market
      }
    ]
  end
end
