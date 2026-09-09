defmodule Bitflyer.ReadinessTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness

  setup do
    reset_readiness()

    on_exit(fn ->
      reset_readiness()
    end)

    :ok
  end

  test "starts as not_ready and does not allow orders" do
    assert Readiness.get() == :not_ready
    refute Readiness.ready?()
    refute Readiness.allow_orders?()
    assert Readiness.gate() == {:error, :not_ready}
    assert Readiness.format(:not_ready) == "not_ready"
  end

  test "reads current state from ETS without requiring a write call" do
    assert Readiness.mark_ready() == :ok
    assert :ets.lookup_element(Readiness, :state, 2) == :ready
    assert Readiness.get() == :ready
  end

  test "mark_ready opens the gate until mark_not_ready" do
    assert Readiness.mark_ready() == :ok
    assert Readiness.get() == :ready
    assert Readiness.ready?()
    assert Readiness.allow_orders?()
    assert Readiness.gate() == :ok
    assert Readiness.format(:ready) == "ready"

    assert Readiness.mark_not_ready() == :ok
    assert Readiness.get() == :not_ready
    refute Readiness.allow_orders?()
  end

  test "halt blocks mark_ready until clear_halt" do
    assert Readiness.mark_ready() == :ok
    assert Readiness.halt(:reconcile_mismatch) == :ok
    assert Readiness.get() == {:halted, :reconcile_mismatch}
    assert Readiness.gate() == {:halted, :reconcile_mismatch}
    assert Readiness.format({:halted, :reconcile_mismatch}) == "halted:reconcile_mismatch"

    assert Readiness.mark_ready() == {:error, {:halted, :reconcile_mismatch}}
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert Readiness.mark_not_ready() == :ok
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert Readiness.clear_halt() == :ok
    assert Readiness.get() == :not_ready
    assert Readiness.mark_ready() == :ok
    assert Readiness.get() == :ready
  end

  test "clear_halt on non-halted returns error" do
    assert Readiness.clear_halt() == {:error, :not_halted}
    assert Readiness.mark_ready() == :ok
    assert Readiness.clear_halt() == {:error, :not_halted}
  end

  test "state transitions emit readiness_changed telemetry" do
    parent = self()
    handler_id = "readiness-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :readiness, :changed],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert Readiness.mark_ready() == :ok

    assert_receive {:telemetry, [:bitflyer, :readiness, :changed], %{count: 1}, metadata}
    assert metadata.from == "not_ready"
    assert metadata.to == "ready"
    assert metadata.trade_mode == :dry_run
  end

  test "identical halt does not re-emit readiness_changed" do
    parent = self()
    handler_id = "readiness-halt-idempotent-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :readiness, :changed],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert Readiness.halt(:reconcile_mismatch) == :ok
    assert_receive {:telemetry, [:bitflyer, :readiness, :changed], _, _}

    assert Readiness.halt(:reconcile_mismatch) == :ok
    refute_receive {:telemetry, [:bitflyer, :readiness, :changed], _, _}, 50
  end

  test "mark_not_ready_safe is no-op when Readiness process is missing" do
    assert :ok = Readiness.mark_not_ready_safe(Bitflyer.Readiness.DoesNotExist)
  end
end
