defmodule Bitflyer.OperationalStatusTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Health
  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OperationalStatus
  alias Bitflyer.Readiness

  @product "BTC_JPY"
  @market_key {:ticker, @product}

  @connected_feed %{
    enabled?: true,
    available?: true,
    connected?: true,
    subscribe_count: 1,
    reconnect_attempt: 0
  }

  @disconnected_feed %{
    enabled?: true,
    available?: true,
    connected?: false,
    subscribe_count: 1,
    reconnect_attempt: 2
  }

  @unavailable_feed %{
    enabled?: true,
    available?: false,
    connected?: false,
    subscribe_count: 0,
    reconnect_attempt: 0
  }

  @fresh_market %{
    enabled?: true,
    max_age_ms: 5_000,
    all_fresh?: true,
    entries: [
      %{product_code: @product, key: @market_key, fresh?: true, age_ms: 10}
    ]
  }

  @stale_market %{
    enabled?: true,
    max_age_ms: 5_000,
    all_fresh?: false,
    entries: [
      %{product_code: @product, key: @market_key, fresh?: false, age_ms: :miss}
    ]
  }

  @disabled_market %{
    enabled?: false,
    max_age_ms: 5_000,
    all_fresh?: false,
    entries: []
  }

  setup do
    reset_readiness()
    assert Cache.clear() == :ok

    on_exit(fn ->
      reset_readiness()
      _ = Cache.clear()
    end)

    :ok
  end

  test "snapshot reports not_ready until ready; MD disabled skips freshness" do
    status = OperationalStatus.snapshot(trade_mode: :dry_run, live_confirmed?: false)

    refute status.orders_allowed?
    assert status.orders_reason == :not_ready
    assert status.readiness == :not_ready
    assert status.halt_reason == nil
    refute status.market_data.enabled?

    assert Readiness.mark_ready() == :ok
    status = OperationalStatus.snapshot(trade_mode: :dry_run, live_confirmed?: false)
    # test.exs では MarketData.enabled? = false → Health ready と同様に鮮度を見ない
    assert status.orders_allowed?
    assert status.orders_reason == nil
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

    status =
      OperationalStatus.snapshot(
        trade_mode: :live,
        live_confirmed?: false,
        market_data: @fresh_market,
        feed: @connected_feed
      )

    refute status.orders_allowed?
    assert status.orders_reason == :live_confirm_missing

    status =
      OperationalStatus.snapshot(
        trade_mode: :live,
        live_confirmed?: true,
        market_data: @fresh_market,
        feed: @connected_feed
      )

    assert status.orders_allowed?
  end

  test "orders_gate returns :ok or {:halted, reason}" do
    assert OperationalStatus.orders_gate(:ready, :dry_run, @fresh_market, false, @connected_feed) ==
             :ok

    assert OperationalStatus.orders_gate(
             :not_ready,
             :dry_run,
             @fresh_market,
             false,
             @connected_feed
           ) == {:halted, :not_ready}

    assert OperationalStatus.orders_gate(
             {:halted, :circuit_open},
             :dry_run,
             @fresh_market,
             false,
             @connected_feed
           ) == {:halted, :circuit_open}
  end

  test "feed disconnect refuses orders even when market data is still fresh" do
    assert Readiness.mark_ready() == :ok

    status =
      OperationalStatus.snapshot(
        trade_mode: :dry_run,
        live_confirmed?: false,
        market_data: @fresh_market,
        feed: @disconnected_feed
      )

    refute status.orders_allowed?
    assert status.orders_reason == :feed_disconnected

    assert OperationalStatus.orders_gate(
             :ready,
             :dry_run,
             @fresh_market,
             false,
             @disconnected_feed
           ) == {:halted, :feed_disconnected}
  end

  test "feed unavailable refuses orders when market data is enabled" do
    assert OperationalStatus.orders_gate(
             :ready,
             :dry_run,
             @fresh_market,
             false,
             @unavailable_feed
           ) == {:halted, :feed_unavailable}
  end

  test "stale market data refuses orders when feed is connected" do
    assert OperationalStatus.orders_gate(
             :ready,
             :dry_run,
             @stale_market,
             false,
             @connected_feed
           ) == {:halted, :stale_market_data}
  end

  test "market_feed_gate matches Health ready reasons" do
    assert OperationalStatus.market_feed_gate(@fresh_market, @connected_feed) == :ok
    assert OperationalStatus.market_feed_gate(@disabled_market, @unavailable_feed) == :ok

    assert OperationalStatus.market_feed_gate(@fresh_market, @disconnected_feed) ==
             {:halted, :feed_disconnected}

    assert OperationalStatus.market_feed_gate(@stale_market, @connected_feed) ==
             {:halted, :stale_market_data}

    health = Health.build_ready(:ok, :ready, :dry_run, @fresh_market, @disconnected_feed)
    assert health.reason == :feed_disconnected
    refute health.healthy?

    health = Health.build_ready(:ok, :ready, :dry_run, @fresh_market, @connected_feed)
    assert health.status == :ready
  end

  test "market_feed_gate treats missing keys as fail-closed" do
    # enabled? 欠落 → 有効扱い → Feed を見る
    assert OperationalStatus.market_feed_gate(%{all_fresh?: true}, @disconnected_feed) ==
             {:halted, :feed_disconnected}

    # all_fresh? 欠落 → stale
    assert OperationalStatus.market_feed_gate(%{enabled?: true}, @connected_feed) ==
             {:halted, :stale_market_data}

    # 明示 disabled のみスキップ
    assert OperationalStatus.market_feed_gate(%{enabled?: false}, @disconnected_feed) == :ok
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
        max_age_ms: 5_000,
        enabled?: true,
        feed_enabled?: true,
        feed_status: %{connected?: true, subscribe_count: 1, reconnect_attempt: 0}
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

  test "feed_snapshot coerces non-boolean connected? to false" do
    feed =
      OperationalStatus.feed_snapshot(
        feed_enabled?: true,
        feed_status: %{
          connected?: "yes",
          subscribe_count: 0,
          reconnect_attempt: 0
        }
      )

    refute feed.connected?
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

  test "snapshot includes feed metrics from explicit feed override" do
    assert Readiness.mark_ready() == :ok

    status =
      OperationalStatus.snapshot(
        trade_mode: :dry_run,
        live_confirmed?: false,
        market_data: @fresh_market,
        feed: @disconnected_feed
      )

    refute status.orders_allowed?
    assert status.orders_reason == :feed_disconnected
    refute status.feed.connected?
    assert status.feed.subscribe_count == 1
    assert status.feed.reconnect_attempt == 2
  end
end
