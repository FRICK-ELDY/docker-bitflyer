defmodule Bitflyer.OrderExecutor.LiveFills.Gate do
  @moduledoc """
  live open-order sync の最小間隔時計と単一ノード直列化。

  `:persistent_term` の頻繁な書き換えや分散向け `:global` ロックは使わない。
  時計は GenServer state。実際の REST sync は呼び出し元プロセスで行い、
  ここは begin/release の短時間 call のみ（Process dict / 呼び出し元文脈を壊さない）。
  """

  use GenServer

  @name __MODULE__
  @default_min_sync_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  sync スロットを取得する。`:run` なら呼び出し側で sync し、必ず `release/1` する。

  - 非 force かつ間隔内 / 他が走行中 → `:skip`
  - force かつ他が走行中 → 完了まで待ち `:run`
  - 時計は `:run` 付与時に進める（失敗時の REST 連打抑制）
  """
  @spec begin(boolean(), integer(), keyword()) :: :run | :skip
  def begin(force?, now, opts \\ []) when is_boolean(force?) and is_integer(now) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:begin, force?, now}, :infinity)
  end

  @doc """
  `begin/2` で得たスロットを解放する。
  """
  @spec release(keyword()) :: :ok
  def release(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :release)
  end

  @doc false
  @spec clear_clock(keyword()) :: :ok
  def clear_clock(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :clear_clock)
  end

  @impl true
  def init(_opts) do
    {:ok, %{last_ms: nil, busy: false, waiters: :queue.new()}}
  end

  @impl true
  def handle_call({:begin, force?, now}, from, state) do
    cond do
      state.busy and not force? ->
        {:reply, :skip, state}

      state.busy and force? ->
        {:noreply, %{state | waiters: :queue.in({from, now}, state.waiters)}}

      not force? and recently_synced?(state.last_ms, now) ->
        {:reply, :skip, state}

      true ->
        {:reply, :run, %{state | busy: true, last_ms: now}}
    end
  end

  def handle_call(:release, _from, state) do
    case :queue.out(state.waiters) do
      {{:value, {from, now}}, waiters} ->
        GenServer.reply(from, :run)
        {:reply, :ok, %{state | busy: true, last_ms: now, waiters: waiters}}

      {:empty, waiters} ->
        {:reply, :ok, %{state | busy: false, waiters: waiters}}
    end
  end

  def handle_call(:clear_clock, _from, state) do
    {:reply, :ok, %{state | last_ms: nil}}
  end

  defp recently_synced?(nil, _now), do: false

  defp recently_synced?(last, now) when is_integer(last) and is_integer(now) do
    now - last < min_sync_interval_ms()
  end

  defp min_sync_interval_ms do
    Application.get_env(:bitflyer, Bitflyer.OrderExecutor.LiveFills, [])
    |> Keyword.get(:min_sync_interval_ms, @default_min_sync_interval_ms)
  end
end
