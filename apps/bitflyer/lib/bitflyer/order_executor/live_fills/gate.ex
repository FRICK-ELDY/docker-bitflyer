defmodule Bitflyer.OrderExecutor.LiveFills.Gate do
  @moduledoc """
  live open-order sync の最小間隔時計と単一ノード直列化。

  `:persistent_term` の頻繁な書き換えや分散向け `:global` ロックは使わない。
  時計は GenServer state。実際の REST sync は呼び出し元プロセスで行い、
  ここは begin/release の短時間 call のみ（Process dict / 呼び出し元文脈を壊さない）。

  スロット保持中・force 待機中のプロセスは `Process.monitor/1` し、異常終了時は
  自動解放する（`release` 漏れによる永久 busy を防ぐ）。
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
  `begin/2` で得たスロットを解放する。保持者以外の呼び出しは no-op。
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
    {:ok, %{last_ms: nil, busy_ref: nil, busy_pid: nil, waiters: :queue.new()}}
  end

  @impl true
  def handle_call({:begin, force?, now}, from, state) do
    busy? = is_reference(state.busy_ref)

    cond do
      busy? and not force? ->
        {:reply, :skip, state}

      busy? and force? ->
        {pid, _} = from
        mon = Process.monitor(pid)
        waiter = {from, now, mon}
        {:noreply, %{state | waiters: :queue.in(waiter, state.waiters)}}

      not force? and recently_synced?(state.last_ms, now) ->
        {:reply, :skip, state}

      true ->
        {:reply, :run, grant(from, now, state)}
    end
  end

  def handle_call(:release, {pid, _}, state) do
    if state.busy_pid == pid do
      _ = demonitor_flush(state.busy_ref)
      {:reply, :ok, promote_or_idle(%{state | busy_ref: nil, busy_pid: nil})}
    else
      # DOWN 後の stale release、または非保持者 → 無視
      {:reply, :ok, state}
    end
  end

  def handle_call(:clear_clock, _from, state) do
    {:reply, :ok, %{state | last_ms: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      state.busy_ref == ref ->
        {:noreply, promote_or_idle(%{state | busy_ref: nil, busy_pid: nil})}

      true ->
        {:noreply, %{state | waiters: drop_waiter(state.waiters, ref)}}
    end
  end

  defp grant(from, now, state) do
    {pid, _} = from
    mon = Process.monitor(pid)
    %{state | busy_ref: mon, busy_pid: pid, last_ms: now}
  end

  defp promote_or_idle(state) do
    case :queue.out(state.waiters) do
      {{:value, {from, now, mon}}, waiters} ->
        {pid, _} = from
        GenServer.reply(from, :run)
        # 待機中から付けた monitor を busy 監視に流用
        %{state | busy_ref: mon, busy_pid: pid, last_ms: now, waiters: waiters}

      {:empty, waiters} ->
        %{state | busy_ref: nil, busy_pid: nil, waiters: waiters}
    end
  end

  defp drop_waiter(waiters, ref) do
    waiters
    |> :queue.to_list()
    |> Enum.reject(fn {_from, _now, mon} -> mon == ref end)
    |> :queue.from_list()
  end

  defp demonitor_flush(nil), do: false

  defp demonitor_flush(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
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
