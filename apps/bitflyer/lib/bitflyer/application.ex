defmodule Bitflyer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Compose stop_grace_period と揃える（進行中の永続・Feed 切断を待つ）
  @child_shutdown_ms 30_000

  @impl true
  def start(_type, _args) do
    children =
      [
        Bitflyer.Repo,
        Bitflyer.Readiness,
        Bitflyer.MarketData.Cache,
        Bitflyer.Risk.OrderRate,
        Supervisor.child_spec(
          {Task.Supervisor, name: Bitflyer.MarketData.TaskSupervisor},
          shutdown: @child_shutdown_ms
        ),
        Supervisor.child_spec(Bitflyer.Startup.Reconciler, shutdown: @child_shutdown_ms)
      ] ++ market_data_feed()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitflyer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  アプリケーション停止前に発注ゲートを閉じる（SIGTERM / `Application.stop`）。

  OTP コールバックは `prep_stop/1`。`Readiness.mark_not_ready/0` により以降の
  `Risk.authorize` が新規 submit を拒否する。halted 中は halted を維持する。
  """
  @impl true
  def prep_stop(state) do
    previous = Bitflyer.Readiness.get()

    Bitflyer.Telemetry.log(:info, "prep_stop: closing order gate", %{
      readiness: Bitflyer.Readiness.format(previous),
      reason: :application_stop
    })

    _ = Bitflyer.Readiness.mark_not_ready()
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
