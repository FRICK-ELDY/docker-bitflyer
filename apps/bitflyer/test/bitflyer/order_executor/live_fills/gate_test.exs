defmodule Bitflyer.OrderExecutor.LiveFills.GateTest do
  use ExUnit.Case, async: false

  alias Bitflyer.OrderExecutor.LiveFills.Gate

  setup do
    name = :"live_fills_gate_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Gate, name: name})
    %{gate: name, gate_pid: pid}
  end

  test "holder crash auto-releases slot", %{gate: gate, gate_pid: gate_pid} do
    parent = self()

    holder =
      spawn(fn ->
        assert :run = Gate.begin(false, 0, server: gate)
        send(parent, :holding)
        Process.sleep(:infinity)
      end)

    assert_receive :holding, 1_000
    mon = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^mon, :process, ^holder, _}, 1_000
    _ = :sys.get_state(gate_pid)

    # busy は解放済み。時計は残るので now を進める
    assert :run = Gate.begin(false, 1_000, server: gate)
    assert :ok = Gate.release(server: gate)
  end

  test "force waiter crash is dropped so release does not stick busy", %{
    gate: gate,
    gate_pid: gate_pid
  } do
    parent = self()

    holder =
      spawn(fn ->
        assert :run = Gate.begin(false, 0, server: gate)
        send(parent, :holding)

        receive do
          :release -> Gate.release(server: gate)
        end
      end)

    assert_receive :holding, 1_000

    waiter =
      spawn(fn ->
        Gate.begin(true, 1, server: gate)
      end)

    assert wait_until(fn -> :queue.len(:sys.get_state(gate_pid).waiters) == 1 end)

    mon = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^mon, :process, ^waiter, _}, 1_000
    _ = :sys.get_state(gate_pid)
    assert :queue.len(:sys.get_state(gate_pid).waiters) == 0

    send(holder, :release)
    _ = :sys.get_state(gate_pid)

    assert :run = Gate.begin(true, 2, server: gate)
    assert :ok = Gate.release(server: gate)
  end

  test "stale release from previous holder does not clear new holder", %{gate: gate} do
    parent = self()

    previous =
      spawn(fn ->
        assert :run = Gate.begin(false, 0, server: gate)
        send(parent, :previous_holding)

        receive do
          :handoff ->
            Gate.release(server: gate)
            send(parent, :previous_released)

            receive do
              :stale_release -> Gate.release(server: gate)
            end
        end
      end)

    assert_receive :previous_holding, 1_000

    next =
      spawn(fn ->
        send(parent, :next_waiting)
        assert :run = Gate.begin(true, 1, server: gate)
        send(parent, :next_holding)

        receive do
          :done -> Gate.release(server: gate)
        end
      end)

    assert_receive :next_waiting, 1_000
    send(previous, :handoff)
    assert_receive :previous_released, 1_000
    assert_receive :next_holding, 1_000

    send(previous, :stale_release)
    _ = :sys.get_state(gate)

    assert :skip = Gate.begin(false, 1, server: gate)
    send(next, :done)
  end

  defp wait_until(fun, attempts \\ 50) when is_function(fun, 0) do
    Enum.any?(1..attempts, fn _ ->
      if fun.() do
        true
      else
        Process.sleep(10)
        false
      end
    end)
  end
end
