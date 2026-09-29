defmodule Bitflyer.Trading.ProductTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Trading.Product

  test "market_type classifies spot fx and unsupported" do
    assert Product.market_type("BTC_JPY") == :spot
    assert Product.market_type("ETH_BTC") == :spot
    assert Product.market_type("FX_BTC_JPY") == :fx
    assert Product.market_type("BTCJPY24MAR") == :unsupported
    # allowlist 外の BASE_QUOTE は spot にしない
    assert Product.market_type("FOO_BAR") == :unsupported
  end

  test "spot? and fx? predicates" do
    assert Product.spot?("BTC_JPY")
    refute Product.spot?("FX_BTC_JPY")
    assert Product.fx?("FX_BTC_JPY")
    refute Product.fx?("BTC_JPY")
  end

  test "live evidence is BTC_JPY and ETH_JPY" do
    assert Product.live_evidenced?("BTC_JPY")
    assert Product.live_evidenced?("ETH_JPY")
    refute Product.live_evidenced?("XRP_JPY")
    refute Product.live_evidenced?("FX_BTC_JPY")
    assert Product.live_evidenced_products() == ["BTC_JPY", "ETH_JPY"]
  end

  test "ETH_JPY order size uses 0.0000001 and rejects a finer size" do
    assert Product.check_order_size("ETH_JPY", Decimal.new("0.0100099")) == :ok

    assert Product.check_order_size("ETH_JPY", Decimal.new("0.01000992")) ==
             {:error, :off_order_step}

    assert Product.check_order_size("ETH_JPY", Decimal.new("0.0099999")) ==
             {:error, :below_min_order_size}
  end

  test "align_order_size floors ETH_JPY to 0.0000001 and refuses below the minimum" do
    assert Product.align_order_size("ETH_JPY", Decimal.new("0.01000992")) ==
             {:ok, Decimal.new("0.0100099")}

    receipt = Decimal.new("0.01002494")
    raw_sell = Decimal.div(receipt, Decimal.new("1.0015"))

    assert Product.align_order_size("ETH_JPY", raw_sell) == {:ok, Decimal.new("0.0100099")}

    assert Product.align_order_size("ETH_JPY", Decimal.new("0.00999999")) ==
             {:error, :below_min_order_size}

    assert {:ok, sell} = Product.sellable_size("ETH_JPY", Decimal.new("0.01002494"))
    assert Decimal.equal?(sell, Decimal.new("0.0100099"))

    assert Product.ensure_buy_can_flatten("ETH_JPY", :buy, Decimal.new("0.01")) ==
             {:error, :below_min_order_size}

    assert Product.ensure_buy_can_flatten("ETH_JPY", :buy, Decimal.new("0.0100301")) == :ok
    assert Product.ensure_buy_can_flatten("ETH_JPY", :sell, Decimal.new("0.0100099")) == :ok

    assert Product.ensure_buy_can_flatten("ETH_JPY", :buy, Decimal.new("0.0100300")) ==
             {:error, :below_min_order_size}

    held_at_min =
      Decimal.mult(Decimal.new("0.0100301"), Decimal.sub(Decimal.new("1"), Decimal.new("0.0015")))

    assert {:ok, sell_at_min} = Product.sellable_size("ETH_JPY", held_at_min)
    assert Decimal.compare(sell_at_min, Decimal.new("0.01")) != :lt

    held_below =
      Decimal.mult(Decimal.new("0.0100300"), Decimal.sub(Decimal.new("1"), Decimal.new("0.0015")))

    assert Product.sellable_size("ETH_JPY", held_below) == {:error, :below_min_order_size}
  end

  test "BTC_JPY sizes are not stepped until a rejection unit is measured" do
    assert Product.check_order_size("BTC_JPY", Decimal.new("0.00101151")) == :ok
    assert Product.check_order_size("BTC_JPY", Decimal.new("0.00100848")) == :ok

    assert Product.align_order_size("BTC_JPY", Decimal.new("0.001")) ==
             {:error, :order_grid_missing}
  end

  test "a spot pair without a measured grid is not aligned" do
    assert Product.check_order_size("XRP_JPY", Decimal.new("1")) == :ok
    assert Product.align_order_size("XRP_JPY", Decimal.new("1")) == {:error, :order_grid_missing}
  end

  test "fee_currency is base for spot and quote for fx" do
    assert Product.fee_currency("BTC_JPY") == "BTC"
    assert Product.fee_currency("ETH_BTC") == "ETH"
    assert Product.fee_currency("FX_BTC_JPY") == "JPY"
  end
end
