defmodule Bitflyer.Trading.ResourcesTest do
  use Bitflyer.DataCase, async: true

  alias Bitflyer.Trading
  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position, RiskState}

  describe "Order" do
    test "creates with decimal size/price and unique internal_order_id" do
      assert {:ok, order} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-001",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run
               })
               |> Ash.create()

      assert order.internal_order_id == "ord-001"
      assert order.status == :pending
      assert Decimal.eq?(order.price, Decimal.new("5000000"))
      assert Decimal.eq?(order.size, Decimal.new("0.01"))
      assert Decimal.eq?(order.filled_size, Decimal.new("0"))

      assert {:error, %Ash.Error.Invalid{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-001",
                 product_code: "FX_BTC_JPY",
                 side: :sell,
                 size: Decimal.new("0.02"),
                 trade_mode: :paper
               })
               |> Ash.create()
    end
  end

  describe "Position" do
    test "uniqueness is per product_code and trade_mode; update is size/average_price only" do
      assert {:ok, paper} =
               Position
               |> Ash.Changeset.for_create(:create, %{
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 size: Decimal.new("0.05"),
                 average_price: Decimal.new("4800000"),
                 trade_mode: :paper
               })
               |> Ash.create()

      assert Decimal.eq?(paper.size, Decimal.new("0.05"))
      assert Decimal.eq?(paper.average_price, Decimal.new("4800000"))

      assert {:ok, _live} =
               Position
               |> Ash.Changeset.for_create(:create, %{
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 size: Decimal.new("0.01"),
                 average_price: Decimal.new("4900000"),
                 trade_mode: :live
               })
               |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} =
               Position
               |> Ash.Changeset.for_create(:create, %{
                 product_code: "FX_BTC_JPY",
                 side: :sell,
                 size: Decimal.new("0.02"),
                 average_price: Decimal.new("4950000"),
                 trade_mode: :paper
               })
               |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} =
               paper
               |> Ash.Changeset.for_update(:update, %{
                 size: Decimal.new("0.06"),
                 average_price: Decimal.new("4810000"),
                 side: :sell,
                 trade_mode: :live
               })
               |> Ash.update()

      assert {:ok, updated} =
               paper
               |> Ash.Changeset.for_update(:update, %{
                 size: Decimal.new("0.06"),
                 average_price: Decimal.new("4810000")
               })
               |> Ash.update()

      assert updated.side == :buy
      assert updated.trade_mode == :paper
      assert Decimal.eq?(updated.size, Decimal.new("0.06"))
      assert Decimal.eq?(updated.average_price, Decimal.new("4810000"))
    end
  end

  describe "BalanceSnapshot" do
    test "stores decimal amounts" do
      captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, snapshot} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: "JPY",
                 amount: Decimal.new("1000000"),
                 available: Decimal.new("950000"),
                 captured_at: captured_at,
                 trade_mode: :live
               })
               |> Ash.create()

      assert Decimal.eq?(snapshot.amount, Decimal.new("1000000"))
      assert Decimal.eq?(snapshot.available, Decimal.new("950000"))
    end
  end

  describe "RiskState" do
    test "persists halt reason with unique name" do
      halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, state} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: true,
                 reason: "reconcile_mismatch",
                 halted_at: halted_at
               })
               |> Ash.create()

      assert state.halted
      assert state.reason == "reconcile_mismatch"

      assert {:error, %Ash.Error.Invalid{}} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: false
               })
               |> Ash.create()
    end
  end

  test "Trading domain registers all four resources" do
    resources = Ash.Domain.Info.resources(Trading)

    assert Bitflyer.Trading.Order in resources
    assert Bitflyer.Trading.Position in resources
    assert Bitflyer.Trading.BalanceSnapshot in resources
    assert Bitflyer.Trading.RiskState in resources
  end
end
