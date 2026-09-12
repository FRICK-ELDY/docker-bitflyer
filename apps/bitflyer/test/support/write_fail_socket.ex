defmodule Bitflyer.TestSupport.WriteFailSocket do
  @moduledoc false

  @behaviour Bitflyer.MarketData.Socket.Client

  @impl true
  def start(opts) do
    feed = Keyword.fetch!(opts, :feed)
    {:ok, pid} = Agent.start_link(fn -> %{feed: feed} end)
    send(feed, :socket_connected)
    {:ok, pid}
  end

  @impl true
  def subscribe(_socket, _channel, _request_id), do: {:error, :closed}
end
