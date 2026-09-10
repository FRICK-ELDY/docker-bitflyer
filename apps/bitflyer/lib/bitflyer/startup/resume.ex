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
  - `:readiness` — 既定 `Bitflyer.Readiness`（Reconcile には渡さない）
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    if Circuit.open?(readiness: readiness) do
      do_resume(opts)
    else
      {:error, :not_halted}
    end
  end

  defp do_resume(opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    halt_reason =
      case readiness.get() do
        {:halted, reason} -> reason
        _ -> :risk_halted
      end

    reconcile_opts =
      opts
      |> Keyword.delete(:readiness)
      |> Keyword.put(:skip_persisted_risk?, true)
      |> Keyword.put(:trade_mode, trade_mode)

    case Reconcile.run(reconcile_opts) do
      {:ok, internal} ->
        # force 禁止: in-flight invalidate を synced に戻さない
        case Bitflyer.Risk.DailyLoss.reload(trade_mode: trade_mode) do
          :ok ->
            sync_balances_then_finish(halt_reason, trade_mode, internal, opts)

          {:ok, :deferred} ->
            Bitflyer.Telemetry.log(:warning, "resume blocked: daily loss barrier held", %{
              trade_mode: trade_mode
            })

            {:error, :daily_loss_barrier, %{reason: :deferred}}

          {:error, reason} ->
            Bitflyer.Telemetry.log(:error, "resume daily loss reload failed", %{
              reason: inspect(reason),
              trade_mode: trade_mode
            })

            {:error, :daily_loss_unsynced, %{reason: reason}}
        end

      {:error, reason, details} ->
        Bitflyer.Telemetry.log(:warning, "resume reconcile failed", %{
          reason: reason,
          trade_mode: trade_mode
        })

        {:error, reason, details}
    end
  end

  defp sync_balances_then_finish(halt_reason, :dry_run, _internal, opts) do
    _ = Bitflyer.Risk.BalanceCache.refresh(:dry_run)
    finish_resume(halt_reason, :dry_run, opts)
  end

  defp sync_balances_then_finish(halt_reason, :live, %{exchange_balances: balances}, opts)
       when is_map(balances) do
    case Bitflyer.Risk.BalanceCache.put(:live, balances, clear_holds: true) do
      :ok ->
        finish_resume(halt_reason, :live, opts)

      {:ok, :deferred} ->
        Bitflyer.Telemetry.log(:warning, "resume blocked: balance cache barrier held", %{
          trade_mode: :live
        })

        {:error, :balance_barrier, %{reason: :deferred}}

      {:error, reason} ->
        Bitflyer.Telemetry.log(:error, "resume balance cache put failed", %{
          reason: inspect(reason),
          trade_mode: :live
        })

        {:error, :balance_unsynced, %{reason: reason}}
    end
  end

  defp sync_balances_then_finish(_halt_reason, :live, _internal, _opts) do
    Bitflyer.Telemetry.log(:error, "resume missing exchange balances after live reconcile", %{
      trade_mode: :live
    })

    _ = Bitflyer.Risk.BalanceCache.mark_unsynced(:live)
    {:error, :balance_unsynced, %{reason: :exchange_balances_missing}}
  end

  defp sync_balances_then_finish(halt_reason, trade_mode, _internal, opts) do
    case Bitflyer.Risk.BalanceCache.refresh(trade_mode) do
      :ok ->
        finish_resume(halt_reason, trade_mode, opts)

      {:ok, :deferred} ->
        Bitflyer.Telemetry.log(:warning, "resume blocked: balance cache barrier held", %{
          trade_mode: trade_mode
        })

        {:error, :balance_barrier, %{reason: :deferred}}

      {:error, reason} ->
        Bitflyer.Telemetry.log(:error, "resume balance cache refresh failed", %{
          reason: inspect(reason),
          trade_mode: trade_mode
        })

        {:error, :balance_unsynced, %{reason: reason}}
    end
  end

  defp finish_resume(halt_reason, trade_mode, opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)
    circuit_opts = Keyword.take(opts, [:readiness])

    with :ok <- Circuit.close(circuit_opts),
         :ok <- mark_ready(readiness) do
      Bitflyer.Telemetry.log(:info, "resume succeeded", %{
        reason: halt_reason,
        readiness: "ready",
        trade_mode: trade_mode
      })

      :ok
    else
      {:error, error} ->
        Bitflyer.Telemetry.log(:error, "resume close/ready failed", %{
          reason: :resume_finalize_failed,
          trade_mode: trade_mode
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
