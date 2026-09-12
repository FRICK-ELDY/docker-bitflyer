defmodule Bitflyer.Startup.LiveInventoryTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Startup.LiveInventory

  @tol %{"BTC" => "0.00000001"}

  test "no position with leftover exchange coins is ok" do
    assert :ok =
             LiveInventory.compare([], [], [btc("0.5")], position_size_tolerance_abs: @tol)
  end

  test "spot short position is position_mismatch after flip" do
    assert {:error, :reconcile_mismatch,
            %{kind: :position_mismatch, reason: :spot_short_position, currency: "BTC"}} =
             LiveInventory.compare(
               [%{product_code: "BTC_JPY", side: :sell, size: Decimal.new("0.01")}],
               [],
               [btc("0.49")],
               position_size_tolerance_abs: @tol
             )
  end

  test "buy position within exchange amount is ok" do
    assert :ok =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.01")],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "buy position matching amount is ok" do
    assert :ok =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.5")],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "available hold does not affect amount compare" do
    assert :ok =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.5")],
               [sell_open("BTC_JPY", "0.2")],
               [btc("0.5", "0.3")],
               position_size_tolerance_abs: @tol
             )
  end

  test "inflated position is position_mismatch" do
    assert {:error, :reconcile_mismatch,
            %{kind: :position_mismatch, reason: :spot_inventory_inflated, currency: "BTC"}} =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.6")],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "open sell larger than buy position is position_mismatch" do
    assert {:error, :reconcile_mismatch,
            %{kind: :position_mismatch, reason: :spot_sell_exceeds_position, currency: "BTC"}} =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.1")],
               [sell_open("BTC_JPY", "0.2")],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "dust over amount is absorbed by abs floor" do
    assert :ok =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.50000001")],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "fx position is ignored" do
    assert :ok =
             LiveInventory.compare(
               [
                 %{
                   product_code: "FX_BTC_JPY",
                   side: :buy,
                   size: Decimal.new("1")
                 }
               ],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "missing balance row treats amount as zero" do
    assert {:error, :reconcile_mismatch, %{reason: :spot_inventory_inflated, currency: "BTC"}} =
             LiveInventory.compare([buy("BTC_JPY", "0.01")], [], [],
               position_size_tolerance_abs: @tol
             )
  end

  test "sums buy positions that share a base" do
    assert {:error, :reconcile_mismatch, %{reason: :spot_inventory_inflated}} =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.4"), buy("BTC_JPY", "0.2")],
               [],
               [btc("0.5")],
               position_size_tolerance_abs: @tol
             )
  end

  test "string-key balance row is accepted" do
    amount = Decimal.new("0.5")

    assert :ok =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.5")],
               [],
               [%{"currency" => "BTC", "amount" => amount, "available" => amount}],
               position_size_tolerance_abs: @tol
             )
  end

  test "non-decimal amount is position_mismatch" do
    assert {:error, :reconcile_mismatch, %{reason: :invalid_balance_amount, currency: "BTC"}} =
             LiveInventory.compare(
               [buy("BTC_JPY", "0.01")],
               [],
               [%{currency: "BTC", amount: "0.5"}],
               position_size_tolerance_abs: @tol
             )
  end

  defp buy(product_code, size) do
    %{product_code: product_code, side: :buy, size: Decimal.new(size)}
  end

  defp sell_open(product_code, size) do
    %{
      product_code: product_code,
      side: :sell,
      size: Decimal.new(size),
      filled_size: Decimal.new(0)
    }
  end

  defp btc(amount, available \\ nil) do
    amount = Decimal.new(amount)
    %{currency: "BTC", amount: amount, available: Decimal.new(available || amount)}
  end
end
