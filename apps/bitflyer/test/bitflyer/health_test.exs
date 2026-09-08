defmodule Bitflyer.HealthTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Health

  test "ready when db ok and readiness ready" do
    health = Health.build(:ok, :ready, :dry_run)

    assert health.status == :ready
    assert health.healthy?
    assert health.db
    assert health.reason == nil
    assert Health.to_json_map(health)["status"] == "ready"
    assert Health.to_json_map(health)["trade_mode"] == "dry_run"
  end

  test "not_ready remains healthy for compose boot" do
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
    assert Health.to_json_map(health)["db_error"] == "connection refused"
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
end
