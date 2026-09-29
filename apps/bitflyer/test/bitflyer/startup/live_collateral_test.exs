defmodule Bitflyer.Startup.LiveCollateralTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Exchange.Rest.Decode
  alias Bitflyer.Startup.LiveCollateral

  test "empty account from 2026-09-29 does not halt" do
    assert {:ok, collateral} =
             Decode.collateral(%{
               "collateral" => 0,
               "open_position_pnl" => 0,
               "require_collateral" => 0,
               "keep_rate" => 0,
               "margin_call_amount" => 0,
               "margin_call_due_date" => nil
             })

    assert :ok = LiveCollateral.check(collateral)
    assert :ok = LiveCollateral.for_products(%{collateral: collateral}, ["FX_BTC_JPY"])
  end

  test "open FX position below keep rate halts" do
    collateral = sample(keep_rate: "0.5", require_collateral: "1000")

    assert {:error, :reconcile_mismatch, %{kind: :keep_rate_breached}} =
             LiveCollateral.check(collateral)
  end

  test "margin call halts even when keep rate is still high" do
    collateral = sample(keep_rate: "3", require_collateral: "1000", margin_call_amount: "10")

    assert {:error, :reconcile_mismatch, %{kind: :margin_call}} =
             LiveCollateral.check(collateral)
  end

  test "open FX position with zero required collateral halts" do
    collateral = sample([])

    assert {:error, :reconcile_mismatch, %{kind: :keep_rate_breached}} =
             LiveCollateral.check(collateral,
               positions: [%{product_code: "FX_BTC_JPY", size: Decimal.new("0.01")}]
             )
  end

  test "a spot long does not count as an FX position" do
    collateral = sample([])

    assert :ok =
             LiveCollateral.check(collateral,
               positions: [%{product_code: "BTC_JPY", size: Decimal.new("0.01")}]
             )
  end

  test "a high published keep rate still halts when equity is below the floor" do
    collateral =
      sample(
        collateral: "1000",
        open_position_pnl: "-500",
        require_collateral: "1000",
        keep_rate: "5"
      )

    assert {:error, :reconcile_mismatch, %{kind: :keep_rate_breached}} =
             LiveCollateral.check(collateral)
  end

  test "keep rate equal to the floor still halts" do
    collateral =
      sample(
        keep_rate: "1",
        require_collateral: "1000",
        collateral: "1000",
        open_position_pnl: "0"
      )

    assert {:error, :reconcile_mismatch, %{kind: :keep_rate_breached}} =
             LiveCollateral.check(collateral)
  end

  test "a due date with zero margin call amount halts" do
    collateral = Map.put(sample([]), :margin_call_due_date, "2026-09-29T00:00:00")

    assert {:error, :reconcile_mismatch, %{kind: :margin_call}} =
             LiveCollateral.check(collateral)
  end

  test "missing keys and a bad floor do not crash" do
    collateral = sample([])

    assert {:error, :reconcile_mismatch, %{kind: :collateral_missing}} =
             LiveCollateral.check(Map.delete(collateral, :keep_rate))

    assert {:error, :reconcile_mismatch, %{kind: :invalid_min_keep_rate}} =
             LiveCollateral.check(collateral, min_keep_rate: "nope")
  end

  test "negative required collateral is not a collateral row" do
    assert {:error, :invalid_number} =
             Decode.collateral(%{
               "collateral" => "1",
               "open_position_pnl" => "0",
               "require_collateral" => "-1",
               "keep_rate" => "1",
               "margin_call_amount" => "0"
             })
  end

  test "spot subscription does not require collateral" do
    assert :ok = LiveCollateral.for_products(%{}, ["BTC_JPY"])
  end

  test "FX subscription without a collateral map is missing" do
    assert {:error, :reconcile_mismatch, %{kind: :collateral_missing}} =
             LiveCollateral.for_products(%{}, ["FX_BTC_JPY"])
  end

  defp sample(overrides) do
    Map.merge(
      %{
        collateral: Decimal.new("100000"),
        open_position_pnl: Decimal.new("0"),
        require_collateral: Decimal.new("0"),
        keep_rate: Decimal.new("0"),
        margin_call_amount: Decimal.new("0"),
        margin_call_due_date: nil
      },
      Map.new(overrides, fn {key, value} -> {key, Decimal.new(value)} end)
    )
  end
end
