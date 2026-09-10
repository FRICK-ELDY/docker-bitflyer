defmodule Bitflyer.Risk.FailureRateTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.FailureRateHelper

  alias Bitflyer.Risk.FailureRate

  setup do
    reset_failure_rate()

    on_exit(fn ->
      reset_failure_rate()
    end)

    :ok
  end

  test "auth_failed evaluates to immediate halt without counting" do
    assert FailureRate.evaluate(:auth_failed) == {:halt, :auth_failed}
    assert FailureRate.count(:live) == 0
  end

  test "rejected_by_exchange counts and halts at max_errors" do
    opts = [trade_mode: :live, max_errors: 3, window_ms: 60_000]

    assert :ok = FailureRate.evaluate(:rejected_by_exchange, opts)
    assert FailureRate.count(:live, window_ms: 60_000) == 1

    assert :ok = FailureRate.evaluate(:rejected_by_exchange, opts)

    assert {:halt, :consecutive_exchange_errors} =
             FailureRate.evaluate(:rejected_by_exchange, opts)

    assert FailureRate.count(:live, window_ms: 60_000) == 3
  end

  test "timeout and unknown reasons do not count" do
    assert :ok = FailureRate.evaluate(:timeout)
    assert :ok = FailureRate.evaluate(:disconnected)
    assert :ok = FailureRate.evaluate(:order_not_found)
    assert :ok = FailureRate.evaluate(:something_else)
    assert FailureRate.count(:live) == 0
  end

  test "entries outside the window are pruned from count" do
    now = FailureRate.monotonic_ms()
    assert :ok = FailureRate.record(:live, now: now - 70_000, window_ms: 60_000)
    assert :ok = FailureRate.record(:live, now: now - 10_000, window_ms: 60_000)

    assert FailureRate.count(:live, now: now, window_ms: 60_000) == 1
  end
end
