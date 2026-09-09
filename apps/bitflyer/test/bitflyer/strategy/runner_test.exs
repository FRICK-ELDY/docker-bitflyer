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
  @order_id "strategy-fixed-once-FX_BTC_JPY"

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

    {:ok, pid} = start_supervised({Runner, [throttle_ms: 0]})
    allow_runner_repo(pid)
    _ = :sys.get_state(Runner)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      Application.put_env(:bitflyer, Bitflyer.Strategy, previous_enabled)
    end)

    :ok
  end

  defp allow_runner_repo(pid) when is_pid(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Bitflyer.Repo, self(), pid)
  end

  test "tick before ready does not persist order; retries after ready" do
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()

    assert Readiness.mark_ready() == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, %Order{status: :pending, trade_mode: :dry_run}} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
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
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read()
  end

  test "throttle_ms prevents immediate retry after failed submit" do
    stop_supervised(Runner)
    {:ok, pid} = start_supervised({Runner, [throttle_ms: 60_000]})
    allow_runner_repo(pid)
    _ = :sys.get_state(Runner)

    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert Readiness.mark_ready() == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()
  end

  test "loads existing internal_order_id into submitted on start" do
    assert {:ok, _order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: @order_id,
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               status: :pending,
               trade_mode: :dry_run
             })
             |> Ash.create()

    stop_supervised(Runner)
    {:ok, pid} = start_supervised({Runner, [throttle_ms: 0]})
    allow_runner_repo(pid)
    state = :sys.get_state(Runner)

    assert MapSet.member?(state.submitted, @order_id)

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, [%Order{}]} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read()
  end

  test "invalid_command is settled and not retried" do
    stop_supervised(Runner)

    Application.put_env(:bitflyer, Bitflyer.Strategy,
      enabled: true,
      module: Bitflyer.TestSupport.InvalidOnceStrategy,
      params: []
    )

    {:ok, pid} = start_supervised({Runner, [throttle_ms: 0]})
    allow_runner_repo(pid)
    _ = :sys.get_state(Runner)

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    state = :sys.get_state(Runner)

    assert MapSet.member?(state.submitted, "strategy-invalid-once-FX_BTC_JPY")

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    state2 = :sys.get_state(Runner)

    assert state2.submitted == state.submitted

    assert {:ok, []} =
             Order
             |> Ash.Query.filter(internal_order_id == "strategy-invalid-once-FX_BTC_JPY")
             |> Ash.read()
  end
end
