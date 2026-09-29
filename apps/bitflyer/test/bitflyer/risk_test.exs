defmodule Bitflyer.RiskTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.{Cache, Normalize}
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.{AuthorizedOrder, DailyLoss}
  alias Bitflyer.Trading.{DailyEquityPeak, Position, RiskState}

  @market_key {:ticker, "BTC_JPY"}

  @connected_feed %{available?: true, connected?: true}
  @disconnected_feed %{available?: true, connected?: false}
  @unavailable_feed %{available?: false, connected?: false}
  @enabled_fresh_market %{enabled?: true, all_fresh?: true}
  @enabled_stale_market %{enabled?: true, all_fresh?: false}

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
             ltp: %{price: Decimal.new("5000000"), source_timestamp: skewed},
             book: %{
               best_bid: Decimal.new("4999000"),
               best_ask: Decimal.new("5001000")
             }
           }) == :ok

    assert {:error, :clock_skew, %{skew_ms: skew_ms, max_ms: 5_000}} =
             Risk.authorize(valid_command(), positions: [])

    assert skew_ms > 5_000
  end

  test "authorize rejects missing source_timestamp" do
    assert Readiness.mark_ready() == :ok

    assert Cache.put(@market_key, %{
             ltp: %{price: Decimal.new("5000000"), source_timestamp: nil},
             book: %{
               best_bid: Decimal.new("4999000"),
               best_ask: Decimal.new("5001000")
             }
           }) == :ok

    assert {:error, :clock_skew, %{reason: :missing_source_timestamp}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "authorize accepts source_timestamp within skew limit" do
    assert Readiness.mark_ready() == :ok

    assert Cache.put(@market_key, %{
             ltp: %{
               price: Decimal.new("5000000"),
               source_timestamp: DateTime.utc_now()
             },
             book: %{
               best_bid: Decimal.new("4999000"),
               best_ask: Decimal.new("5001000")
             }
           }) == :ok

    assert {:ok, %AuthorizedOrder{}} = Risk.authorize(valid_command(), positions: [])
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
      %{product_code: "BTC_JPY", side: :buy, size: Decimal.new("0.04")}
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

    assert {:ok, %AuthorizedOrder{}} = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects disconnected feed while cache is still fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :stale, %{reason: :feed_disconnected}} =
             Risk.authorize(valid_command(),
               positions: [],
               market_data: @enabled_fresh_market,
               feed: @disconnected_feed
             )
  end

  test "authorize rejects unavailable feed while cache is still fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :stale, %{reason: :feed_unavailable}} =
             Risk.authorize(valid_command(),
               positions: [],
               market_data: @enabled_fresh_market,
               feed: @unavailable_feed
             )
  end

  test "authorize rejects stale_market_data from market_feed_gate even if command key is fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :stale, %{reason: :stale_market_data}} =
             Risk.authorize(valid_command(),
               positions: [],
               market_data: @enabled_stale_market,
               feed: @connected_feed
             )
  end

  test "authorize accepts when market_feed_gate is connected and all fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(),
               positions: [],
               market_data: @enabled_fresh_market,
               feed: @connected_feed
             )
  end

  test "authorize ignores product_codes opt so all configured products stay in the gate" do
    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData, [])

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous_md)
    end)

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      previous_md
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:product_codes, ["BTC_JPY", "ETH_JPY"])
    )

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :stale, %{reason: :stale_market_data}} =
             Risk.authorize(valid_command(),
               positions: [],
               product_codes: ["BTC_JPY"],
               feed: @connected_feed
             )
  end

  test "authorize ignores injected feed snapshots when test injections are off" do
    previous_risk = Application.get_env(:bitflyer, Bitflyer.Risk, [])
    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData, [])

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.Risk, previous_risk)
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous_md)
    end)

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.put(previous_risk, :allow_test_injections, false)
    )

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.put(previous_md, :enabled, true)
    )

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :stale, %{reason: :feed_unavailable}} =
             Risk.authorize(valid_command(),
               positions: [],
               market_data: @enabled_fresh_market,
               feed: @connected_feed
             )
  end

  test "authorize raises HWM in ETS without syncing DailyEquityPeak" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = DailyLoss.seed_net(:dry_run, Decimal.new("100000"))

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               write_behind: false
             )

    assert {:ok, %{peak: peak}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(peak, Decimal.new("100000"))

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    refute Enum.any?(rows, &(&1.trade_mode == :dry_run))
  end

  test "authorize crash before peak flush still leaves HWM after write-behind" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = DailyLoss.seed_net(:dry_run, Decimal.new("100000"))
    assert :ok = Bitflyer.Risk.PeakWriter.suspend()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)

    assert {:ok, %{peak: ets_peak}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(ets_peak, Decimal.new("100000"))

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows_before} = DailyEquityPeak.fetch_day(day)
    refute Enum.any?(rows_before, &(&1.trade_mode == :dry_run))

    # 認可直後の DailyLoss 再起動。DB に高値が無いので ETS peak は消える。
    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: lost}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(lost, Decimal.new(0))

    assert :ok = Bitflyer.Risk.PeakWriter.resume()
    assert :ok = Bitflyer.Risk.PeakWriter.drain()

    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    row = Enum.find(rows, &(&1.trade_mode == :dry_run))
    assert row
    assert Decimal.eq?(row.peak, Decimal.new("100000"))

    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(restored, Decimal.new("100000"))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: after_boot}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(after_boot, Decimal.new("100000"))
  end

  test "authorize persists HWM before returning when the peak writer is absent" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = DailyLoss.seed_net(:dry_run, Decimal.new("100000"))

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               peak_writer: :missing_peak_writer
             )

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    row = Enum.find(rows, &(&1.trade_mode == :dry_run))
    assert row
    assert Decimal.eq?(row.peak, Decimal.new("100000"))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(restored, Decimal.new("100000"))
  end

  test "authorize rejects when the peak writer is absent and the fallback upsert fails" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    assert :ok = DailyLoss.seed_net(:dry_run, Decimal.new("100000"))

    assert {:error, :unsynced, %{reason: :hwm_persist_failed}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               peak_writer: :missing_peak_writer,
               fallback_upsert: fn _mode, _day, _peak -> {:error, :db_down} end
             )

    assert {:error, :unsynced} = DailyLoss.snapshot(:dry_run)
  end

  test "enforce after authorize flush persists HWM so reinit keeps unrealized drawdown" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    filled_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Bitflyer.Trading.Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "hwm-flush-1",
               product_code: "BTC_JPY",
               side: :sell,
               size: Decimal.new("0.02"),
               price: Decimal.new("5000000"),
               realized_pnl: Decimal.new("100000"),
               trade_mode: :dry_run,
               filled_at: filled_at
             })
             |> Ash.create()

    assert :ok = DailyLoss.reload(trade_mode: :dry_run)

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert :ok = Bitflyer.Risk.PeakWriter.drain()
    assert {:ok, rows_before} = DailyEquityPeak.fetch_day(day)
    row_before = Enum.find(rows_before, &(&1.trade_mode == :dry_run))
    assert row_before
    assert Decimal.eq?(row_before.peak, Decimal.new("100000"))

    assert {:ok, position} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "BTC_JPY",
               side: :buy,
               size: Decimal.new("0.02"),
               average_price: Decimal.new("5000000"),
               trade_mode: :dry_run
             })
             |> Ash.create()

    # 実現益後に含み損で equity を下げる（peak は認可の write-behind で既に永続）
    assert put_fresh_ticker(@market_key, Decimal.new("1000000")) == :ok

    assert {:ok, snap} =
             Bitflyer.Risk.Equity.enforce(
               trade_mode: :dry_run,
               positions: [position],
               limits: %{max_daily_drawdown: "200000"}
             )

    assert Decimal.eq?(snap.peak, Decimal.new("100000"))
    assert Decimal.eq?(snap.realized_net, Decimal.new("100000"))
    assert Decimal.eq?(snap.unrealized, Decimal.new("-80000"))
    assert Decimal.eq?(snap.equity_pnl, Decimal.new("20000"))
    assert Decimal.eq?(snap.drawdown, Decimal.new("80000"))

    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    row = Enum.find(rows, &(&1.trade_mode == :dry_run))
    assert row
    assert Decimal.eq?(row.peak, Decimal.new("100000"))

    assert :ok = DailyLoss.reset()
    assert :ok = DailyLoss.reinit()

    assert {:ok, restored} =
             Bitflyer.Risk.Equity.snapshot(
               trade_mode: :dry_run,
               positions: [position],
               record_peak: false,
               limits: %{max_daily_drawdown: "200000"}
             )

    assert Decimal.eq?(restored.peak, Decimal.new("100000"))
    assert Decimal.eq?(restored.realized_net, Decimal.new("100000"))
    assert Decimal.eq?(restored.unrealized, Decimal.new("-80000"))
    assert Decimal.eq?(restored.drawdown, Decimal.new("80000"))
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

  test "authorize ignores persisted RiskState by default until CircuitSync" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "mix_halt",
               halted_at: halted_at
             })
             |> Ash.create()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(), positions: [])

    assert {:ok, :synced} = Bitflyer.Risk.CircuitSync.sync_now()
    assert match?({:halted, _}, Readiness.get())

    assert {:error, :circuit_open, %{readiness: _}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "authorize can opt into persisted circuit check without CircuitSync" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "mix_halt",
               halted_at: halted_at
             })
             |> Ash.create()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(),
               positions: [],
               check_persisted_circuit: false
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

    assert {:ok, %AuthorizedOrder{}} =
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

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(%{order_type: :market}),
               positions: [],
               limits: %{max_price_deviation_pct: Decimal.new("0.01")}
             )
  end

  test "authorize rejects market order when spread exceeds max_spread_pct" do
    assert Readiness.mark_ready() == :ok

    assert :ok =
             Cache.put(@market_key, %{
               ltp: Decimal.new("5000000"),
               best_bid: Decimal.new("4900000"),
               best_ask: Decimal.new("5100000"),
               source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
             })

    # mid=5_000_000, spread=4%
    assert {:error, :limit_exceeded, %{limit: :max_spread_pct, spread_pct: spread}} =
             Risk.authorize(valid_command(%{order_type: :market}),
               positions: [],
               limits: %{max_spread_pct: Decimal.new("0.5")}
             )

    assert Decimal.gt?(spread, Decimal.new("0.5"))
  end

  test "authorize accepts market order within max_spread_pct" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(%{order_type: :market}),
               positions: [],
               limits: %{max_spread_pct: Decimal.new("0.5")}
             )
  end

  test "authorize skips spread gate for limit orders" do
    assert Readiness.mark_ready() == :ok

    assert :ok =
             Cache.put(@market_key, %{
               ltp: Decimal.new("5000000"),
               best_bid: Decimal.new("4900000"),
               best_ask: Decimal.new("5100000"),
               source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
             })

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               limits: %{
                 max_spread_pct: Decimal.new("0.01"),
                 max_price_deviation_pct: Decimal.new("2")
               }
             )
  end

  test "live market buy rejects a size that walks past the top" do
    ask = Decimal.new("5001000")
    size = Decimal.new("0.02")
    top = Decimal.new("0.01")

    assert :ok =
             Cache.put(@market_key, %{
               ltp: %{
                 price: Decimal.new("5000000"),
                 source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
               },
               book: %{
                 best_bid: Decimal.new("4999000"),
                 best_ask: ask,
                 best_ask_size: top
               }
             })

    assert {:error, :limit_exceeded, %{limit: :ask_depth, ask_size: ask_size}} =
             Risk.balance_hold(
               valid_command(%{order_type: :market, size: size}),
               trade_mode: :live
             )

    assert Decimal.equal?(ask_size, top)

    assert {:error, :limit_exceeded, %{limit: :ask_depth}} =
             Risk.balance_hold(
               valid_command(%{order_type: :market, size: size}),
               trade_mode: :paper
             )

    assert Readiness.mark_ready() == :ok

    parent = self()
    handler_id = "risk-ask-depth-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :risk, :rejected],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:ask_depth_rejected, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :limit_exceeded, %{limit: :ask_depth}} =
             Risk.authorize(
               valid_command(%{order_type: :market, size: size}),
               trade_mode: :live,
               positions: [],
               balances: %{"JPY" => %{available: Decimal.new("10000000")}}
             )

    assert_receive {:ask_depth_rejected, metadata}
    assert metadata.limit == :ask_depth
    assert Decimal.equal?(metadata.size, size)
    assert Decimal.equal?(metadata.ask_size, top)
  end

  test "live market buy rejects when the top size is missing" do
    assert :ok =
             Cache.put(@market_key, %{
               ltp: %{
                 price: Decimal.new("5000000"),
                 source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
               },
               book: %{
                 best_bid: Decimal.new("4999000"),
                 best_ask: Decimal.new("5001000")
               }
             })

    assert {:error, :stale, %{reason: :ask_size_missing}} =
             Risk.balance_hold(valid_command(%{order_type: :market}), trade_mode: :live)
  end

  test "live market buy hold stays at ask times size when size fits the top" do
    ask = Decimal.new("5001000")
    size = Decimal.new("0.01")

    assert :ok =
             Cache.put(@market_key, %{
               ltp: %{
                 price: Decimal.new("5000000"),
                 source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
               },
               book: %{
                 best_bid: Decimal.new("4999000"),
                 best_ask: ask,
                 best_ask_size: size
               }
             })

    assert {:ok, %{amount: amount}} =
             Risk.balance_hold(
               valid_command(%{order_type: :market, size: size}),
               trade_mode: :live
             )

    assert Decimal.equal?(amount, Decimal.mult(ask, size))
  end

  test "paper market buy hold stays on adverse LTP and ignores best_ask" do
    ltp = Decimal.new("5000000")
    ask = Decimal.new("5010000")
    size = Decimal.new("0.01")

    assert :ok =
             Cache.put(@market_key, %{
               ltp: ltp,
               best_bid: ltp,
               best_ask: ask,
               best_ask_size: size,
               source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
             })

    assert {:ok, %{currency: "JPY", amount: amount}} =
             Risk.balance_hold(
               valid_command(%{order_type: :market, size: size}),
               trade_mode: :paper
             )

    assert {:ok, priced} =
             Bitflyer.OrderExecutor.Paper.FillPricing.effective_price(:buy, ltp)

    assert Decimal.equal?(amount, Decimal.mult(priced, size))
    refute Decimal.equal?(amount, Decimal.mult(ask, size))
  end

  test "live market buy hold fails closed when best_ask is missing" do
    assert :ok =
             Cache.put(@market_key, %{
               ltp: Decimal.new("5000000"),
               source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
             })

    assert {:error, :stale, %{reason: :bid_ask_missing}} =
             Risk.balance_hold(valid_command(%{order_type: :market}), trade_mode: :live)
  end

  test "crossed book stays fresh and market orders stop as bid_ask_missing" do
    assert Readiness.mark_ready() == :ok

    assert {:ok, key, value} =
             Normalize.from_ticker(%{
               "product_code" => "BTC_JPY",
               "ltp" => 5_000_000,
               "best_bid" => 5_002_000,
               "best_ask" => 5_001_000,
               "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert value.book == nil
    assert :ok = Cache.put(key, value)
    assert Cache.fresh?(key, 5_000)
    assert :ok = Risk.check_source_timestamp(value, 5_000)

    parent = self()
    handler_id = "risk-book-#{System.unique_integer([:positive])}"

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

    assert {:error, :stale, %{reason: :bid_ask_missing}} =
             Risk.authorize(valid_command(%{order_type: :market}), positions: [])

    assert_receive {:telemetry, [:bitflyer, :risk, :rejected], %{count: 1}, metadata}
    assert metadata.rejection_code == :stale
    assert metadata.reason == :stale
    assert metadata.detail == :bid_ask_missing

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{
                 order_type: :limit,
                 price: Decimal.new("5000000"),
                 size: Decimal.new("0.01")
               }),
               positions: [],
               limits: %{max_price_deviation_pct: Decimal.new("1")}
             )
  end

  test "authorize rejects market order when bid/ask missing from cache" do
    assert Readiness.mark_ready() == :ok

    assert :ok =
             Cache.put(@market_key, %{
               ltp: Decimal.new("5000000"),
               source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
             })

    assert {:error, :stale, %{reason: :bid_ask_missing}} =
             Risk.authorize(valid_command(%{order_type: :market}), positions: [])
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

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(valid_command(), positions: [], trade_mode: :dry_run)
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

  test "authorize rejects unrealized drawdown and opens circuit" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker(@market_key, Decimal.new("1000000")) == :ok

    losing = %{
      product_code: "BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      average_price: Decimal.new("5000000")
    }

    assert {:error, :limit_exceeded, %{limit: :max_daily_drawdown, drawdown: drawdown}} =
             Risk.authorize(valid_command(),
               positions: [losing],
               trade_mode: :dry_run,
               limits: %{
                 max_daily_loss: Decimal.new("1000000"),
                 max_daily_drawdown: Decimal.new("50000")
               }
             )

    assert Decimal.gt?(drawdown, Decimal.new("50000"))
    assert Readiness.get() == {:halted, :daily_drawdown_exceeded}
  end

  test "authorize ignores injected empty positions without test injections" do
    previous = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.put(previous, :allow_test_injections, false)
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.Risk, previous)
    end)

    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker(@market_key, Decimal.new("1000000")) == :ok

    {:ok, _} =
      Position
      |> Ash.Changeset.for_create(:create, %{
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.02"),
        average_price: Decimal.new("5000000"),
        trade_mode: :dry_run
      })
      |> Ash.create()

    assert {:error, :limit_exceeded, %{limit: :max_daily_drawdown}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               limits: %{
                 max_daily_loss: Decimal.new("1000000"),
                 max_daily_drawdown: Decimal.new("50000")
               }
             )
  end

  test "authorize rejects when carried position mark is stale" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    losing = %{
      product_code: "ETH_JPY",
      side: :buy,
      size: Decimal.new("1"),
      average_price: Decimal.new("500000")
    }

    assert {:error, :stale, %{reason: :mark_price_unavailable, product_code: "ETH_JPY"}} =
             Risk.authorize(valid_command(),
               positions: [losing],
               trade_mode: :dry_run
             )

    refute match?({:halted, _}, Readiness.get())
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

  test "concurrent authorize cannot exceed max_orders_per_minute" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    max = 5
    task_count = 30

    results =
      1..task_count
      |> Task.async_stream(
        fn i ->
          Risk.authorize(
            valid_command(%{internal_order_id: "rate-concurrent-#{i}"}),
            positions: [],
            trade_mode: :dry_run,
            limits: %{max_orders_per_minute: max}
          )
        end,
        max_concurrency: task_count,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = Enum.filter(results, &match?({:ok, _}, &1))
    limited = Enum.filter(results, &match?({:error, :limit_exceeded, _}, &1))

    assert length(oks) == max
    assert length(limited) == task_count - max
    assert {:ok, ^max} = Bitflyer.Risk.OrderRate.count(:dry_run)
  end

  test "authorize ignores recent_order_count injection when test injections disabled" do
    previous = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.put(previous, :allow_test_injections, false)
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.Risk, previous) end)

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Bitflyer.Risk.OrderRate.record(:dry_run)

    # 注入 count=0 でも実 ETS（1）を見て拒否する
    assert {:error, :limit_exceeded, %{limit: :max_orders_per_minute, count: 1, max: 1}} =
             Risk.authorize(valid_command(),
               positions: [],
               trade_mode: :dry_run,
               recent_order_count: 0,
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

  test "live authorize refuses max_open_age_ms above the 7 day limit" do
    previous = Application.get_env(:bitflyer, Bitflyer.Risk.OpenOrderPolicy, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk.OpenOrderPolicy,
      Keyword.put(
        previous,
        :max_open_age_ms,
        Bitflyer.Config.LiveSafety.max_open_age_ms_limit() + 1
      )
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.Risk.OpenOrderPolicy, previous) end)

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :unsynced, %{reason: :max_open_age_required}} =
             Risk.authorize(
               valid_command(),
               positions: [],
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("10000000")}}
             )
  end

  test "live authorize refuses unbounded max_open_age_ms" do
    previous = Application.get_env(:bitflyer, Bitflyer.Risk.OpenOrderPolicy, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk.OpenOrderPolicy,
      Keyword.put(previous, :max_open_age_ms, :infinity)
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.Risk.OpenOrderPolicy, previous) end)

    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :unsynced, %{reason: :max_open_age_required}} =
             Risk.authorize(
               valid_command(),
               positions: [],
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("10000000")}}
             )
  end

  test "live rejects sell without a covering long position" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :spot_sell_exceeds_position}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: Decimal.new("0.01")}),
               positions: [],
               open_orders: [],
               trade_mode: :live,
               balances: %{
                 "JPY" => %{available: Decimal.new("1000000")},
                 "BTC" => %{available: Decimal.new("0.5")}
               }
             )
  end

  test "live rejects sell of the full long because the base fee reserve does not fit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :spot_sell_exceeds_position}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: Decimal.new("0.01")}),
               positions: [
                 %{
                   product_code: "BTC_JPY",
                   side: :buy,
                   size: Decimal.new("0.01"),
                   average_price: Decimal.new("5000000")
                 }
               ],
               open_orders: [],
               trade_mode: :live,
               balances: %{
                 "JPY" => %{available: Decimal.new("1000000")},
                 "BTC" => %{available: Decimal.new("0.5")}
               }
             )
  end

  test "live accepts sell that leaves the published fee reserve on the long" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    size =
      Decimal.div(Decimal.new("0.01"), Decimal.add(Decimal.new("1"), Decimal.new("0.0015")))

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: size}),
               positions: [
                 %{
                   product_code: "BTC_JPY",
                   side: :buy,
                   size: Decimal.new("0.01"),
                   average_price: Decimal.new("5000000")
                 }
               ],
               open_orders: [],
               trade_mode: :live,
               balances: %{
                 "JPY" => %{available: Decimal.new("1000000")},
                 "BTC" => %{available: Decimal.new("0.5")}
               }
             )
  end

  test "live rejects sell that exceeds long minus open sells" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :limit_exceeded, %{limit: :spot_sell_exceeds_position}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: Decimal.new("0.01")}),
               positions: [
                 %{
                   product_code: "BTC_JPY",
                   side: :buy,
                   size: Decimal.new("0.01"),
                   average_price: Decimal.new("5000000")
                 }
               ],
               open_orders: [
                 %{
                   product_code: "BTC_JPY",
                   side: :sell,
                   size: Decimal.new("0.01"),
                   filled_size: Decimal.new(0)
                 }
               ],
               trade_mode: :live,
               balances: %{
                 "JPY" => %{available: Decimal.new("1000000")},
                 "BTC" => %{available: Decimal.new("0.5")}
               }
             )
  end

  test "paper still allows sell without a position when base balance is enough" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{side: :sell, size: Decimal.new("0.01")}),
               positions: [],
               trade_mode: :paper,
               balances: %{"BTC" => %{available: Decimal.new("0.5")}}
             )
  end

  test "live rejects FX product before other checks" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :invalid_command, meta} =
             Risk.authorize(
               valid_command(%{
                 product_code: "FX_BTC_JPY",
                 market_key: {:ticker, "FX_BTC_JPY"}
               }),
               positions: [],
               trade_mode: :live
             )

    assert meta.reason == :unsupported_product_for_live
    assert meta.market_type == :fx
  end

  test "live rejects an ETH_JPY size that is finer than 0.0000001" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    subscribe!("ETH_JPY")

    assert {:error, :invalid_command, meta} =
             Risk.authorize(
               valid_command(%{
                 product_code: "ETH_JPY",
                 market_key: {:ticker, "ETH_JPY"},
                 size: Decimal.new("0.01000992")
               }),
               positions: [],
               trade_mode: :live
             )

    assert meta.reason == :off_order_step
  end

  test "live rejects non-evidenced spot" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :invalid_command, meta} =
             Risk.authorize(
               valid_command(%{
                 product_code: "XRP_JPY",
                 market_key: {:ticker, "XRP_JPY"}
               }),
               positions: [],
               trade_mode: :live
             )

    assert meta.reason == :unsupported_product_for_live
    assert meta.market_type == :spot
  end

  test "live rejects an ETH_JPY buy that the fee would leave below the sell minimum" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker({:ticker, "ETH_JPY"}) == :ok
    subscribe!("ETH_JPY")

    assert {:error, :invalid_command, meta} =
             Risk.authorize(
               valid_command(%{
                 product_code: "ETH_JPY",
                 market_key: {:ticker, "ETH_JPY"},
                 side: :buy,
                 size: Decimal.new("0.01")
               }),
               positions: [],
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("1000000")}}
             )

    assert meta.reason == :below_min_order_size
  end

  test "live authorizes an on-step ETH_JPY buy that remains sellable" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker({:ticker, "ETH_JPY"}) == :ok
    subscribe!("ETH_JPY")

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{
                 product_code: "ETH_JPY",
                 market_key: {:ticker, "ETH_JPY"},
                 side: :buy,
                 size: Decimal.new("0.0100301")
               }),
               positions: [],
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("1000000")}}
             )
  end

  test "live rejects an evidenced product that is not subscribed" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker({:ticker, "ETH_JPY"}) == :ok

    assert {:error, :invalid_command, meta} =
             Risk.authorize(
               valid_command(%{
                 product_code: "ETH_JPY",
                 market_key: {:ticker, "ETH_JPY"},
                 side: :buy,
                 size: Decimal.new("0.0100301")
               }),
               positions: [],
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("1000000")}}
             )

    assert meta.reason == :unsubscribed_product
  end

  test "live FX buy does not spend spot JPY" do
    assert {:error, :unsynced, %{reason: :fx_margin_unmeasured}} =
             Risk.balance_hold(
               %{
                 product_code: "FX_BTC_JPY",
                 side: :buy,
                 size: Decimal.new("0.01"),
                 order_type: :limit,
                 price: Decimal.new("10000000"),
                 market_key: {:ticker, "FX_BTC_JPY"}
               },
               trade_mode: :live,
               balances: %{"JPY" => %{available: Decimal.new("100000000")}},
               collateral: %{
                 collateral: Decimal.new("100000"),
                 open_position_pnl: Decimal.new("0"),
                 require_collateral: Decimal.new("0"),
                 keep_rate: Decimal.new("0"),
                 margin_call_amount: Decimal.new("0"),
                 margin_call_due_date: nil
               },
               positions: []
             )
  end

  test "dry_run still allows FX product codes for paper-style fixtures" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker({:ticker, "FX_BTC_JPY"}) == :ok

    assert {:ok, %AuthorizedOrder{}} =
             Risk.authorize(
               valid_command(%{
                 product_code: "FX_BTC_JPY",
                 market_key: {:ticker, "FX_BTC_JPY"}
               }),
               positions: [],
               trade_mode: :dry_run
             )
  end

  test "live FX sell does not spend spot JPY or BTC" do
    assert {:error, :unsynced, %{reason: :fx_margin_unmeasured}} =
             Risk.balance_hold(
               %{
                 product_code: "FX_BTC_JPY",
                 side: :sell,
                 size: Decimal.new("0.01"),
                 order_type: :limit,
                 price: Decimal.new("10000000"),
                 market_key: {:ticker, "FX_BTC_JPY"}
               },
               trade_mode: :live,
               collateral: empty_collateral(),
               positions: []
             )
  end

  test "live FX sell halts when a position has no required collateral" do
    assert {:error, :limit_exceeded, %{limit: :keep_rate_breached}} =
             Risk.balance_hold(
               %{
                 product_code: "FX_BTC_JPY",
                 side: :sell,
                 size: Decimal.new("0.01"),
                 market_key: {:ticker, "FX_BTC_JPY"}
               },
               trade_mode: :live,
               collateral: empty_collateral(),
               positions: [%{product_code: "FX_BTC_JPY", size: Decimal.new("0.01")}]
             )
  end

  defp empty_collateral do
    %{
      collateral: Decimal.new("0"),
      open_position_pnl: Decimal.new("0"),
      require_collateral: Decimal.new("0"),
      keep_rate: Decimal.new("0"),
      margin_call_amount: Decimal.new("0"),
      margin_call_due_date: nil
    }
  end

  defp valid_command(overrides \\ %{}) do
    Map.merge(
      %{
        product_code: "BTC_JPY",
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

  defp subscribe!(product_code) do
    previous = Application.get_env(:bitflyer, Bitflyer.MarketData, [])

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous)
    end)

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.put(previous, :product_codes, [product_code])
    )
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
