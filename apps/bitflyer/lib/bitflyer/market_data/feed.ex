defmodule Bitflyer.MarketData.Feed do
  @moduledoc """
  市場データ購読のオーケストレータ。

  - 接続時: チャネル再購読 + REST 穴埋め
  - 切断時: telemetry → backoff 再接続（古い Cache のままなので risk は stale 拒否）
  - フレーム: 正規化 → Cache.put → tick telemetry
  - socket は link + trap_exit（Feed 終了時のリーク防止、切断は EXIT で検知）
  """

  use GenServer

  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.{Cache, Normalize}

  @name __MODULE__

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  REST で全銘柄を穴埋めする（手動・テスト用）。
  """
  @spec gap_fill(GenServer.server()) :: :ok
  def gap_fill(server \\ @name) do
    GenServer.call(server, :gap_fill)
  end

  @doc """
  現在の接続状態（運用画面・テスト用）。
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ @name) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cfg = MarketData.config()

    state = %{
      product_codes: Keyword.get(opts, :product_codes, MarketData.product_codes()),
      rest_client:
        Keyword.get(opts, :rest_client, Keyword.get(cfg, :rest_client, Bitflyer.MarketData.Rest)),
      socket_client:
        Keyword.get(
          opts,
          :socket_client,
          Keyword.get(cfg, :socket_client, Bitflyer.MarketData.Socket)
        ),
      ws_url:
        Keyword.get(
          opts,
          :ws_url,
          Keyword.get(cfg, :ws_url, "wss://ws.lightstream.bitflyer.com/json-rpc")
        ),
      gap_fill_on_connect?:
        Keyword.get(opts, :gap_fill_on_connect?, Keyword.get(cfg, :gap_fill_on_connect?, true)),
      reconnect_base_ms:
        Keyword.get(opts, :reconnect_base_ms, Keyword.get(cfg, :reconnect_base_ms, 500)),
      reconnect_max_ms:
        Keyword.get(opts, :reconnect_max_ms, Keyword.get(cfg, :reconnect_max_ms, 30_000)),
      socket: nil,
      connected?: false,
      reconnect_attempt: 0,
      reconnect_timer: nil,
      subscribe_count: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect_socket(state)}
  end

  @impl true
  def handle_call(:gap_fill, _from, state) do
    {:reply, :ok, do_gap_fill(state)}
  end

  def handle_call(:status, _from, state) do
    status = %{
      connected?: state.connected?,
      product_codes: state.product_codes,
      subscribe_count: state.subscribe_count,
      reconnect_attempt: state.reconnect_attempt,
      socket: state.socket
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:socket_connected, state) do
    state =
      state
      |> cancel_reconnect_timer()
      |> Map.put(:connected?, true)
      |> Map.put(:reconnect_attempt, 0)
      |> subscribe_all()

    state =
      if state.gap_fill_on_connect? do
        do_gap_fill(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:socket_frame, frame}, state) do
    _ = ingest_frame(frame)
    {:noreply, state}
  end

  def handle_info({:socket_disconnected, reason}, state) do
    {:noreply, handle_disconnect(state, reason)}
  end

  def handle_info({:EXIT, pid, reason}, %{socket: pid} = state) do
    {:noreply, handle_disconnect(state, reason)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    # mailbox に残った :reconnect が、確立済み接続を落とさないようにする
    if state.connected? or not is_nil(state.socket) do
      {:noreply, state}
    else
      {:noreply, connect_socket(state)}
    end
  end

  def handle_info({:gap_fill_tick, key, value, product_code, gap_fill_started_at}, state) do
    _ = maybe_apply_gap_fill(key, value, product_code, gap_fill_started_at)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_disconnect(%{connected?: false, socket: nil} = state, _reason), do: state

  defp handle_disconnect(state, reason) do
    emit_disconnected(reason)

    state
    |> stop_socket()
    |> Map.put(:connected?, false)
    |> schedule_reconnect()
  end

  defp connect_socket(state) do
    state =
      state
      |> cancel_reconnect_timer()
      |> stop_socket()

    case state.socket_client.start(url: state.ws_url, feed: self()) do
      {:ok, pid} ->
        %{state | socket: pid}

      {:error, {:already_started, pid}} ->
        # 既存 socket は別 Feed PID 向けのままなので捨てて張り直す
        if is_pid(pid), do: Process.exit(pid, :shutdown)
        emit_disconnected({:already_started, pid})
        schedule_reconnect(%{state | connected?: false, socket: nil})

      {:error, reason} ->
        emit_disconnected(reason)
        schedule_reconnect(%{state | connected?: false, socket: nil})
    end
  end

  defp stop_socket(%{socket: nil} = state), do: state

  defp stop_socket(%{socket: pid} = state) do
    if is_pid(pid), do: Process.exit(pid, :shutdown)
    %{state | socket: nil}
  end

  defp subscribe_all(%{socket: nil} = state), do: state

  defp subscribe_all(state) do
    Enum.reduce(state.product_codes, state, fn product_code, acc ->
      channel = MarketData.ticker_channel(product_code)

      case state.socket_client.subscribe(acc.socket, channel) do
        :ok ->
          %{acc | subscribe_count: acc.subscribe_count + 1}

        {:error, reason} ->
          Bitflyer.Telemetry.log(
            :warning,
            "market_data subscribe failed: #{inspect(reason)}",
            %{product_code: product_code, reason: reason, status: :subscribe_failed}
          )

          acc
      end
    end)
  end

  defp do_gap_fill(state) do
    rest_client = state.rest_client
    product_codes = state.product_codes
    gap_fill_started_at = Cache.monotonic_ms()
    parent = self()

    # REST は Feed をブロックしない。結果は Feed 経由で適用し、
    # 開始後に届いた WS より古い穴埋めで上書きしない。
    _ =
      Task.Supervisor.start_child(MarketData.task_supervisor(), fn ->
        gap_fill_products(rest_client, product_codes, gap_fill_started_at, parent)
      end)

    state
  end

  defp gap_fill_products(rest_client, product_codes, gap_fill_started_at, parent) do
    Enum.each(product_codes, fn product_code ->
      case rest_client.fetch_ticker(product_code) do
        {:ok, body} ->
          case Normalize.from_ticker(body) do
            {:ok, key, value} ->
              send(parent, {:gap_fill_tick, key, value, product_code, gap_fill_started_at})

            :error ->
              Bitflyer.Telemetry.log(
                :warning,
                "market_data gap fill normalization failed",
                %{
                  product_code: product_code,
                  reason: :normalization_failed,
                  status: :gap_fill_failed
                }
              )
          end

        {:error, reason} ->
          Bitflyer.Telemetry.log(
            :warning,
            "market_data gap fill failed: #{inspect(reason)}",
            %{product_code: product_code, reason: reason, status: :gap_fill_failed}
          )
      end
    end)
  end

  defp maybe_apply_gap_fill(key, value, product_code, gap_fill_started_at) do
    case Cache.get(key) do
      {:ok, _current, received_at} when received_at >= gap_fill_started_at ->
        :ok

      _ ->
        put_tick(key, value, product_code, received_at: gap_fill_started_at)
    end
  end

  defp ingest_frame(frame) do
    case Normalize.from_ws_frame(frame) do
      {:ok, key, value} ->
        put_tick(key, value, elem(key, 1))

      :ignore ->
        :ok

      :error ->
        # フレーム全文はログに載せない（肥大・ノイズ回避）
        Bitflyer.Telemetry.log(
          :warning,
          "market_data ws frame normalization failed",
          %{reason: :normalization_failed, status: :ws_frame_failed}
        )
    end
  end

  defp put_tick(key, value, product_code, opts \\ []) do
    _ = Cache.put(key, value, opts)

    Bitflyer.Telemetry.execute(
      :market_data_tick,
      %{count: 1},
      %{product_code: product_code, status: :ok}
    )

    _ = Bitflyer.Strategy.Runner.notify_tick(key, value)

    :ok
  end

  defp emit_disconnected(reason) do
    Bitflyer.Telemetry.execute(
      :market_data_disconnected,
      %{count: 1},
      %{reason: reason, status: :disconnected}
    )
  end

  defp schedule_reconnect(state) do
    state = cancel_reconnect_timer(state)
    attempt = state.reconnect_attempt
    delay = reconnect_delay(attempt, state.reconnect_base_ms, state.reconnect_max_ms)
    timer = Process.send_after(self(), :reconnect, delay)

    %{state | reconnect_attempt: attempt + 1, reconnect_timer: timer}
  end

  defp reconnect_delay(attempt, base, max) when attempt >= 0 do
    factor = trunc(:math.pow(2, min(attempt, 10)))
    min(base * factor, max)
  end

  defp cancel_reconnect_timer(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end
end
