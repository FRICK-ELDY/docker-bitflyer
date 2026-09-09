defmodule Bitflyer.Risk.OrderRate do
  @moduledoc """
  直近の発注件数を ETS で数える（発注ホットパスから DB を叩かない）。

  - `record/2` — pending 作成成功時に呼ぶ
  - `count/2` — 直近 `window_ms`（既定 60_000）の件数
  """

  use GenServer

  @name __MODULE__
  @default_window_ms 60_000

  @type trade_mode :: Bitflyer.TradeMode.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  発注 1 件を記録する。
  """
  @spec record(trade_mode(), keyword()) :: :ok
  def record(trade_mode, opts \\ []) when trade_mode in [:dry_run, :paper, :live] do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:record, trade_mode, opts})
  end

  @doc """
  直近窓の発注件数。テーブル消失時は 0。
  """
  @spec count(trade_mode(), keyword()) :: non_neg_integer()
  def count(trade_mode, opts \\ []) when trade_mode in [:dry_run, :paper, :live] do
    server = Keyword.get(opts, :server, @name)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)

    if is_atom(server) do
      ets_count(server, trade_mode, now, window_ms)
    else
      GenServer.call(server, {:count, trade_mode, now, window_ms})
    end
  end

  @doc """
  全消し（テスト用）。
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :clear)
  end

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)
    {:ok, table}
  end

  @impl true
  def handle_call({:record, trade_mode, opts}, _from, table) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    true = :ets.insert(table, {trade_mode, now})
    _ = prune(table, trade_mode, now, window_ms)
    {:reply, :ok, table}
  end

  def handle_call({:count, trade_mode, now, window_ms}, _from, table) do
    {:reply, ets_count(table, trade_mode, now, window_ms), table}
  end

  def handle_call(:clear, _from, table) do
    true = :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  defp ensure_table(table) when is_atom(table) do
    :ets.new(table, [:named_table, :protected, :bag, read_concurrency: true])
  end

  defp ets_count(table, trade_mode, now, window_ms)
       when is_atom(table) or is_reference(table) do
    since = now - window_ms

    try do
      :ets.select_count(table, [{{trade_mode, :"$1"}, [{:>=, :"$1", since}], [true]}])
    rescue
      ArgumentError -> 0
    end
  end

  defp prune(table, trade_mode, now, window_ms) do
    since = now - window_ms
    _ = :ets.select_delete(table, [{{trade_mode, :"$1"}, [{:<, :"$1", since}], [true]}])
    :ok
  end
end
