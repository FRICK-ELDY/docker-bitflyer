defmodule Bitflyer.HealthTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Health

  @fresh_market %{
    enabled?: true,
    max_age_ms: 5_000,
    all_fresh?: true,
    entries: [
      %{product_code: "FX_BTC_JPY", key: {:ticker, "FX_BTC_JPY"}, fresh?: true, age_ms: 10}
    ]
  }

  @stale_market %{
    enabled?: true,
    max_age_ms: 5_000,
    all_fresh?: false,
    entries: [
      %{product_code: "FX_BTC_JPY", key: {:ticker, "FX_BTC_JPY"}, fresh?: false, age_ms: :miss}
    ]
  }

  @disabled_market %{
    enabled?: false,
    max_age_ms: 5_000,
    all_fresh?: false,
    entries: []
  }

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

  test "ready when db ok and readiness ready" do
    health = Health.build(:ok, :ready, :dry_run)

    assert health.status == :ready
    assert health.healthy?
    assert health.db
    assert health.reason == nil
    assert Health.to_json_map(health)["status"] == "ready"
    assert Health.to_json_map(health)["trade_mode"] == "dry_run"
    refute Map.has_key?(Health.to_json_map(health), "db_error")
    refute Map.has_key?(Health.to_json_map(health), "feed")
  end

  test "not_ready remains healthy for compose boot on legacy /health" do
    health = Health.build(:ok, :not_ready, :paper)

    assert health.status == :not_ready
    assert health.healthy?
    assert Health.to_json_map(health)["readiness"] == "not_ready"
  end

  test "database failure is unavailable and unhealthy" do
    health = Health.build({:error, "connection refused"}, :ready, :live)

    assert health.status == :unavailable
    refute health.healthy?
    refute health.db
    assert health.reason == :database_unavailable
    assert health.db_error == "connection refused"
    refute Map.has_key?(Health.to_json_map(health), "db_error")
  end

  test "non-binary database errors are stringified without crashing" do
    health = Health.build({:error, %{code: :econnrefused}}, :ready, :dry_run)

    assert health.status == :unavailable
    refute health.healthy?
    assert health.db_error == "%{code: :econnrefused}"
  end

  test "unknown readiness is treated as unavailable" do
    health = Health.build(:ok, :syncing, :dry_run)

    assert health.status == :unavailable
    refute health.healthy?
    assert health.reason == :unknown_readiness
    assert Health.to_json_map(health)["readiness"] == "unknown::syncing"
  end

  test "halted readiness is unhealthy even when db ok" do
    health = Health.build(:ok, {:halted, :reconcile_mismatch}, :live)

    assert health.status == :halted
    refute health.healthy?
    assert health.reason == :reconcile_mismatch
    assert Health.to_json_map(health)["reason"] == "reconcile_mismatch"
    assert Health.to_json_map(health)["readiness"] == "halted:reconcile_mismatch"
  end

  test "snapshot uses injectable checks" do
    health =
      Health.snapshot(
        database: fn -> {:error, "boom"} end,
        readiness: fn -> :ready end,
        trade_mode: fn -> :dry_run end
      )

    assert health.status == :unavailable
    refute health.healthy?
  end

  test "live_snapshot is always healthy" do
    health = Health.live_snapshot(trade_mode: fn -> :paper end)

    assert health.status == :live
    assert health.healthy?
    assert Health.to_json_map(health)["status"] == "live"
    assert Health.to_json_map(health)["readiness"] == "live"
    assert Health.to_json_map(health)["trade_mode"] == "paper"
  end

  test "ready_snapshot is ready when market enabled and feed connected and fresh" do
    health = Health.build_ready(:ok, :ready, :dry_run, @fresh_market, @connected_feed)

    assert health.status == :ready
    assert health.healthy?
    assert health.reason == nil

    json = Health.to_json_map(health)
    assert json["feed"]["connected"] == true
    assert json["market_data"]["all_fresh"] == true
  end

  test "ready_snapshot fails when feed is disconnected" do
    health = Health.build_ready(:ok, :ready, :dry_run, @fresh_market, @disconnected_feed)

    assert health.status == :not_ready
    refute health.healthy?
    assert health.reason == :feed_disconnected
    assert Health.to_json_map(health)["reason"] == "feed_disconnected"
  end

  test "ready_snapshot fails when feed process is unavailable" do
    health = Health.build_ready(:ok, :ready, :dry_run, @fresh_market, @unavailable_feed)

    assert health.status == :not_ready
    refute health.healthy?
    assert health.reason == :feed_unavailable
  end

  test "ready_snapshot fails when market data is stale" do
    health = Health.build_ready(:ok, :ready, :dry_run, @stale_market, @connected_feed)

    assert health.status == :not_ready
    refute health.healthy?
    assert health.reason == :stale_market_data

    assert Health.to_json_map(health)["market_data"]["entries"] == [
             %{"product_code" => "FX_BTC_JPY", "fresh" => false, "age_ms" => nil}
           ]
  end

  test "ready_snapshot skips feed and freshness when market data is disabled" do
    health = Health.build_ready(:ok, :ready, :dry_run, @disabled_market, @unavailable_feed)

    assert health.status == :ready
    assert health.healthy?
  end

  test "ready_snapshot treats boot not_ready as unhealthy" do
    health = Health.build_ready(:ok, :not_ready, :dry_run, @disabled_market, @unavailable_feed)

    assert health.status == :not_ready
    refute health.healthy?
    assert health.reason == :not_ready
  end

  test "ready_snapshot uses injectable market and feed" do
    health =
      Health.ready_snapshot(
        database: fn -> :ok end,
        readiness: fn -> :ready end,
        trade_mode: fn -> :dry_run end,
        market_data: @fresh_market,
        feed: @disconnected_feed
      )

    refute health.healthy?
    assert health.reason == :feed_disconnected
  end
end
