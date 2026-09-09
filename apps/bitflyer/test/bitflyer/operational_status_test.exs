defmodule Bitflyer.OperationalStatusTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OperationalStatus
  alias Bitflyer.Readiness

  @product "FX_BTC_JPY"
  @market_key {:ticker, @product}

  setup do
    reset_readiness()
    assert Cache.clear() == :ok

    on_exit(fn ->
      reset_readiness()
      _ = Cache.clear()
    end)

    :ok
  end

  test "snapshot reports not_ready and stale until ready and fresh" do
    status = OperationalStatus.snapshot(trade_mode: :dry_run, live_confirmed?: false)

    refute status.orders_allowed?
    assert status.orders_reason == :not_ready
    assert status.readiness == :not_ready
    assert status.halt_reason == nil
    refute status.market_data.all_fresh?

    assert Readiness.mark_ready() == :ok
    status = OperationalStatus.snapshot(trade_mode: :dry_run, live_confirmed?: false)
    refute status.orders_allowed?
    assert status.orders_reason == :stale_market_data

    assert Cache.put(@market_key, %{ltp: Decimal.new("1")}) == :ok
    status = OperationalStatus.snapshot(trade_mode: :dry_run, live_confirmed?: false)
    assert status.orders_allowed?
    assert status.orders_reason == nil
    assert status.market_data.all_fresh?
  end

  test "halt reason becomes orders_reason" do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    status = OperationalStatus.snapshot(trade_mode: :paper, live_confirmed?: false)
    refute status.orders_allowed?
    assert status.orders_reason == :reconcile_mismatch
    assert status.halt_reason == :reconcile_mismatch
    assert status.readiness_label == "halted:reconcile_mismatch"
  end

  test "live without confirm stays halted even when ready and fresh" do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("1")}) == :ok

    status = OperationalStatus.snapshot(trade_mode: :live, live_confirmed?: false)
    refute status.orders_allowed?
    assert status.orders_reason == :live_confirm_missing

    status = OperationalStatus.snapshot(trade_mode: :live, live_confirmed?: true)
    assert status.orders_allowed?
  end

  test "orders_gate returns :ok or {:halted, reason}" do
    market = %{
      enabled?: true,
      max_age_ms: 5_000,
      all_fresh?: true,
      entries: []
    }

    assert OperationalStatus.orders_gate(:ready, :dry_run, market, false) == :ok

    assert OperationalStatus.orders_gate(:not_ready, :dry_run, market, false) ==
             {:halted, :not_ready}

    assert OperationalStatus.orders_gate({:halted, :circuit_open}, :dry_run, market, false) ==
             {:halted, :circuit_open}
  end

  test "snapshot forwards now/max_age_ms into market_data freshness" do
    assert Readiness.mark_ready() == :ok
    now = Cache.monotonic_ms()
    assert Cache.put(@market_key, %{ltp: Decimal.new("1")}, received_at: now - 10_000) == :ok

    status =
      OperationalStatus.snapshot(
        trade_mode: :dry_run,
        live_confirmed?: false,
        now: now,
        max_age_ms: 5_000
      )

    refute status.orders_allowed?
    assert status.orders_reason == :stale_market_data
    refute status.market_data.all_fresh?
    assert hd(status.market_data.entries).age_ms == 10_000
  end

  test "feed_snapshot reports disabled when market data is off" do
    feed = OperationalStatus.feed_snapshot(feed_enabled?: false)

    refute feed.enabled?
    refute feed.available?
    refute feed.connected?
    assert feed.subscribe_count == 0
    assert feed.reconnect_attempt == 0
  end

  test "feed_snapshot normalizes connected feed status" do
    feed =
      OperationalStatus.feed_snapshot(
        feed_enabled?: true,
        feed_status: %{
          connected?: true,
          subscribe_count: 2,
          reconnect_attempt: 0
        }
      )

    assert feed.enabled?
    assert feed.available?
    assert feed.connected?
    assert feed.subscribe_count == 2
    assert feed.reconnect_attempt == 0
  end

  test "feed_snapshot marks missing process as unavailable" do
    feed =
      OperationalStatus.feed_snapshot(
        feed_enabled?: true,
        feed_status: :unavailable
      )

    assert feed.enabled?
    refute feed.available?
    refute feed.connected?
  end

  test "snapshot includes feed from feed_status override" do
    status =
      OperationalStatus.snapshot(
        trade_mode: :dry_run,
        live_confirmed?: false,
        feed_enabled?: true,
        feed_status: %{
          connected?: false,
          subscribe_count: 1,
          reconnect_attempt: 3
        }
      )

    refute status.feed.connected?
    assert status.feed.subscribe_count == 1
    assert status.feed.reconnect_attempt == 3
  end
end
