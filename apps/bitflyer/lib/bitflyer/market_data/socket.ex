defmodule Bitflyer.MarketData.Socket do
  @moduledoc """
  Lightstream JSON-RPC WebSocket（WebSockex）。
  """

  use WebSockex

  @behaviour Bitflyer.MarketData.Socket.Client

  @impl Bitflyer.MarketData.Socket.Client
  def start(opts) do
    url = Keyword.fetch!(opts, :url)
    feed = Keyword.fetch!(opts, :feed)
    name = Keyword.get(opts, :name)

    start_opts = if name, do: [name: name], else: []
    WebSockex.start(url, __MODULE__, %{feed: feed}, start_opts)
  end

  @impl Bitflyer.MarketData.Socket.Client
  def subscribe(socket, channel) when is_binary(channel) do
    payload =
      Jason.encode!(%{
        "method" => "subscribe",
        "params" => %{"channel" => channel}
      })

    WebSockex.send_frame(socket, {:text, payload})
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    send(state.feed, :socket_connected)
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    send(state.feed, {:socket_frame, msg})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(connection_status, state) do
    reason =
      case connection_status do
        %{reason: reason} -> reason
        other -> other
      end

    send(state.feed, {:socket_disconnected, reason})
    # Feed 側で backoff 再接続する（ここで自動 reconnect しない）
    {:ok, state}
  end
end
