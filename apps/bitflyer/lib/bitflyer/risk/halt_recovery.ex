defmodule Bitflyer.Risk.HaltRecovery do
  @moduledoc """
  halt 理由ごとの復帰手順（Status 表示用の atom ステップ）。

  文言は UI gettext。ここでは順序とキーだけを返す。
  Resume は再突合成功かつ Equity が閾値内のときだけ通る。
  """

  @type step :: atom()

  @doc """
  既知の halt 理由に対する手順。未 halt（`nil`）は空。
  未知 atom は汎用手順。
  """
  @spec steps(atom() | nil) :: [step()]
  def steps(nil), do: []

  def steps(:manual_halt), do: [:confirm_safe, :resume_on_status]

  def steps(:reconcile_mismatch),
    do: [:read_mismatch_logs, :reconcile_now, :fix_drift, :resume_on_status]

  def steps(:submission_unknown),
    do: [:inspect_unknown_orders, :recover_submission, :resume_on_status]

  def steps(:daily_loss_exceeded),
    do: [:do_not_resume_while_over_limit, :wait_jst_or_flatten, :resume_after_limit_clears]

  def steps(:daily_drawdown_exceeded),
    do: [
      :do_not_resume_while_over_drawdown,
      :wait_marks_or_flatten,
      :resume_after_drawdown_clears
    ]

  def steps(:persist_failed), do: [:check_risk_state_persist, :repersist_then_resume]

  def steps(:fill_sync_failed), do: [:check_fill_sync_logs, :reconcile_now, :resume_on_status]

  def steps(:fill_price_unavailable),
    do: [:check_fill_pricing, :reconcile_now, :resume_on_status]

  def steps(:restore_failed), do: [:check_risk_state_restore, :fix_db_restart_resume]

  def steps(:exchange_unavailable),
    do: [:check_exchange_connectivity, :reconcile_now, :resume_on_status]

  def steps(:invalid_exchange_payload),
    do: [:inspect_payload_logs, :do_not_resume_until_decode_ok, :resume_on_status]

  def steps(:risk_halted), do: [:identify_underlying_reason, :reconcile_now, :resume_on_status]

  def steps(:unsafe_api_permissions), do: [:fix_api_permissions, :restart_then_resume]

  def steps(:clock_skew), do: [:fix_host_clock, :resume_on_status]

  def steps(:auth_failed), do: [:check_api_credentials, :resume_on_status]

  def steps(:consecutive_exchange_errors),
    do: [:check_exchange_error_logs, :reconcile_now, :resume_on_status]

  def steps(:failure_rate_unsynced), do: [:reload_or_restart, :resume_on_status]

  def steps(reason) when is_atom(reason),
    do: [:identify_underlying_reason, :reconcile_now, :resume_on_status]
end
