defmodule Bitflyer.TestSupport.MissingIdStrategy do
  @moduledoc false
  @behaviour Bitflyer.Strategy

  @impl true
  def evaluate(market, _positions, _params) do
    [
      %{
        product_code: market.product_code,
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: market.market_key,
        order_type: :market
      }
    ]
  end
end
