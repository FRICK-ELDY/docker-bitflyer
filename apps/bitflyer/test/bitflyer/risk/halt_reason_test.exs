defmodule Bitflyer.Risk.HaltReasonTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Risk.HaltReason

  test "from_string maps known persisted reasons without collapsing" do
    assert HaltReason.from_string("persist_failed") == :persist_failed
    assert HaltReason.from_string("fill_sync_failed") == :fill_sync_failed
    assert HaltReason.from_string("daily_loss_exceeded") == :daily_loss_exceeded
    assert HaltReason.from_string("daily_drawdown_exceeded") == :daily_drawdown_exceeded
    assert HaltReason.from_string("manual_halt") == :manual_halt
    assert HaltReason.from_string("submission_unknown") == :submission_unknown
    assert HaltReason.from_string("fill_price_unavailable") == :fill_price_unavailable
    assert HaltReason.from_string("failure_rate_unsynced") == :failure_rate_unsynced
  end

  test "from_string collapses unknown and nil to risk_halted" do
    assert HaltReason.from_string(nil) == :risk_halted
    assert HaltReason.from_string("not_a_real_halt_reason") == :risk_halted
  end

  test "to_string round-trips known reasons" do
    assert HaltReason.to_string(:persist_failed) == "persist_failed"
    assert HaltReason.to_string(:fill_sync_failed) == "fill_sync_failed"
    assert HaltReason.to_string(:daily_loss_exceeded) == "daily_loss_exceeded"
    assert HaltReason.to_string(:daily_drawdown_exceeded) == "daily_drawdown_exceeded"
    assert HaltReason.to_string(:manual_halt) == "manual_halt"
    assert HaltReason.to_string(:fill_price_unavailable) == "fill_price_unavailable"
  end

  test "to_string falls back for unknown atoms" do
    assert HaltReason.to_string(:totally_unknown_halt_xyz) == "reconcile_mismatch"
  end

  test "Reconcile delegates to HaltReason" do
    assert Bitflyer.Startup.Reconcile.reason_from_string("persist_failed") == :persist_failed

    assert Bitflyer.Startup.Reconcile.reason_to_string(:daily_loss_exceeded) ==
             "daily_loss_exceeded"
  end
end
