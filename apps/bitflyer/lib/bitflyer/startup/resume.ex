defmodule Bitflyer.Startup.Resume do
  @moduledoc """
  halted からの手動復帰。

  再突合が成功したときだけサーキットを閉じ、Ready にする。
  定期突合（`Reconciler`）は halted を自動解除しない。こちらが唯一の復帰入口。
  """

  alias Bitflyer.Risk.Circuit
  alias Bitflyer.Startup.Reconcile

  @type result :: :ok | {:error, atom()} | {:error, atom(), map()}

  @doc """
  再突合 → 成功時のみ `Circuit.close` → `mark_ready`。

  ## Options
  - `:trade_mode` / `:exchange` / `:required_balance_currencies` — `Reconcile.run/1` へ転送
  - `:readiness` — 既定 `Bitflyer.Readiness`
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    cond do
      match?({:halted, _}, readiness.get()) ->
        do_resume(opts)

      Circuit.open?(readiness: readiness) ->
        do_resume(opts)

      true ->
        {:error, :not_halted}
    end
  end

  defp do_resume(opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    halt_reason =
      case readiness.get() do
        {:halted, reason} -> reason
        _ -> :risk_halted
      end

    reconcile_opts =
      opts
      |> Keyword.take([:trade_mode, :exchange, :required_balance_currencies])
      |> Keyword.put(:skip_persisted_risk?, true)

    case Reconcile.run(reconcile_opts) do
      {:ok, _internal} ->
        finish_resume(halt_reason, opts)

      {:error, reason, details} ->
        Bitflyer.Telemetry.log(:warning, "resume reconcile failed", %{
          reason: reason,
          trade_mode: Bitflyer.TradeMode.current()
        })

        {:error, reason, details}
    end
  end

  defp finish_resume(halt_reason, opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)
    circuit_opts = Keyword.take(opts, [:readiness])

    with :ok <- Circuit.close(circuit_opts),
         :ok <- mark_ready(readiness) do
      Bitflyer.Telemetry.log(:info, "resume succeeded", %{
        reason: halt_reason,
        readiness: "ready",
        trade_mode: Bitflyer.TradeMode.current()
      })

      :ok
    else
      {:error, error} ->
        Bitflyer.Telemetry.log(:error, "resume close/ready failed", %{
          reason: :resume_finalize_failed,
          trade_mode: Bitflyer.TradeMode.current()
        })

        {:error, :resume_finalize_failed, %{detail: error}}
    end
  end

  defp mark_ready(readiness) do
    case readiness.mark_ready() do
      :ok -> :ok
      {:error, state} -> {:error, state}
    end
  end
end
