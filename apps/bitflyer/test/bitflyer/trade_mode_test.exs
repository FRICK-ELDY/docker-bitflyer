defmodule Bitflyer.TradeModeTest do
  use ExUnit.Case, async: false

  alias Bitflyer.TradeMode

  setup do
    previous = %{
      trade_mode: Application.get_env(:bitflyer, :trade_mode),
      live_confirmed: Application.get_env(:bitflyer, :live_confirmed),
      readiness: Application.get_env(:bitflyer, :readiness)
    }

    on_exit(fn ->
      restore_env(:trade_mode, previous.trade_mode)
      restore_env(:live_confirmed, previous.live_confirmed)
      restore_env(:readiness, previous.readiness)
    end)

    :ok
  end

  describe "parse/1 and parse!/1" do
    test "accepts allowed modes" do
      assert TradeMode.parse("dry_run") == {:ok, :dry_run}
      assert TradeMode.parse("paper") == {:ok, :paper}
      assert TradeMode.parse(" live ") == {:ok, :live}
      assert TradeMode.parse!("dry_run") == :dry_run
      assert TradeMode.parse!("paper") == :paper
      assert TradeMode.parse!("live") == :live
    end

    test "rejects unknown or mistyped values" do
      assert {:error, _} = TradeMode.parse("Live")
      assert {:error, _} = TradeMode.parse("papper")
      assert {:error, _} = TradeMode.parse("")

      assert_raise ArgumentError, ~r/invalid TRADE_MODE/, fn ->
        TradeMode.parse!("production")
      end
    end
  end

  describe "predicates" do
    test "classify modes" do
      assert TradeMode.dry_run?(:dry_run)
      assert TradeMode.paper?(:paper)
      assert TradeMode.live?(:live)
      assert TradeMode.orders_reach_exchange?(:live)
      refute TradeMode.orders_reach_exchange?(:paper)
      refute TradeMode.orders_reach_exchange?(:dry_run)
    end
  end

  describe "valid_live_confirm?/2" do
    test "requires exact UTC date string" do
      today = ~D[2026-09-08]
      assert TradeMode.valid_live_confirm?("2026-09-08", today)
      refute TradeMode.valid_live_confirm?("2026-09-07", today)
      refute TradeMode.valid_live_confirm?(nil, today)
      refute TradeMode.valid_live_confirm?("", today)
    end
  end

  describe "exchange_order_gate/0" do
    test "dry_run and paper never permit exchange orders" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :readiness, :ready)

      assert TradeMode.exchange_order_gate() == {:halted, :not_live_mode}
      refute TradeMode.exchange_orders_permitted?()

      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert TradeMode.exchange_order_gate() == {:halted, :not_live_mode}
    end

    test "live alone without confirm stays halted" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, false)
      Application.put_env(:bitflyer, :readiness, :ready)

      assert TradeMode.exchange_order_gate() == {:halted, :live_confirm_missing}
      refute TradeMode.exchange_orders_permitted?()
    end

    test "live with confirm but not ready stays halted" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :readiness, :not_ready)

      assert TradeMode.exchange_order_gate() == {:halted, :not_ready}
      refute TradeMode.exchange_orders_permitted?()
    end

    test "live with confirm and ready permits exchange orders" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :readiness, :ready)

      assert TradeMode.exchange_order_gate() == :ok
      assert TradeMode.exchange_orders_permitted?()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:bitflyer, key)
  defp restore_env(key, value), do: Application.put_env(:bitflyer, key, value)
end
