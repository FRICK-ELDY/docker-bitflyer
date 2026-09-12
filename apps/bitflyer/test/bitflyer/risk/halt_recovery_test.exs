defmodule Bitflyer.Risk.HaltRecoveryTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Risk.{HaltReason, HaltRecovery}

  test "nil has no steps" do
    assert HaltRecovery.steps(nil) == []
  end

  test "every known halt reason has non-empty steps" do
    for reason <- [
          :reconcile_mismatch,
          :restore_failed,
          :exchange_unavailable,
          :invalid_exchange_payload,
          :risk_halted,
          :unsafe_api_permissions,
          :clock_skew,
          :auth_failed,
          :consecutive_exchange_errors,
          :failure_rate_unsynced,
          :submission_unknown,
          :manual_halt,
          :persist_failed,
          :fill_sync_failed,
          :daily_loss_exceeded,
          :daily_drawdown_exceeded,
          :fill_price_unavailable
        ] do
      assert HaltReason.known?(reason)
      assert HaltRecovery.steps(reason) != []
    end
  end

  test "manual halt points at Status Resume" do
    assert :resume_on_status in HaltRecovery.steps(:manual_halt)
  end

  test "reconcile mismatch asks to reconcile before resume" do
    steps = HaltRecovery.steps(:reconcile_mismatch)
    assert :reconcile_now in steps
    assert :resume_on_status in steps
  end

  test "submission_unknown requires recover before resume" do
    steps = HaltRecovery.steps(:submission_unknown)
    assert :recover_submission in steps
    assert :resume_on_status in steps
  end

  test "daily loss and drawdown warn not to resume while over limit" do
    assert :do_not_resume_while_over_limit in HaltRecovery.steps(:daily_loss_exceeded)
    assert :do_not_resume_while_over_drawdown in HaltRecovery.steps(:daily_drawdown_exceeded)
  end

  test "unknown atom still has generic steps" do
    assert HaltRecovery.steps(:not_a_known_halt) == [
             :identify_underlying_reason,
             :reconcile_now,
             :resume_on_status
           ]
  end
end
