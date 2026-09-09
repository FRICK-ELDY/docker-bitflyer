defmodule Bitflyer.ApplicationShutdownTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.Order

  @market_key {:ticker, "FX_BTC_JPY"}

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    Application.put_env(:bitflyer, :trade_mode, :dry_run)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
    end)

    :ok
  end

  test "prep_stop closes order gate and rejects new submit" do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    assert [] = Bitflyer.Application.prep_stop([])
    assert Readiness.get() == :not_ready

    assert {:error, :unsynced, %{readiness: :not_ready}} =
             OrderExecutor.submit(valid_command("shutdown-1"),
               positions: [],
               trade_mode: :dry_run
             )

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "shutdown-1")
             |> Ash.read_one()
  end

  test "prep_stop preserves halted state" do
    assert :ok = Readiness.halt(:reconcile_mismatch)
    assert [] = Bitflyer.Application.prep_stop([])
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert {:error, :circuit_open, %{readiness: :reconcile_mismatch}} =
             OrderExecutor.submit(valid_command("shutdown-halt-1"),
               positions: [],
               trade_mode: :dry_run
             )
  end

  test "ui prep_stop also closes order gate" do
    assert Readiness.mark_ready() == :ok
    assert [] = Ui.Application.prep_stop([])
    assert Readiness.get() == :not_ready
  end

  defp valid_command(id) do
    %{
      internal_order_id: id,
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      market_key: @market_key,
      order_type: :market
    }
  end
end
