defmodule Bitflyer.Strategy.FixedOnceTest do
  use ExUnit.Case, async: false

  alias Bitflyer.Strategy.FixedOnce

  @market %{
    product_code: "FX_BTC_JPY",
    market_key: {:ticker, "FX_BTC_JPY"},
    ltp: Decimal.new("5000000")
  }

  setup do
    previous = Application.get_env(:bitflyer, :trade_mode)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
    end)

    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    :ok
  end

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

  test "evaluate accepts float size via Decimal.from_float" do
    assert [command] = FixedOnce.evaluate(@market, [], %{size: 0.05})
    assert Decimal.eq?(command.size, Decimal.from_float(0.05))
  end

  test "evaluate returns no commands when trade_mode is live" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    assert FixedOnce.evaluate(@market, [], %{size: "0.01", side: :buy}) == []
  end
end
