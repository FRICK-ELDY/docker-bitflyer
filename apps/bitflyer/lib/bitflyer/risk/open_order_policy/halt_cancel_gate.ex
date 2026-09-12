defmodule Bitflyer.Risk.OpenOrderPolicy.HaltCancelGate do
  @moduledoc """
  halt cancel-all の in-flight / backoff 状態を持つ ETS のオーナー。

  `OpenOrderPolicy.ensure_halt_cancels/2` の背圧用。テーブルは本 GenServer が
  `:protected` で作成し、StatusLive 等の短命プロセスが最初に触っても
  所有者にならない（OrderRate / AuthorizedOrder と同じ慣例）。
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
  cancel 完了を記録する（in-flight 解除、必要なら backoff）。
  """
  @spec finish(finish_outcome(), keyword()) :: :ok
  def finish(outcome, opts \\ []) when outcome in [:cleared, :retry] do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:finish, outcome, opts})
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

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:try_begin, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)
    stale_ms = Keyword.get(opts, :stale_ms, @default_in_flight_stale_ms)
    now = System.monotonic_time(:millisecond)
    table = state.table

    if force? do
      :ets.delete(table, :next_allowed_ms)
    end

    result =
      cond do
        not force? and backed_off?(table, now) ->
          :backoff

        true ->
          acquire_in_flight(table, now, stale_ms)
      end

    {:reply, result, state}
  end

  def handle_call({:finish, outcome, opts}, _from, state) do
    table = state.table
    now = System.monotonic_time(:millisecond)
    backoff_ms = Keyword.get(opts, :backoff_ms, @default_retry_backoff_ms)

    case outcome do
      :cleared ->
        :ets.delete(table, :next_allowed_ms)

      :retry ->
        :ets.insert(table, {:next_allowed_ms, now + backoff_ms})
    end

    :ets.delete(table, :in_flight)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  defp backed_off?(table, now) do
    case :ets.lookup(table, :next_allowed_ms) do
      [{:next_allowed_ms, next}] when is_integer(next) and now < next -> true
      _ -> false
    end
  end

  defp acquire_in_flight(table, now, stale_ms) do
    case :ets.lookup(table, :in_flight) do
      [{:in_flight, started}] when is_integer(started) ->
        if now - started >= stale_ms do
          :ets.delete(table, :in_flight)

          if :ets.insert_new(table, {:in_flight, now}) do
            :go
          else
            :busy
          end
        else
          :busy
        end

      [] ->
        if :ets.insert_new(table, {:in_flight, now}) do
          :go
        else
          :busy
        end
    end
  end
end
