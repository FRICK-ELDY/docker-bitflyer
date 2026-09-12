defmodule Bitflyer.Risk.OpenOrderPolicy.HaltCancelGate do
  @moduledoc """
  halt cancel-all の in-flight / backoff / cleared 状態を持つ ETS のオーナー。

  `OpenOrderPolicy.ensure_halt_cancels/2` の背圧用。テーブルは本 GenServer が
  `:protected` で作成し、StatusLive 等の短命プロセスが最初に触っても
  所有者にならない（OrderRate / AuthorizedOrder と同じ慣例）。

  非同期 cancel Task は `watch/2` で監視し、`finish/2` 前に死んだら
  in-flight を解除して backoff する（stale 待ちにしない）。
  """

  use GenServer

  @name __MODULE__
  @default_retry_backoff_ms 30_000
  @default_in_flight_stale_ms 600_000

  @type begin_result :: :go | :busy | :backoff
  @type finish_outcome :: :cleared | :retry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  cancel 起動を試みる。`:go` のとき呼び出し側が cancel を走らせ、完了後に `finish/2` する。
  """
  @spec try_begin(keyword()) :: begin_result()
  def try_begin(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:try_begin, opts})
  end

  @doc """
  非同期 cancel の PID を監視する。`finish/2` 前に死んだら `:retry` 相当でロック解除。
  """
  @spec watch(pid(), keyword()) :: :ok
  def watch(pid, opts \\ []) when is_pid(pid) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:watch, pid})
  end

  @doc """
  cancel 完了を記録する（in-flight 解除、必要なら backoff / cleared）。
  """
  @spec finish(finish_outcome(), keyword()) :: :ok
  def finish(outcome, opts \\ []) when outcome in [:cleared, :retry] do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:finish, outcome, opts})
  end

  @doc """
  直近の cancel-all が空になったあと、resume / `:force` まで list を省略してよいか。
  """
  @spec cleared?(keyword()) :: boolean()
  def cleared?(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :cleared?)
  end

  @doc """
  open が既に無いことを記録する（list が空のときの CircuitSync 省略用）。
  """
  @spec mark_cleared(keyword()) :: :ok
  def mark_cleared(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :mark_cleared)
  end

  @doc false
  @spec reset!(keyword()) :: :ok
  def reset!(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :reset)
  end

  @doc false
  @spec owner(keyword()) :: pid() | :undefined
  def owner(opts \\ []) do
    server = Keyword.get(opts, :server, @name)

    case Process.whereis(server) do
      pid when is_pid(pid) -> pid
      _ -> :undefined
    end
  end

  @doc false
  @spec table_name(keyword()) :: atom()
  def table_name(opts \\ []) do
    Keyword.get(opts, :server, @name)
  end

  @impl true
  def init(%{table: table_name}) do
    table =
      :ets.new(table_name, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    {:ok, %{table: table, worker: nil}}
  end

  @impl true
  def handle_call({:try_begin, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)
    stale_ms = Keyword.get(opts, :stale_ms, @default_in_flight_stale_ms)
    now = System.monotonic_time(:millisecond)
    table = state.table

    if force? do
      :ets.delete(table, :next_allowed_ms)
      :ets.delete(table, :cleared)
    end

    {result, state} =
      cond do
        not force? and backed_off?(table, now) ->
          {:backoff, state}

        true ->
          acquire_in_flight(state, now, stale_ms)
      end

    {:reply, result, state}
  end

  def handle_call({:watch, pid}, _from, state) do
    if in_flight?(state.table) do
      {:reply, :ok, monitor_worker(state, pid)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:finish, outcome, opts}, _from, state) do
    {:reply, :ok, apply_finish(state, outcome, opts)}
  end

  def handle_call(:cleared?, _from, state) do
    {:reply, cleared_flag?(state.table), state}
  end

  def handle_call(:mark_cleared, _from, state) do
    :ets.insert(state.table, {:cleared, true})
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    state = demonitor_worker(state)
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case state.worker do
      {^pid, ^ref} ->
        Bitflyer.Telemetry.log(
          :warning,
          "HaltCancelGate cancel worker died before finish",
          %{error: inspect(reason)}
        )

        {:noreply, apply_finish(state, :retry, [])}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_finish(state, outcome, opts) do
    table = state.table
    now = System.monotonic_time(:millisecond)
    backoff_ms = Keyword.get(opts, :backoff_ms, @default_retry_backoff_ms)

    case outcome do
      :cleared ->
        :ets.delete(table, :next_allowed_ms)
        :ets.insert(table, {:cleared, true})

      :retry ->
        :ets.delete(table, :cleared)
        :ets.insert(table, {:next_allowed_ms, now + backoff_ms})
    end

    :ets.delete(table, :in_flight)
    demonitor_worker(state)
  end

  defp backed_off?(table, now) do
    case :ets.lookup(table, :next_allowed_ms) do
      [{:next_allowed_ms, next}] when is_integer(next) and now < next -> true
      _ -> false
    end
  end

  defp cleared_flag?(table) do
    match?([{:cleared, true}], :ets.lookup(table, :cleared))
  end

  defp in_flight?(table) do
    match?([{:in_flight, _}], :ets.lookup(table, :in_flight))
  end

  defp acquire_in_flight(state, now, stale_ms) do
    table = state.table

    case :ets.lookup(table, :in_flight) do
      [{:in_flight, started}] when is_integer(started) ->
        if now - started >= stale_ms do
          state = demonitor_worker(state)
          :ets.insert(table, {:in_flight, now})
          {:go, state}
        else
          {:busy, state}
        end

      [] ->
        :ets.insert(table, {:in_flight, now})
        {:go, state}
    end
  end

  defp monitor_worker(state, pid) do
    state = demonitor_worker(state)
    ref = Process.monitor(pid)
    %{state | worker: {pid, ref}}
  end

  defp demonitor_worker(%{worker: {_, ref}} = state) do
    true = Process.demonitor(ref, [:flush])
    %{state | worker: nil}
  end

  defp demonitor_worker(state), do: %{state | worker: nil}
end
