defmodule Bitflyer.ReadinessTest do
  use ExUnit.Case, async: false

  alias Bitflyer.Readiness

  setup do
    reset_to_not_ready()

    on_exit(fn ->
      reset_to_not_ready()
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

  defp reset_to_not_ready do
    case Readiness.get() do
      {:halted, _} ->
        assert Readiness.clear_halt() == :ok

      :ready ->
        assert Readiness.mark_not_ready() == :ok

      :not_ready ->
        :ok
    end
  end
end
