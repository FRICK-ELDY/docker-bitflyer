defmodule Bitflyer.Strategy.RevisionTest do
  use Bitflyer.DataCase, async: true

  require Ash.Query

  alias Bitflyer.Strategy.Revision
  alias Bitflyer.Trading.StrategyParameterRevision

  describe "ensure_current/1" do
    test "creates a revision and reuses the latest when params_hash matches" do
      assert {:ok, first} =
               Revision.ensure_current(
                 trade_mode: :dry_run,
                 module: Bitflyer.Strategy.FixedOnce,
                 params: %{size: "0.01", side: :buy},
                 throttle_ms: 1_000,
                 source: :boot,
                 operator: "test"
               )

      assert first.strategy_module == "Elixir.Bitflyer.Strategy.FixedOnce"
      assert first.params == %{"side" => "buy", "size" => "0.01"}
      assert first.throttle_ms == 1_000
      assert first.source == :boot
      assert byte_size(first.params_hash) == 64

      assert {:ok, second} =
               Revision.ensure_current(
                 trade_mode: :dry_run,
                 module: Bitflyer.Strategy.FixedOnce,
                 params: %{size: "0.01", side: :buy},
                 throttle_ms: 1_000
               )

      assert second.id == first.id

      assert {:ok, [%StrategyParameterRevision{}]} =
               StrategyParameterRevision
               |> Ash.Query.filter(trade_mode == :dry_run)
               |> Ash.read()
    end

    test "creates a new row when params change" do
      assert {:ok, first} =
               Revision.ensure_current(
                 trade_mode: :paper,
                 module: Bitflyer.Strategy.FixedOnce,
                 params: %{size: "0.01", side: :buy},
                 throttle_ms: 500
               )

      assert {:ok, second} =
               Revision.ensure_current(
                 trade_mode: :paper,
                 module: Bitflyer.Strategy.FixedOnce,
                 params: %{size: "0.02", side: :buy},
                 throttle_ms: 500
               )

      assert second.id != first.id
      assert second.params_hash != first.params_hash
    end
  end

  describe "command_hash/1" do
    test "is stable for equivalent commands" do
      command = %{
        internal_order_id: "strategy-fixed-once-FX_BTC_JPY",
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market
      }

      hash = Revision.command_hash(command)
      assert hash == Revision.command_hash(command)
      assert byte_size(hash) == 64

      refute hash ==
               Revision.command_hash(%{command | size: Decimal.new("0.02")})
    end
  end
end
