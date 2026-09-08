defmodule Bitflyer.MarketData.Socket.Local do
  @moduledoc false

  @behaviour Bitflyer.MarketData.Socket.Client

  use GenServer

  @impl Bitflyer.MarketData.Socket.Client
  def start(opts) do
    feed = Keyword.fetch!(opts, :feed)
    name = Keyword.get(opts, :name)
    genserver_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, %{feed: feed, subscribed: []}, genserver_opts)
  end

  @impl Bitflyer.MarketData.Socket.Client
  def subscribe(socket, channel) when is_binary(channel) do
    GenServer.call(socket, {:subscribe, channel})
  end

  @doc """
  テスト用: 接続完了を Feed に通知する。
  """
  def notify_connected(socket) do
    GenServer.cast(socket, :notify_connected)
  end

  @doc """
  テスト用: 切断を Feed に通知する。
  """
  def notify_disconnected(socket, reason \\ :closed) do
    GenServer.cast(socket, {:notify_disconnected, reason})
  end

  @doc """
  テスト用: JSON フレームを Feed に渡す。
  """
  def push_frame(socket, frame) when is_binary(frame) do
    GenServer.call(socket, {:push_frame, frame})
  end

  @doc """
  購読済みチャネル一覧（テスト用）。
  """
  def subscribed(socket) do
    GenServer.call(socket, :subscribed)
  end

  @impl GenServer
  def init(state) do
    # 実 WS と同様、起動直後に connected を送る
    send(self(), :auto_connect)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:auto_connect, state) do
    send(state.feed, :socket_connected)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:subscribe, channel}, _from, state) do
    {:reply, :ok, %{state | subscribed: state.subscribed ++ [channel]}}
  end

  def handle_call(:subscribed, _from, state) do
    {:reply, state.subscribed, state}
  end

  def handle_call({:push_frame, frame}, _from, state) do
    send(state.feed, {:socket_frame, frame})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:notify_connected, state) do
    send(state.feed, :socket_connected)
    {:noreply, state}
  end

  def handle_cast({:notify_disconnected, reason}, state) do
    send(state.feed, {:socket_disconnected, reason})
    {:noreply, %{state | subscribed: []}}
  end
end
