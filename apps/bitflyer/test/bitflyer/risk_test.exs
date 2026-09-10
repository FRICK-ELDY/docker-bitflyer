defmodule Bitflyer.RiskTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Trading.RiskState

  @market_key {:ticker, "FX_BTC_JPY"}

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_daily_loss()
    reset_balance_cache()
    clear_default_risk_state()

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_daily_loss()
      reset_balance_cache()
    end)

    :ok
  end

  test "authorize rejects unsynced when not ready" do
    assert Readiness.get() == :not_ready
    put_fresh_market()

    assert {:error, :unsynced, _} = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects stale market data" do
    assert Readiness.mark_ready() == :ok

    assert {:error, :stale, %{market_key: @market_key}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects clock skew when source_timestamp is too far" do
    assert Readiness.mark_ready() == :ok

    skewed = DateTime.add(DateTime.utc_now(), -60, :second)

    assert Cache.put(@market_key, %{
             ltp: Decimal.new("5000000"),
             source_timestamp: skewed
           }) == :ok

    assert {:error, :clock_skew, %{skew_ms: skew_ms, max_ms: 5_000}} =
             Risk.authorize(valid_command(), positions: [])

    assert skew_ms > 5_000
  end

  test "authorize rejects missing source_timestamp" do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    assert {:error, :clock_skew, %{reason: :missing_source_timestamp}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "authorize accepts source_timestamp within skew limit" do
    assert Readiness.mark_ready() == :ok

    assert Cache.put(@market_key, %{
             ltp: Decimal.new("5000000"),
             source_timestamp: DateTime.utc_now()
           }) == :ok

    assert :ok = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects order size over limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_order_size: Decimal.new("0.01"),
      max_position_size: Decimal.new("5"),
      market_data_max_age_ms: 5_000
    }

    assert {:error, :limit_exceeded, %{limit: :max_order_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("0.02")}),
               positions: [],
               limits: limits
             )
  end

  test "authorize normalizes partial limits overrides" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :max_order_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("0.02")}),
               positions: [],
               limits: %{max_order_size: "0.01"}
             )
  end

  test "authorize rejects projected position over limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_order_size: Decimal.new("1"),
      max_position_size: Decimal.new("0.05"),
      market_data_max_age_ms: 5_000
    }

    positions = [
      %{product_code: "FX_BTC_JPY", side: :buy, size: Decimal.new("0.04")}
    ]

    assert {:error, :limit_exceeded, %{limit: :max_position_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("0.02")}),
               positions: positions,
               limits: limits
             )
  end

  test "authorize accepts a valid command when ready and fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects when circuit is open and open_circuit persists RiskState" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Risk.open_circuit(:limit_exceeded)
    assert Readiness.get() == {:halted, :limit_exceeded}
    assert Risk.circuit_open?()

    assert {:error, :circuit_open, _} =
             Risk.authorize(valid_command(), positions: [])

    assert {:ok, %RiskState{halted: true, reason: "limit_exceeded"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "clear_circuit clears RiskState and readiness halt" do
    assert Readiness.mark_ready() == :ok
    assert :ok = Risk.open_circuit(:limit_exceeded)
    assert Risk.circuit_open?()

    assert :ok = Risk.clear_circuit()
    assert Readiness.get() == :not_ready
    refute Risk.circuit_open?()

    assert {:ok, %RiskState{halted: false}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "authorize rejects when persisted circuit check finds halted RiskState" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "manual",
               halted_at: halted_at
             })
             |> Ash.create()

    assert {:error, :circuit_open, %{source: :risk_state}} =
             Risk.authorize(valid_command(),
               positions: [],
               check_persisted_circuit: true
             )
  end

  test "authorize emits risk_rejected telemetry" do
    parent = self()
    handler_id = "risk-rejected-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :risk, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :unsynced, _} = Risk.authorize(valid_command(), positions: [])

    assert_receive {:telemetry, [:bitflyer, :risk, :rejected], %{count: 1}, metadata}
    assert metadata.rejection_code == :unsynced
  end

  test "authorize emits limit name on limit_exceeded telemetry" do
    parent = self()
    handler_id = "risk-limit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :risk, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :max_order_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("100")}),
               positions: [],
               limits: %{
                 max_order_size: Decimal.new("1"),
                 max_position_size: Decimal.new("5"),
                 market_data_max_age_ms: 5_000
               }
             )

    assert_receive {:telemetry, [:bitflyer, :risk, :rejected], %{count: 1}, metadata}
    assert metadata.rejection_code == :limit_exceeded
    assert metadata.limit == :max_order_size
  end

  test "authorize rejects limit price far from LTP" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_order_size: Decimal.new("1"),
      max_position_size: Decimal.new("5"),
      max_price_deviation_pct: Decimal.new("1"),
      market_data_max_age_ms: 5_000
    }

    # LTP 5_000_000 に対し 3% 乖離
    assert {:error, :limit_exceeded, %{limit: :max_price_deviation_pct}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5150000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               limits: limits
             )
  end

  test "authorize accepts limit price within deviation" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_price_deviation_pct: Decimal.new("1"),
      market_data_max_age_ms: 5_000
    }

    assert :ok =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5040000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               limits: limits
             )
  end

  test "authorize skips price deviation for market orders" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok =
             Risk.authorize(valid_command(%{order_type: :market}),
               positions: [],
               limits: %{max_price_deviation_pct: Decimal.new("0.01")}
             )
  end

  test "authorize rejects when recent order rate exceeds limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :max_orders_per_minute, count: 3, max: 2}} =
             Risk.authorize(valid_command(),
               positions: [],
               recent_order_count: 3,
               limits: %{max_orders_per_minute: 2}
             )
  end

  test "authorize rejects daily loss over limit and opens circuit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
             Risk.authorize(valid_command(),
               positions: [],
               daily_loss: Decimal.new("150000"),
               limits: %{max_daily_loss: Decimal.new("100000")}
             )

    assert Readiness.get() == {:halted, :daily_loss_exceeded}
    assert Risk.circuit_open?()
  end

  test "authorize rejects when DailyLoss ETS is unsynced" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = Bitflyer.Risk.DailyLoss.mark_unsynced()

    assert {:error, :unsynced, %{reason: :daily_loss_unsynced}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "invalidate without reload keeps authorize fail-closed" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert {:ok, _gen} = Bitflyer.Risk.DailyLoss.invalidate(:dry_run)

    assert {:error, :unsynced, %{reason: :daily_loss_unsynced}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)
  end

  test "reconcile-style reload cannot sync over an open invalidate barrier" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, gen} = Bitflyer.Risk.DailyLoss.invalidate(:dry_run)

    # 突合側の安全 reload（release なし）は barrier 中に synced 化しない
    assert {:ok, :deferred} = Bitflyer.Risk.DailyLoss.reload(trade_mode: :dry_run)

    assert {:error, :unsynced, %{reason: :daily_loss_unsynced}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)

    # fill 側が同じ世代で解放して初めて synced
    assert :ok =
             Bitflyer.Risk.DailyLoss.reload(
               trade_mode: :dry_run,
               generation: gen,
               release_barrier: true
             )

    assert :ok = Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)
  end

  test "authorize rejects from DailyLoss ETS without daily_loss injection" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Bitflyer.Risk.DailyLoss.seed_loss(:dry_run, Decimal.new("150000"))

    assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               limits: %{max_daily_loss: Decimal.new("100000")}
             )

    assert Readiness.get() == {:halted, :daily_loss_exceeded}
  end

  test "authorize treats non-positive LTP as miss and rejects string daily_loss over limit" do
    assert Readiness.mark_ready() == :ok

    assert Cache.put(@market_key, %{
             ltp: Decimal.new("0"),
             source_timestamp: DateTime.utc_now()
           }) == :ok

    assert {:error, :stale, %{reason: :ltp_missing}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("1"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               limits: %{max_price_deviation_pct: Decimal.new("1")}
             )

    reset_readiness()
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
             Risk.authorize(valid_command(),
               positions: [],
               daily_loss: "150000",
               limits: %{max_daily_loss: "100000"}
             )
  end

  test "authorize rejects buy when atom currency keys are used in balances" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :insufficient_balance, currency: "JPY"}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               trade_mode: :paper,
               balances: %{JPY: %{available: Decimal.new("1000")}}
             )
  end

  test "authorize rejects when OrderRate ETS count exceeds limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Bitflyer.Risk.OrderRate.record(:dry_run)
    assert Bitflyer.Risk.OrderRate.count(:dry_run) == {:ok, 1}

    assert {:error, :limit_exceeded, %{limit: :max_orders_per_minute, count: 1, max: 1}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               limits: %{max_orders_per_minute: 1}
             )
  end

  test "authorize rejects buy when available quote balance is insufficient" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :insufficient_balance, currency: "JPY"}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               trade_mode: :paper,
               balances: %{"JPY" => %{available: Decimal.new("1000")}}
             )
  end

  test "authorize rejects sell when available base balance is insufficient" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :insufficient_balance, currency: "BTC"}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: Decimal.new("0.01")}),
               positions: [],
               trade_mode: :paper,
               balances: %{"BTC" => %{available: Decimal.new("0.001")}}
             )
  end

  test "authorize rejects when BalanceCache ETS is unsynced" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = Bitflyer.Risk.BalanceCache.mark_unsynced(:paper)

    assert {:error, :unsynced, %{reason: :balance_unsynced}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :paper)
  end

  test "authorize rejects missing required currency from BalanceCache without injection" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:paper, %{"BTC" => Decimal.new("1")})

    assert {:error, :unsynced, %{reason: :balance_currency_missing, currency: "JPY"}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               trade_mode: :paper
             )
  end

  test "authorize uses BalanceCache without balances injection" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:paper, %{"JPY" => Decimal.new("1000"), "BTC" => Decimal.new("0")})

    assert {:error, :limit_exceeded, %{limit: :insufficient_balance, currency: "JPY"}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               trade_mode: :paper
             )
  end

  test "authorize ignores balances injection when test injections disabled" do
    previous = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.put(previous, :allow_test_injections, false)
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.Risk, previous) end)

    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = Bitflyer.Risk.BalanceCache.mark_unsynced(:paper)

    assert {:error, :unsynced, %{reason: :balance_unsynced}} =
             Risk.authorize(
               valid_command(),
               positions: [],
               trade_mode: :paper,
               balances: %{"JPY" => %{available: Decimal.new("10000000")}}
             )
  end

  defp valid_command(overrides \\ %{}) do
    Map.merge(
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: @market_key,
        intent_id: "intent-1"
      },
      overrides
    )
  end

  defp put_fresh_market do
    assert put_fresh_ticker(@market_key) == :ok
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} -> :ok
      {:ok, risk} -> Ash.destroy!(risk)
      {:error, _} -> :ok
    end
  end
end
