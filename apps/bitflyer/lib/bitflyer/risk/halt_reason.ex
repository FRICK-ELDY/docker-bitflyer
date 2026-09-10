defmodule Bitflyer.Risk.HaltReason do
  @moduledoc """
  RiskState に永続化する halt 理由の文字列 ↔ atom 変換。

  Circuit / Reconcile の双方がここを正本とする（Risk→Startup 依存を避ける）。
  """

  @known MapSet.new([
           :reconcile_mismatch,
           :restore_failed,
           :exchange_unavailable,
           :invalid_exchange_payload,
           :risk_halted,
           :unsafe_api_permissions,
           :clock_skew,
           :auth_failed,
           :consecutive_exchange_errors,
           :submission_unknown,
           :manual_halt,
           :persist_failed,
           :daily_loss_exceeded
         ])

  @type t :: atom()

  @doc """
  既知の永続 halt 理由か。
  """
  @spec known?(atom()) :: boolean()
  def known?(reason) when is_atom(reason), do: MapSet.member?(@known, reason)

  @doc """
  永続化された停止理由文字列を Readiness 用 atom にする。
  未知・不正は `:risk_halted`（`String.to_atom/1` は使わない）。
  """
  @spec from_string(String.t() | nil) :: t()
  def from_string(nil), do: :risk_halted

  def from_string(reason) when is_binary(reason) do
    try do
      atom = String.to_existing_atom(reason)

      if MapSet.member?(@known, atom) do
        atom
      else
        :risk_halted
      end
    rescue
      ArgumentError -> :risk_halted
    end
  end

  @doc """
  Readiness halt 理由を RiskState 用文字列にする。
  未知 atom は `"reconcile_mismatch"`（従来の Reconcile 互換）。
  """
  @spec to_string(t()) :: String.t()
  def to_string(reason) when is_atom(reason) do
    if MapSet.member?(@known, reason) do
      Atom.to_string(reason)
    else
      "reconcile_mismatch"
    end
  end
end
