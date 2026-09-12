defmodule Bitflyer.MarketData.Socket.Local do
  @moduledoc false

  @behaviour Bitflyer.MarketData.Socket.Client

  use GenServer

  @impl Bitflyer.MarketData.Socket.Client
  def start(opts) do
    feed = Keyword.fetch!(opts, :feed)
    name = Keyword.get(opts, :name)
    genserver_opts = if name, do: [name: name], else: []

    GenServer.start_link(
      __MODULE__,
      %{
        feed: feed,
        subscribed: [],
        subscribe_ack: Keyword.get(opts, :subscribe_ack, :immediate)
      },
      genserver_opts
    )
  end

  @impl Bitflyer.MarketData.Socket.Client
  def subscribe(socket, channel, request_id)
      when is_binary(channel) and is_integer(request_id) and request_id > 0 do
    GenServer.call(socket, {:subscribe, channel, request_id})
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
  テスト用: 未送信の購読 ACK を後から送る。
  """
  def ack(socket, request_id) when is_integer(request_id) do
    GenServer.call(socket, {:ack, request_id})
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
  def handle_call({:subscribe, channel, request_id}, _from, state) do
    state = %{state | subscribed: state.subscribed ++ [channel]}

    case state.subscribe_ack do
      :immediate ->
        send_rpc(state.feed, %{"id" => request_id, "result" => true})
        {:reply, :ok, state}

      :error ->
        send_rpc(state.feed, %{"id" => request_id, "error" => %{"message" => "denied"}})
        {:reply, :ok, state}

      :never ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:subscribed, _from, state) do
    {:reply, state.subscribed, state}
  end

  def handle_call({:push_frame, frame}, _from, state) do
    send(state.feed, {:socket_frame, frame})
    {:reply, :ok, state}
  end

  def handle_call({:ack, request_id}, _from, state) do
    send_rpc(state.feed, %{"id" => request_id, "result" => true})
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

  defp send_rpc(feed, map) do
    send(feed, {:socket_frame, Jason.encode!(map)})
  end
end
