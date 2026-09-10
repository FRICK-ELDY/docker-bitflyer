defmodule Bitflyer.TelemetryTest do
  use ExUnit.Case, async: false

  alias Bitflyer.Telemetry

  setup do
    handler_id = "bitflyer-telemetry-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        Map.values(Telemetry.events()),
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, handler_id: handler_id}
  end

  test "events/0 locks the domain vocabulary" do
    events = Telemetry.events()

    assert events.market_data_tick == [:bitflyer, :market_data, :tick]
    assert events.risk_rejected == [:bitflyer, :risk, :rejected]
    assert events.order_submitted == [:bitflyer, :order, :submitted]
    assert events.order_filled == [:bitflyer, :order, :filled]
    assert events.reconcile_mismatch == [:bitflyer, :reconcile, :mismatch]
    assert events.circuit_opened == [:bitflyer, :circuit, :opened]
    assert events.readiness_changed == [:bitflyer, :readiness, :changed]
    assert events.health_unhealthy == [:bitflyer, :health, :unhealthy]

    assert "bitflyer.readiness.changed.count" in Telemetry.metric_names()
    assert "bitflyer.health.unhealthy.count" in Telemetry.metric_names()
  end

  test "sanitize_metadata keeps allowlist and drops secrets" do
    sanitized =
      Telemetry.sanitize_metadata(%{
        trade_mode: :dry_run,
        reason: :reconcile_mismatch,
        kind: :balance_mismatch,
        currency: "JPY",
        limit: :max_order_size,
        api_key: "SHOULD_NOT_LEAK",
        password: "secret",
        webhook_url: "https://example.invalid",
        unknown_field: "drop-me"
      })

    assert sanitized == %{
             trade_mode: :dry_run,
             reason: :reconcile_mismatch,
             kind: :balance_mismatch,
             currency: "JPY",
             limit: :max_order_size
           }
  end

  test "diagnostic keys stay on allowlist and logger metadata" do
    allowlist = Telemetry.metadata_allowlist()
    logger_metadata = Application.get_env(:logger, :default_formatter)[:metadata] || []

    for key <- [:kind, :currency, :limit, :operator, :snapshot_hash] do
      assert MapSet.member?(allowlist, key)
      assert key in logger_metadata
    end
  end

  test "execute emits filtered metadata only" do
    assert :ok =
             Telemetry.execute(:order_submitted, %{count: 1}, %{
               trade_mode: :paper,
               internal_order_id: "ord-1",
               api_secret: "nope",
               authorization: "Bearer x"
             })

    assert_receive {:telemetry, [:bitflyer, :order, :submitted], %{count: 1}, metadata}
    assert metadata.trade_mode == :paper
    assert metadata.internal_order_id == "ord-1"
    refute Map.has_key?(metadata, :api_secret)
    refute Map.has_key?(metadata, :authorization)
  end

  test "reconcile_mismatch keeps kind and currency" do
    assert :ok =
             Telemetry.execute(:reconcile_mismatch, %{count: 1}, %{
               reason: :reconcile_mismatch,
               kind: :position_mismatch,
               currency: "BTC",
               product_code: "FX_BTC_JPY",
               api_key: "nope"
             })

    assert_receive {:telemetry, [:bitflyer, :reconcile, :mismatch], %{count: 1}, metadata}
    assert metadata.kind == :position_mismatch
    assert metadata.currency == "BTC"
    assert metadata.product_code == "FX_BTC_JPY"
    refute Map.has_key?(metadata, :api_key)
  end
end
