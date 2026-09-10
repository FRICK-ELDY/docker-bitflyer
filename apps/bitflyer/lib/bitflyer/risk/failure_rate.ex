defmodule Bitflyer.Risk.FailureRate do
  @moduledoc """
  取引所エラーの連続発生を ETS で数える（発注ホットパスから DB を叩かない）。

  - `:auth_failed`（401/403）は回数不要で即サーキット候補
  - その他の確定拒否は窓内 N 回で `:consecutive_exchange_errors`
  - `:order_not_found` は取消レース等で起きうるため **連続カウント対象外**（確定拒否のまま、
    単発では halt しない）
  - timeout 等の提出不明はここでは数えない（既存の即 halt を維持）
  - カウンタはプロセス内 ETS のみ。再起動で消える（`OrderRate` 同型）。
    `:auth_failed` は都度即 halt なので鍵違いは再発で再度止まる
  """

  use GenServer

  @name __MODULE__
  @default_window_ms 60_000
  @default_max_errors 5

  @countable_reasons MapSet.new([
                       :rejected_by_exchange,
                       :insufficient_funds,
                       :invalid_order,
                       :invalid_request,
                       :rate_limited
                     ])

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type evaluate_result :: :ok | {:halt, :auth_failed | :consecutive_exchange_errors}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  取引所エラー理由を評価する。必要なら呼び出し側が `Risk.open_circuit/1` する。
  """
  @spec evaluate(term(), keyword()) :: evaluate_result()
  def evaluate(reason, opts \\ [])

  def evaluate(:auth_failed, _opts), do: {:halt, :auth_failed}

  def evaluate(reason, opts) when is_atom(reason) do
    if MapSet.member?(@countable_reasons, reason) do
      trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
      _ = record(trade_mode, opts)
      max = Keyword.get(opts, :max_errors, max_errors())
      window_ms = Keyword.get(opts, :window_ms, window_ms())

      if count(trade_mode, Keyword.merge(opts, window_ms: window_ms)) >= max do
        {:halt, :consecutive_exchange_errors}
      else
        :ok
      end
    else
      :ok
    end
  end

  def evaluate(_reason, _opts), do: :ok

  @doc """
  エラー 1 件を記録する。
  """
  @spec record(trade_mode(), keyword()) :: :ok
  def record(trade_mode, opts \\ []) when trade_mode in [:dry_run, :paper, :live] do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:record, trade_mode, opts})
  end

  @doc """
  直近窓のエラー件数。
  """
  @spec count(trade_mode(), keyword()) :: non_neg_integer()
  def count(trade_mode, opts \\ []) when trade_mode in [:dry_run, :paper, :live] do
    server = Keyword.get(opts, :server, @name)
    window_ms = Keyword.get(opts, :window_ms, window_ms())
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

  @spec window_ms() :: pos_integer()
  def window_ms do
    Application.get_env(:bitflyer, Bitflyer.Risk, [])
    |> Keyword.get(:exchange_error_window_ms, @default_window_ms)
  end

  @spec max_errors() :: pos_integer()
  def max_errors do
    Application.get_env(:bitflyer, Bitflyer.Risk, [])
    |> Keyword.get(:max_exchange_errors_per_window, @default_max_errors)
  end

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)
    {:ok, table}
  end

  @impl true
  def handle_call({:record, trade_mode, opts}, _from, table) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, window_ms())
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
    # 同一 ms の連続エラーを別件として数える（:bag だと同一タプルは1件に潰れる）
    :ets.new(table, [:named_table, :protected, :duplicate_bag, read_concurrency: true])
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
