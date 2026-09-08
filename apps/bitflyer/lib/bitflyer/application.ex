defmodule Bitflyer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Bitflyer.Repo,
      Bitflyer.Readiness,
      Bitflyer.MarketData.Cache,
      Bitflyer.Startup.Reconciler
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitflyer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
