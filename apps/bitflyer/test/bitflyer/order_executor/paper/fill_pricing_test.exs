defmodule Bitflyer.OrderExecutor.Paper.FillPricingTest do
  use ExUnit.Case, async: true

  alias Bitflyer.OrderExecutor.Paper.FillPricing

  test "bps zero keeps base price" do
    base = Decimal.new("5000000")

    assert {:ok, ^base} =
             FillPricing.effective_price(:buy, base, slippage_bps: 0, fee_bps: 0)

    assert {:ok, ^base} =
             FillPricing.effective_price(:sell, base, slippage_bps: 0, fee_bps: 0)
  end

  test "buy moves up and sell moves down" do
    base = Decimal.new("10000")

    assert {:ok, buy} =
             FillPricing.effective_price(:buy, base,
               slippage_bps: Decimal.new("10"),
               fee_bps: Decimal.new("0")
             )

    assert {:ok, sell} =
             FillPricing.effective_price(:sell, base,
               slippage_bps: Decimal.new("10"),
               fee_bps: Decimal.new("0")
             )

    assert Decimal.eq?(buy, Decimal.new("10010"))
    assert Decimal.eq?(sell, Decimal.new("9990"))
  end

  test "fee stacks after slippage in adverse direction" do
    base = Decimal.new("10000")

    assert {:ok, price} =
             FillPricing.effective_price(:buy, base,
               slippage_bps: Decimal.new("10"),
               fee_bps: Decimal.new("10")
             )

    assert Decimal.eq?(price, Decimal.new("10020.01"))
  end

  test "limit_fill_price applies fee only" do
    base = Decimal.new("10000")

    assert {:ok, price} =
             FillPricing.limit_fill_price(:buy, base,
               slippage_bps: Decimal.new("50"),
               fee_bps: Decimal.new("10")
             )

    assert Decimal.eq?(price, Decimal.new("10010"))
  end

  test "rejects non-positive base without raising" do
    assert {:error, :invalid_fill_pricing, %{reason: :non_positive_base}} =
             FillPricing.effective_price(:buy, Decimal.new("0"), fee_bps: 0, slippage_bps: 0)
  end

  test "rejects invalid and oversized bps instead of silent zero" do
    assert {:error, :invalid_fill_pricing, %{reason: :invalid_bps}} =
             FillPricing.effective_price(:buy, Decimal.new("100"),
               slippage_bps: "nope",
               fee_bps: 0
             )

    assert {:error, :invalid_fill_pricing, %{reason: :bps_too_large}} =
             FillPricing.effective_price(:sell, Decimal.new("100"),
               slippage_bps: 0,
               fee_bps: 10_000
             )
  end
end
