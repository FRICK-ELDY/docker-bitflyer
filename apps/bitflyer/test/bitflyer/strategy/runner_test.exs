defmodule Bitflyer.Strategy.RunnerTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Readiness
  alias Bitflyer.Strategy.Runner
  alias Bitflyer.Trading.Order

  @market_key {:ticker, "FX_BTC_JPY"}

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()

    previous_enabled = Application.get_env(:bitflyer, Bitflyer.Strategy, [])

    Application.put_env(:bitflyer, Bitflyer.Strategy,
      enabled: true,
      module: Bitflyer.Strategy.FixedOnce,
      params: [size: "0.01", side: :buy]
    )

    {:ok, _pid} = start_supervised({Runner, [throttle_ms: 0]})

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      Application.put_env(:bitflyer, Bitflyer.Strategy, previous_enabled)
    end)

    :ok
  end

  test "tick before ready does not persist order; retries after ready" do
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "strategy-fixed-once-FX_BTC_JPY")
             |> Ash.read_one()

    assert Readiness.mark_ready() == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, %Order{status: :pending, trade_mode: :dry_run}} =
             Order
             |> Ash.Query.filter(internal_order_id == "strategy-fixed-once-FX_BTC_JPY")
             |> Ash.read_one()
  end

  test "successful intent is only submitted once per internal_order_id" do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, [%Order{}]} =
             Order
             |> Ash.Query.filter(internal_order_id == "strategy-fixed-once-FX_BTC_JPY")
             |> Ash.read()
  end

  test "throttle_ms prevents immediate retry after failed submit" do
    stop_supervised(Runner)
    {:ok, _pid} = start_supervised({Runner, [throttle_ms: 60_000]})

    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert Readiness.mark_ready() == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "strategy-fixed-once-FX_BTC_JPY")
             |> Ash.read_one()
  end
end
