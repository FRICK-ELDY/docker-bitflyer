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

  test "live evidence is BTC_JPY even when other pairs are spot" do
    assert Product.live_evidenced?("BTC_JPY")
    assert Product.spot?("ETH_JPY")
    refute Product.live_evidenced?("ETH_JPY")
    refute Product.live_evidenced?("FX_BTC_JPY")
    assert Product.live_evidenced_products() == ["BTC_JPY"]
  end

  test "fee_currency is base for spot and quote for fx" do
    assert Product.fee_currency("BTC_JPY") == "BTC"
    assert Product.fee_currency("ETH_BTC") == "ETH"
    assert Product.fee_currency("FX_BTC_JPY") == "JPY"
  end
end
