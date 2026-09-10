defmodule Bitflyer.System do
  @moduledoc """
  開発・稼働確認用の Domain。取引エンティティは置かない。
  """
  use Ash.Domain,
    otp_app: :bitflyer

  resources do
    resource Bitflyer.System.Heartbeat
  end

  @doc """
  Repo 経由で PostgreSQL に到達できるか確認する。
  """
  def check_database do
    try do
      case Ecto.Adapters.SQL.query(Bitflyer.Repo, "SELECT 1", [], timeout: 2_000) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, Exception.message(error)}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, "Database repo is not running: #{inspect(reason)}"}
    end
  end

  @doc """
  現在の取引モード（`:dry_run` / `:paper` / `:live`）。
  """
  def trade_mode do
    Bitflyer.TradeMode.current()
  end

  @doc """
  稼働スナップショット（DB + readiness + trade mode）。`GET /health` 互換。
  """
  def health(opts \\ []) do
    Bitflyer.Health.snapshot(opts)
  end

  @doc """
  プロセス生存スナップショット。`GET /health/live`。
  """
  def health_live(opts \\ []) do
    Bitflyer.Health.live_snapshot(opts)
  end

  @doc """
  外形 readiness（DB + Ready + Feed/鮮度）。`GET /health/ready`。
  """
  def health_ready(opts \\ []) do
    Bitflyer.Health.ready_snapshot(opts)
  end

  @doc """
  運用画面向けスナップショット（発注可否・鮮度・モード）。
  """
  def operational_status(opts \\ []) do
    Bitflyer.OperationalStatus.snapshot(opts)
  end

  @doc """
  Ready 状態の正本（`:not_ready` / `:ready` / `{:halted, reason}`）。
  """
  def readiness do
    Bitflyer.Readiness.get()
  end

  @doc """
  Ready か。
  """
  def ready? do
    Bitflyer.Readiness.ready?()
  end

  @doc """
  取引所への実発注が許可されているか（live + 二重確認 + Ready）。
  """
  def exchange_orders_permitted? do
    Bitflyer.TradeMode.exchange_orders_permitted?()
  end

  @doc """
  発注ゲート。`:ok` または `{:halted, reason}`。
  """
  def exchange_order_gate do
    Bitflyer.TradeMode.exchange_order_gate()
  end

  @doc """
  起動・定期と同じ突合をいま実行する。

  ## Options
  - `:operator` — 操作者（ログ用。StatusLive / mix）
  """
  def reconcile_now(opts \\ []) do
    operator = Keyword.get(opts, :operator, "unknown")

    Bitflyer.Telemetry.log(:info, "reconcile_now requested", %{
      operator: operator,
      trade_mode: Bitflyer.TradeMode.current()
    })

    case Bitflyer.Startup.Reconciler.run_now() do
      :ok = ok ->
        Bitflyer.Telemetry.log(:info, "reconcile_now succeeded", %{
          operator: operator,
          trade_mode: Bitflyer.TradeMode.current()
        })

        ok

      {:error, reason} = error ->
        Bitflyer.Telemetry.log(:warning, "reconcile_now failed", %{
          operator: operator,
          reason: reason,
          trade_mode: Bitflyer.TradeMode.current()
        })

        error
    end
  end

  @doc """
  halted からの手動復帰。再突合成功時のみサーキット解除 → Ready。

  ## Options
  - `:operator` — 操作者（ログ用）
  - その他は `Startup.Resume.run/1` へ転送
  """
  def resume(opts \\ []) do
    operator = Keyword.get(opts, :operator, "unknown")
    resume_opts = Keyword.delete(opts, :operator)

    Bitflyer.Telemetry.log(:info, "resume requested", %{
      operator: operator,
      trade_mode: Bitflyer.TradeMode.current()
    })

    case Bitflyer.Startup.Resume.run(resume_opts) do
      :ok = ok ->
        Bitflyer.Telemetry.log(:info, "resume succeeded", %{
          operator: operator,
          readiness: "ready",
          trade_mode: Bitflyer.TradeMode.current()
        })

        ok

      {:error, :not_halted} = error ->
        Bitflyer.Telemetry.log(:warning, "resume failed: not halted", %{
          operator: operator,
          reason: :not_halted,
          trade_mode: Bitflyer.TradeMode.current()
        })

        error

      {:error, reason, _details} = error ->
        Bitflyer.Telemetry.log(:warning, "resume failed", %{
          operator: operator,
          reason: reason,
          trade_mode: Bitflyer.TradeMode.current()
        })

        error

      {:error, reason} = error ->
        Bitflyer.Telemetry.log(:warning, "resume failed", %{
          operator: operator,
          reason: reason,
          trade_mode: Bitflyer.TradeMode.current()
        })

        error
    end
  end

  @doc """
  運用 kill switch。即サーキットを開き発注を止める（永続化あり）。

  既に ETS または永続 RiskState で halted のときは reason を上書きしない
  （別 BEAM の Mix が `submission_unknown` 等を `manual_halt` に潰さない）。
  ETS は止まったが RiskState 永続化だけ失敗した場合は `{:ok, :persist_failed}`。

  ## Options
  - `:reason` — 既定 `:manual_halt`（未 halt 時のみ使用）
  - `:operator` — 操作者（ログ用）
  """
  def halt_trading(opts \\ []) do
    reason = Keyword.get(opts, :reason, :manual_halt)
    operator = Keyword.get(opts, :operator, "unknown")
    trade_mode = Bitflyer.TradeMode.current()

    case Bitflyer.Readiness.get() do
      {:halted, existing} ->
        Bitflyer.Telemetry.log(:info, "manual halt skipped: already halted", %{
          operator: operator,
          reason: existing,
          trade_mode: trade_mode
        })

        :ok

      _ ->
        case Bitflyer.Risk.Circuit.persisted_halt_reason() do
          {:halted, existing} ->
            # 別 BEAM で DB だけ halt 済み — ローカル ETS を揃え、DB reason は維持
            _ = Bitflyer.Readiness.halt(existing)

            Bitflyer.Telemetry.log(:info, "manual halt synced from persisted RiskState", %{
              operator: operator,
              reason: existing,
              trade_mode: trade_mode
            })

            :ok

          other when other in [:clear, :unsynced] ->
            Bitflyer.Telemetry.log(:critical, "manual halt requested", %{
              operator: operator,
              reason: reason,
              trade_mode: trade_mode
            })

            case Bitflyer.Risk.open_circuit(reason) do
              :ok ->
                Bitflyer.Telemetry.log(:critical, "manual halt applied", %{
                  operator: operator,
                  reason: reason,
                  trade_mode: trade_mode
                })

                :ok

              {:error, error} ->
                if match?({:halted, _}, Bitflyer.Readiness.get()) do
                  Bitflyer.Telemetry.log(:error, "manual halt ets applied but persist failed", %{
                    operator: operator,
                    reason: reason,
                    trade_mode: trade_mode
                  })

                  {:ok, :persist_failed}
                else
                  Bitflyer.Telemetry.log(:error, "manual halt failed", %{
                    operator: operator,
                    reason: reason,
                    trade_mode: trade_mode
                  })

                  {:error, error}
                end
            end
        end
    end
  end

  @doc """
  live 初回 BalanceSnapshot baseline の承認付き import（Ready にはしない）。
  """
  def import_baseline(opts \\ []) do
    Bitflyer.Startup.Baseline.import(opts)
  end

  @doc """
  submission_unknown / ID 未埋込 pending の承認付き回収（Ready にはしない）。
  """
  def recover_submission(opts \\ []) do
    Bitflyer.OrderExecutor.SubmissionRecovery.recover(opts)
  end

  @doc """
  市場データキーが鮮度内か（miss / stale は false）。
  """
  def market_data_fresh?(key, max_age_ms \\ Bitflyer.MarketData.Cache.default_max_age_ms()) do
    Bitflyer.MarketData.Cache.fresh?(key, max_age_ms)
  end

  @doc """
  市場データ Feed の状態（接続・再購読回数など）。
  """
  def market_data_status(opts \\ []) do
    Bitflyer.OperationalStatus.feed_snapshot(opts)
  end

  @doc """
  発注意図の risk 認可（fail-closed）。成功時は `Risk.AuthorizedOrder`。
  """
  def authorize_order(command, opts \\ []) do
    Bitflyer.Risk.authorize(command, opts)
  end

  @doc """
  risk 認可のあと order-executor へ渡す（モード別出口・冪等）。

  raw map はここで必ず `Risk.authorize/2` を通る。Executor は `AuthorizedOrder` のみ受け付ける。
  `prep_stop` 後（InFlight closed）は認可前に `:shutting_down` を返す。
  live では認可前に未反映約定を同期する（建玉検査が遅れないようにする）。
  """
  def submit_order(command, opts \\ []) when is_map(command) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    opts = Keyword.put(opts, :trade_mode, trade_mode)

    with :ok <- reject_if_order_gate_closed(),
         :ok <- Bitflyer.OrderExecutor.sync_live_fills_before_authorize(trade_mode, opts),
         {:ok, authorized} <- Bitflyer.Risk.authorize(command, opts) do
      Bitflyer.OrderExecutor.submit(authorized, opts)
    end
  end

  defp reject_if_order_gate_closed do
    if Bitflyer.OrderExecutor.InFlight.closed?() do
      {:error, :shutting_down, %{reason: :inflight_closed}}
    else
      :ok
    end
  end
end
