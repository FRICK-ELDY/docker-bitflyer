defmodule Bitflyer.OrderExecutor.InFlightTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.InFlightHelper

  alias Bitflyer.OrderExecutor.InFlight

  setup do
    reset_inflight()

    on_exit(fn ->
      reset_inflight()
    end)

    :ok
  end

  test "empty drain returns ok immediately" do
    assert :ok = InFlight.drain(timeout_ms: 100)
    assert {:error, :closed} = InFlight.track(%{kind: :submit})
  end

  test "drain waits until last untrack" do
    parent = self()

    worker =
      Task.async(fn ->
        assert {:ok, ref} = InFlight.track(%{kind: :submit, internal_order_id: "a"})
        send(parent, :tracked)

        receive do
          :release -> :ok
        end

        assert :ok = InFlight.untrack(ref)
        :done
      end)

    assert_receive :tracked

    stopper =
      Task.async(fn ->
        InFlight.drain(timeout_ms: 2_000)
      end)

    refute match?({:ok, _}, Task.yield(stopper, 30))
    send(worker.pid, :release)

    assert Task.await(worker) == :done
    assert Task.await(stopper) == :ok
    assert InFlight.count() == 0
  end

  test "drain timeout returns leftovers" do
    assert {:ok, ref} = InFlight.track(%{kind: :cancel, internal_order_id: "b"})

    assert {:error, :timeout, [entry]} = InFlight.drain(timeout_ms: 30)
    assert entry.kind == :cancel
    assert entry.internal_order_id == "b"
    assert entry.ref == ref

    assert :ok = InFlight.untrack(ref)
    assert InFlight.count() == 0
  end

  test "DOWN removes abandoned track and completes drain" do
    parent = self()

    {:ok, worker} =
      Task.start(fn ->
        {:ok, _ref} = InFlight.track(%{kind: :submit})
        send(parent, :tracked)

        receive do
          :block -> :ok
        end
      end)

    assert_receive :tracked

    stopper =
      Task.async(fn ->
        InFlight.drain(timeout_ms: 2_000)
      end)

    true = Process.exit(worker, :kill)
    assert Task.await(stopper) == :ok
    assert InFlight.count() == 0
  end
end
