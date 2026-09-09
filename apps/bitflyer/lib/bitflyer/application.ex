defmodule Bitflyer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Bitflyer.Repo,
        Bitflyer.Readiness,
        Bitflyer.MarketData.Cache,
        Bitflyer.Risk.OrderRate,
        {Task.Supervisor, name: Bitflyer.MarketData.TaskSupervisor},
        Bitflyer.Startup.Reconciler
      ] ++ market_data_feed()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitflyer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp market_data_feed do
    if Bitflyer.MarketData.enabled?() do
      [{Bitflyer.MarketData.Feed, []}] ++ strategy_runner()
    else
      []
    end
  end

  defp strategy_runner do
    if Bitflyer.Strategy.enabled?() do
      [{Bitflyer.Strategy.Runner, []}]
    else
      []
    end
  end
end
