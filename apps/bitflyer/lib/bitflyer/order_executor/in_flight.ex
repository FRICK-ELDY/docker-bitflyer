defmodule Bitflyer.OrderExecutor.InFlight do
  @moduledoc """
  進行中の `OrderExecutor.submit` / `cancel` を数える（停止時 drain 用）。

  - `track/1` → 処理本体 → `untrack/1`（`try/after`）
  - `prep_stop` はゲート閉鎖後に `drain/1` し、件数ゼロまたは timeout まで待つ
  - timeout 時は呼び出し側が leftovers を `submission_unknown` 化する
  - 追跡プロセスが落ちた場合は `DOWN` で自動除去（リーク防止）
  """

  use GenServer

  @name __MODULE__
  @default_drain_timeout_ms 10_000

  @type kind :: :submit | :cancel
  @type entry :: %{
          ref: reference(),
          kind: kind(),
          internal_order_id: String.t() | nil,
          pid: pid()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  進行中処理を登録する。`drain` 開始後（closed）は `{:error, :closed}`。
  """
  @spec track(map(), keyword()) :: {:ok, reference()} | {:error, :closed}
  def track(meta \\ %{}, opts \\ []) when is_map(meta) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:track, meta, self()})
  end

  @doc """
  登録を外す。未知 ref は no-op。
  """
  @spec untrack(reference(), keyword()) :: :ok
  def untrack(ref, opts \\ []) when is_reference(ref) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:untrack, ref})
  end

  @doc """
  現在の in-flight 件数。
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :count)
  end

  @doc """
  `drain/1` 後など、新規 track を拒否しているか。
  """
  @spec closed?(keyword()) :: boolean()
  def closed?(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :closed?)
  end

  @doc """
  受付を閉じ、進行中が空になるまで待つ。

  既に空なら即 `:ok`。timeout 時は `{:error, :timeout, leftovers}`。
  """
  @spec drain(keyword()) :: :ok | {:error, :timeout, [entry()]}
  def drain(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    timeout_ms = Keyword.get(opts, :timeout_ms, drain_timeout_ms())
    # call 自体の timeout に余裕を持たせる
    GenServer.call(server, {:drain, timeout_ms}, timeout_ms + 5_000)
  end

  @doc """
  全消し＋受付再開（テスト用）。
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :clear)
  end

  @spec drain_timeout_ms() :: pos_integer()
  def drain_timeout_ms do
    Application.get_env(:bitflyer, Bitflyer.OrderExecutor, [])
    |> Keyword.get(:drain_timeout_ms, @default_drain_timeout_ms)
  end

  @impl true
  def init(_) do
    {:ok,
     %{
       closed?: false,
       inflight: %{},
       monitors: %{},
       waiters: [],
       drain_timer: nil
     }}
  end

  @impl true
  def handle_call({:track, meta, pid}, _from, %{closed?: true} = state) do
    _ = meta
    _ = pid
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:track, meta, pid}, _from, state) do
    ref = make_ref()
    mon = Process.monitor(pid)

    entry = %{
      ref: ref,
      kind: Map.get(meta, :kind, :submit),
      internal_order_id: Map.get(meta, :internal_order_id),
      pid: pid,
      mon: mon
    }

    state = %{
      state
      | inflight: Map.put(state.inflight, ref, entry),
        monitors: Map.put(state.monitors, mon, ref)
    }

    {:reply, {:ok, ref}, state}
  end

  def handle_call({:untrack, ref}, _from, state) do
    {:reply, :ok, remove_ref(state, ref)}
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.inflight), state}
  end

  def handle_call(:closed?, _from, state) do
    {:reply, state.closed?, state}
  end

  def handle_call({:drain, timeout_ms}, from, state) do
    state = %{state | closed?: true}

    if map_size(state.inflight) == 0 do
      state = cancel_drain_timer(state)
      {:reply, :ok, state}
    else
      state = cancel_drain_timer(state)
      timer = Process.send_after(self(), {:drain_timeout, from}, timeout_ms)
      state = %{state | waiters: [from | state.waiters], drain_timer: timer}
      {:noreply, state}
    end
  end

  def handle_call(:clear, _from, state) do
    state =
      state
      |> demonitor_all()
      |> cancel_drain_timer()

    Enum.each(state.waiters, fn waiter ->
      GenServer.reply(waiter, :ok)
    end)

    {:reply, :ok,
     %{
       closed?: false,
       inflight: %{},
       monitors: %{},
       waiters: [],
       drain_timer: nil
     }}
  end

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mon) do
      {nil, _} ->
        {:noreply, state}

      {ref, monitors} ->
        state = %{state | monitors: monitors, inflight: Map.delete(state.inflight, ref)}
        {:noreply, maybe_complete_drain(state)}
    end
  end

  def handle_info({:drain_timeout, from}, state) do
    if from in state.waiters do
      leftovers =
        state.inflight
        |> Map.values()
        |> Enum.map(&Map.take(&1, [:ref, :kind, :internal_order_id, :pid]))

      Enum.each(state.waiters, fn waiter ->
        GenServer.reply(waiter, {:error, :timeout, leftovers})
      end)

      {:noreply, %{state | waiters: [], drain_timer: nil}}
    else
      {:noreply, %{state | drain_timer: nil}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp remove_ref(state, ref) do
    case Map.pop(state.inflight, ref) do
      {nil, _} ->
        state

      {%{mon: mon}, inflight} ->
        true = Process.demonitor(mon, [:flush])

        state = %{
          state
          | inflight: inflight,
            monitors: Map.delete(state.monitors, mon)
        }

        maybe_complete_drain(state)
    end
  end

  defp maybe_complete_drain(%{waiters: []} = state), do: state

  defp maybe_complete_drain(%{inflight: inflight} = state) when map_size(inflight) > 0, do: state

  defp maybe_complete_drain(state) do
    state = cancel_drain_timer(state)

    Enum.each(state.waiters, fn waiter ->
      GenServer.reply(waiter, :ok)
    end)

    %{state | waiters: []}
  end

  defp cancel_drain_timer(%{drain_timer: nil} = state), do: state

  defp cancel_drain_timer(%{drain_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | drain_timer: nil}
  end

  defp demonitor_all(state) do
    Enum.each(state.monitors, fn {mon, _} ->
      Process.demonitor(mon, [:flush])
    end)

    state
  end
end
