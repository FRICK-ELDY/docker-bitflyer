defmodule Bitflyer.Strategy.FixedOnceTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Strategy.FixedOnce

  @market %{
    product_code: "FX_BTC_JPY",
    market_key: {:ticker, "FX_BTC_JPY"},
    ltp: Decimal.new("5000000")
  }

  test "evaluate returns one market buy with stable idempotent id" do
    assert [command] = FixedOnce.evaluate(@market, [], %{size: "0.01", side: :buy})

    assert command.internal_order_id == "strategy-fixed-once-FX_BTC_JPY"
    assert command.product_code == "FX_BTC_JPY"
    assert command.side == :buy
    assert command.order_type == :market
    assert Decimal.eq?(command.size, Decimal.new("0.01"))
    assert command.market_key == {:ticker, "FX_BTC_JPY"}
  end

  test "evaluate is pure and repeats the same intent" do
    assert FixedOnce.evaluate(@market, [], %{}) == FixedOnce.evaluate(@market, [], %{})
  end
end
