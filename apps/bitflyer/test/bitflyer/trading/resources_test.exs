defmodule Bitflyer.Trading.ResourcesTest do
  use Bitflyer.DataCase, async: true

  alias Bitflyer.Trading
  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position, RiskState, StrategyParameterRevision}

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
                 price: Decimal.new("5100000"),
                 size: Decimal.new("0.02"),
                 trade_mode: :paper
               })
               |> Ash.create()
    end

    test "requires price for limit orders; pending market forbids price" do
      assert {:error, %Ash.Error.Invalid{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-limit-no-price",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 order_type: :limit,
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run
               })
               |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-market-with-price",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 order_type: :market,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run
               })
               |> Ash.create()

      assert {:ok, market} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-market",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 order_type: :market,
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run
               })
               |> Ash.create()

      assert is_nil(market.price)

      assert {:ok, filled} =
               market
               |> Ash.Changeset.for_update(:update, %{
                 status: :filled,
                 filled_size: market.size,
                 price: Decimal.new("5000000")
               })
               |> Ash.update()

      assert Decimal.eq?(filled.price, Decimal.new("5000000"))
    end

    test "rejects filled_size greater than size" do
      assert {:error, %Ash.Error.Invalid{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-overfill",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01"),
                 filled_size: Decimal.new("0.02"),
                 trade_mode: :dry_run
               })
               |> Ash.create()
    end

    test "rejects non-positive size" do
      assert {:error, %Ash.Error.Invalid{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-neg-size",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0"),
                 trade_mode: :dry_run
               })
               |> Ash.create()
    end

    test "accepts expired status from exchange lifecycle" do
      assert {:ok, order} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-expired",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01"),
                 trade_mode: :live,
                 status: :expired
               })
               |> Ash.create()

      assert order.status == :expired
    end

    test "accepts optional strategy provenance fields with valid FK" do
      applied_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, revision} =
               StrategyParameterRevision
               |> Ash.Changeset.for_create(:create, %{
                 trade_mode: :dry_run,
                 strategy_module: "Elixir.Bitflyer.Strategy.FixedOnce",
                 params: %{"size" => "0.01", "side" => "buy"},
                 params_hash: String.duplicate("c", 64),
                 throttle_ms: 1_000,
                 source: :boot,
                 operator: "test",
                 applied_at: applied_at
               })
               |> Ash.create()

      assert {:ok, order} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-with-revision",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 order_type: :market,
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run,
                 strategy_parameter_revision_id: revision.id,
                 strategy_module: "Elixir.Bitflyer.Strategy.FixedOnce",
                 command_hash: String.duplicate("a", 64)
               })
               |> Ash.create()

      assert order.strategy_parameter_revision_id == revision.id
      assert order.strategy_module == "Elixir.Bitflyer.Strategy.FixedOnce"
      assert order.command_hash == String.duplicate("a", 64)

      assert {:error, %Ash.Error.Unknown{}} =
               Order
               |> Ash.Changeset.for_create(:create, %{
                 internal_order_id: "ord-orphan-revision",
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 order_type: :market,
                 size: Decimal.new("0.01"),
                 trade_mode: :dry_run,
                 strategy_parameter_revision_id: Ash.UUIDv7.generate()
               })
               |> Ash.create()
    end
  end

  describe "StrategyParameterRevision" do
    test "stores immutable strategy params snapshot" do
      applied_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, revision} =
               StrategyParameterRevision
               |> Ash.Changeset.for_create(:create, %{
                 trade_mode: :dry_run,
                 strategy_module: "Elixir.Bitflyer.Strategy.FixedOnce",
                 params: %{"size" => "0.01", "side" => "buy"},
                 params_hash: String.duplicate("b", 64),
                 throttle_ms: 1_000,
                 source: :boot,
                 operator: "test",
                 applied_at: applied_at
               })
               |> Ash.create()

      assert revision.source == :boot
      assert revision.params["size"] == "0.01"
    end

    test "rejects duplicate trade_mode and params_hash" do
      applied_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        trade_mode: :paper,
        strategy_module: "Elixir.Bitflyer.Strategy.FixedOnce",
        params: %{"size" => "0.01"},
        params_hash: String.duplicate("d", 64),
        throttle_ms: 1_000,
        source: :boot,
        operator: "test",
        applied_at: applied_at
      }

      assert {:ok, _} =
               StrategyParameterRevision
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} =
               StrategyParameterRevision
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create()
    end
  end

  describe "Position" do
    test "uniqueness is per product_code and trade_mode; side can flip, trade_mode cannot" do
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
                 trade_mode: :live
               })
               |> Ash.update()

      assert {:ok, flipped} =
               paper
               |> Ash.Changeset.for_update(:update, %{
                 side: :sell,
                 size: Decimal.new("0.06"),
                 average_price: Decimal.new("4810000")
               })
               |> Ash.update()

      assert flipped.side == :sell
      assert flipped.trade_mode == :paper
      assert Decimal.eq?(flipped.size, Decimal.new("0.06"))
      assert Decimal.eq?(flipped.average_price, Decimal.new("4810000"))
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

    test "rejects available greater than amount" do
      captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:error, %Ash.Error.Invalid{}} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: "JPY",
                 amount: Decimal.new("1000000"),
                 available: Decimal.new("1000001"),
                 captured_at: captured_at,
                 trade_mode: :live
               })
               |> Ash.create()
    end
  end

  describe "RiskState" do
    test "halted requires reason and halted_at" do
      assert {:error, %Ash.Error.Invalid{}} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "incomplete",
                 halted: true
               })
               |> Ash.create()

      halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, state} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "halted-default",
                 halted: true,
                 reason: "reconcile_mismatch",
                 halted_at: halted_at
               })
               |> Ash.create()

      assert state.halted
      assert state.reason == "reconcile_mismatch"
    end

    test "not halted clears reason fields and can be created" do
      assert {:ok, state} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "not-halted",
                 halted: false
               })
               |> Ash.create()

      assert state.halted == false
      assert is_nil(state.reason)
      assert is_nil(state.halted_at)

      assert {:error, %Ash.Error.Invalid{}} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "stale-reason",
                 halted: false,
                 reason: "old"
               })
               |> Ash.create()
    end

    test "name is unique" do
      halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: true,
                 reason: "reconcile_mismatch",
                 halted_at: halted_at
               })
               |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: false
               })
               |> Ash.create()
    end
  end

  test "Trading domain registers core resources" do
    resources = Ash.Domain.Info.resources(Trading)

    assert Bitflyer.Trading.Order in resources
    assert Bitflyer.Trading.Position in resources
    assert Bitflyer.Trading.Fill in resources
    assert Bitflyer.Trading.BalanceSnapshot in resources
    assert Bitflyer.Trading.BaselineImport in resources
    assert Bitflyer.Trading.StrategyParameterRevision in resources
    assert Bitflyer.Trading.RiskState in resources
  end
end
