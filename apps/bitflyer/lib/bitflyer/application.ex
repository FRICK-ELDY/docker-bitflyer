defmodule Bitflyer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Supervisor は子を直列停止する。1 子あたりの上限を短くし、
  # Compose stop_grace_period（45s）内に Repo 等の後続クリーンアップ余地を残す。
  # 発注停止自体は prep_stop で即時に行う。
  @child_shutdown_ms 5_000

  @impl true
  def start(_type, _args) do
    children =
      [
        Bitflyer.Repo,
        Bitflyer.Readiness,
        Bitflyer.MarketData.Cache,
        Bitflyer.Risk.OrderRate,
        Bitflyer.Risk.DailyLoss,
        Supervisor.child_spec(
          {Task.Supervisor, name: Bitflyer.MarketData.TaskSupervisor},
          shutdown: @child_shutdown_ms
        ),
        Supervisor.child_spec(Bitflyer.Startup.Reconciler, shutdown: @child_shutdown_ms),
        # 発注経路の兄弟。通知失敗・クラッシュで取引木を巻き込まない。
        Supervisor.child_spec(Bitflyer.Observe.Discord, shutdown: @child_shutdown_ms)
      ] ++ market_data_feed()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitflyer.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # GenServer 再起動のたびに attach/detach しない（静的 ID で一度だけ）。
        :ok = Bitflyer.Observe.Discord.install_telemetry()
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  アプリケーション停止前に発注ゲートを閉じる（SIGTERM / `Application.stop`）。

  OTP コールバックは `prep_stop/1`。`Readiness.mark_not_ready_safe/0` により以降の
  `Risk.authorize` が新規 submit を拒否する。halted 中は halted を維持する。
  """
  @impl true
  def prep_stop(state) do
    _ = Bitflyer.Observe.Discord.uninstall_telemetry()

    previous =
      try do
        Bitflyer.Readiness.get()
      catch
        :exit, _ -> :not_ready
      end

    Bitflyer.Telemetry.log(:info, "prep_stop: closing order gate", %{
      readiness: Bitflyer.Readiness.format(previous),
      reason: :application_stop
    })

    _ = Bitflyer.Readiness.mark_not_ready_safe()
    state
  end

  defp market_data_feed do
    if Bitflyer.MarketData.enabled?() do
      [
        Supervisor.child_spec({Bitflyer.MarketData.Feed, []}, shutdown: @child_shutdown_ms)
      ] ++ strategy_runner()
    else
      []
    end
  end

  defp strategy_runner do
    if Bitflyer.Strategy.enabled?() do
      [
        Supervisor.child_spec({Bitflyer.Strategy.Runner, []}, shutdown: @child_shutdown_ms)
      ]
    else
      []
    end
  end
end
