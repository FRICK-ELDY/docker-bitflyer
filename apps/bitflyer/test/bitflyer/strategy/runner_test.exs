defmodule Bitflyer.Strategy.RunnerTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
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
    reset_daily_loss()

    previous_enabled = Application.get_env(:bitflyer, Bitflyer.Strategy, [])

    Application.put_env(:bitflyer, Bitflyer.Strategy,
      enabled: true,
      module: Bitflyer.Strategy.FixedOnce,
      params: [size: "0.01", side: :buy]
    )

    start_runner(throttle_ms: 0)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_daily_loss()
      Application.put_env(:bitflyer, Bitflyer.Strategy, previous_enabled)
    end)

    :ok
  end

  defp start_runner(opts) do
    opts = Keyword.merge([throttle_ms: 0, load_submitted?: false], opts)
    {:ok, pid} = start_supervised({Runner, opts})
    allow_runner_repo(pid)

    if opts[:load_submitted?] == false do
      send(pid, :load_submitted)
    end

    _ = :sys.get_state(Runner)
    {:ok, pid}
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
    start_runner(throttle_ms: 60_000)

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
    start_runner(throttle_ms: 0)
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

  test "ignores ticks until submitted ids are loaded" do
    stop_supervised(Runner)

    {:ok, pid} = start_supervised({Runner, [throttle_ms: 0, load_submitted?: :pending]})
    allow_runner_repo(pid)

    assert %{submitted: nil} = :sys.get_state(pid)

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(pid)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()

    send(pid, :load_submitted)
    _ = :sys.get_state(pid)

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(pid)

    assert {:ok, %Order{}} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()
  end

  test "discards ticks sent before ticks_ready_at (boot backlog)" do
    stop_supervised(Runner)

    {:ok, pid} = start_supervised({Runner, [throttle_ms: 0, load_submitted?: :pending]})
    allow_runner_repo(pid)
    send(pid, :load_submitted)
    state = :sys.get_state(pid)

    assert is_integer(state.ticks_ready_at)

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    send(
      pid,
      {:tick, @market_key, %{ltp: Decimal.new("5000000")}, state.ticks_ready_at - 1}
    )

    _ = :sys.get_state(pid)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(pid)

    assert {:ok, %Order{}} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()
  end

  test "invalid_command is settled and not retried" do
    stop_supervised(Runner)

    Application.put_env(:bitflyer, Bitflyer.Strategy,
      enabled: true,
      module: Bitflyer.TestSupport.InvalidOnceStrategy,
      params: []
    )

    start_runner(throttle_ms: 0)

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

  test "commands without internal_order_id are dropped without submit" do
    stop_supervised(Runner)

    Application.put_env(:bitflyer, Bitflyer.Strategy,
      enabled: true,
      module: Bitflyer.TestSupport.MissingIdStrategy,
      params: []
    )

    # DB ロードなし（他テストの order id を submitted に載せない）
    {:ok, _pid} = start_supervised({Runner, [throttle_ms: 0, load_submitted?: false]})
    assert %{submitted: submitted} = :sys.get_state(Runner)
    assert submitted == MapSet.new()

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert {:ok, before_orders} = Ash.read(Order)

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    state = :sys.get_state(Runner)

    assert state.submitted == MapSet.new()
    assert {:ok, after_orders} = Ash.read(Order)
    assert length(after_orders) == length(before_orders)
  end

  test "keyword params from start opts are normalized to a map" do
    stop_supervised(Runner)

    {:ok, _pid} =
      start_supervised(
        {Runner,
         [
           throttle_ms: 0,
           load_submitted?: false,
           params: [size: "0.02", side: :sell]
         ]}
      )

    assert %{params: %{size: "0.02", side: :sell}} = :sys.get_state(Runner)
  end

  test "FixedOnce emits no orders when trade_mode is live" do
    previous_mode = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :live_confirmed, false)
    end)

    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
    assert {:ok, before} = Ash.read(Order)

    assert :ok = Runner.notify_tick(@market_key, %{ltp: Decimal.new("5000000")})
    _ = :sys.get_state(Runner)

    assert {:ok, after_orders} = Ash.read(Order)
    assert length(after_orders) == length(before)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == ^@order_id)
             |> Ash.read_one()
  end
end
