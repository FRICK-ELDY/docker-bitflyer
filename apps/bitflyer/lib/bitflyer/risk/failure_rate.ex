defmodule Bitflyer.Risk.FailureRate do
  @moduledoc """
  取引所エラーの連続発生を ETS で数える（発注ホットパスから DB を叩かない）。

  - `:auth_failed`（401/403）は回数不要で即サーキット候補
  - その他の確定拒否は窓内 N 回で `:consecutive_exchange_errors`
  - `:order_not_found` は取消レース等で起きうるため **連続カウント対象外**（確定拒否のまま、
    単発では halt しない）
  - timeout 等の提出不明はここでは数えない（既存の即 halt を維持）
  - 起動時 / `warm_from_db/1` — 直近窓の `status == :rejected` Order で ETS を温める
    （時刻軸は拒否に近い `updated_at`。trade_mode ごとに最大 `max_errors` 件）
  - 起動 warm 失敗は空＋unsynced（fail-closed）。実行中 warm 失敗は既存 ETS を維持
  - 未同期時は `evaluate` / `record` / `count` を拒否し、`Risk.authorize/2` も拒否する
  - 起動 warm 失敗の自動再試行はしない（`OrderRate` 同型）。復旧はプロセス再起動か
    明示的な `warm_from_db/1`

  注意: Order に拒否理由は永続化していないため、warm は rejected 全件を数える
  （auth 等の即 halt 理由も含みうる＝過大側・安全側）。cancel 確定拒否は建玉が残るため
  Order を `:rejected` にできず、warm 対象外（実行中カウントは ETS のみ。`warm_from_db`
  成功時は DB 内容で ETS を置換するため cancel 由来件数も消える）。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Trading.Order

  @name __MODULE__
  @default_window_ms 60_000
  @default_max_errors 5
  @trade_modes [:dry_run, :paper, :live]

  @countable_reasons MapSet.new([
                       :rejected_by_exchange,
                       :insufficient_funds,
                       :invalid_order,
                       :invalid_request,
                       :rate_limited
                     ])

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type evaluate_result ::
          :ok | {:halt, :auth_failed | :consecutive_exchange_errors | :failure_rate_unsynced}
  @type count_result :: {:ok, non_neg_integer()} | {:error, :unsynced}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    warm_opts = Keyword.take(opts, [:loader, :window_ms, :now_dt, :now])
    GenServer.start_link(__MODULE__, %{table: name, warm_opts: warm_opts}, name: name)
  end

  @doc """
  取引所エラー理由を評価する。必要なら呼び出し側が `Risk.open_circuit/1` する。

  未同期時は countable 理由で `{:halt, :failure_rate_unsynced}`（クラッシュ後に
  連続障害を見失ったまま発注を続けない）。
  """
  @spec evaluate(term(), keyword()) :: evaluate_result()
  def evaluate(reason, opts \\ [])

  def evaluate(:auth_failed, _opts), do: {:halt, :auth_failed}

  def evaluate(reason, opts) when is_atom(reason) do
    if MapSet.member?(@countable_reasons, reason) do
      trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
      server = Keyword.get(opts, :server, @name)
      max = Keyword.get(opts, :max_errors, max_errors())
      window_ms = Keyword.get(opts, :window_ms, window_ms())
      now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)

      case GenServer.call(server, {:evaluate, trade_mode, now, window_ms, max}) do
        :ok -> :ok
        {:halt, _} = halt -> halt
      end
    else
      :ok
    end
  end

  def evaluate(_reason, _opts), do: :ok

  @doc """
  エラー 1 件を記録する。未同期時は書き込まず `:ok`（count / evaluate と一貫）。
  """
  @spec record(trade_mode(), keyword()) :: :ok
  def record(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:record, trade_mode, opts})
  end

  @doc """
  直近窓のエラー件数。未同期は `{:error, :unsynced}`。
  """
  @spec count(trade_mode(), keyword()) :: count_result()
  def count(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    window_ms = Keyword.get(opts, :window_ms, window_ms())
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    GenServer.call(server, {:count, trade_mode, now, window_ms})
  end

  @doc """
  DB の直近 rejected Order で ETS を置き換えて温める。

  読取成功後にだけ既存 ETS を消して入れ替える。失敗時は既存件数を維持する。
  """
  @spec warm_from_db(keyword()) :: :ok | {:error, term()}
  def warm_from_db(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:warm_from_db, opts})
  end

  @doc """
  全消しして synced に戻す（テスト用）。
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :clear)
  end

  @doc """
  テスト用。未同期にする。
  """
  @spec mark_unsynced(keyword()) :: :ok
  def mark_unsynced(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :mark_unsynced)
  end

  @doc """
  テスト用。ETS を触らず synced に戻す。
  """
  @spec mark_synced(keyword()) :: :ok
  def mark_synced(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :mark_synced)
  end

  @doc """
  warm 済みか。未同期なら authorize は fail-closed。
  """
  @spec synced?(keyword()) :: boolean()
  def synced?(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :synced?)
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
  def init(%{table: table} = args) do
    warm_opts = Map.get(args, :warm_opts, [])
    _ = ensure_table(table)

    case replace_from_db(table, warm_opts) do
      :ok ->
        {:ok, %{table: table, synced: true}}

      {:error, reason} ->
        Bitflyer.Telemetry.log(:error, "failure rate warm failed; marked unsynced", %{
          reason: inspect(reason)
        })

        {:ok, %{table: table, synced: false}}
    end
  end

  @impl true
  def handle_call(
        {:evaluate, _trade_mode, _now, _window_ms, _max},
        _from,
        %{synced: false} = state
      ) do
    {:reply, {:halt, :failure_rate_unsynced}, state}
  end

  def handle_call(
        {:evaluate, trade_mode, now, window_ms, max},
        _from,
        %{table: table, synced: true} = state
      ) do
    true = :ets.insert(table, {trade_mode, now})
    _ = prune(table, trade_mode, now, window_ms)
    count = ets_count(table, trade_mode, now, window_ms)

    if count >= max do
      {:reply, {:halt, :consecutive_exchange_errors}, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:record, _trade_mode, _opts}, _from, %{synced: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:record, trade_mode, opts}, _from, %{table: table, synced: true} = state) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, window_ms())
    true = :ets.insert(table, {trade_mode, now})
    _ = prune(table, trade_mode, now, window_ms)
    {:reply, :ok, state}
  end

  def handle_call({:count, _trade_mode, _now, _window_ms}, _from, %{synced: false} = state) do
    {:reply, {:error, :unsynced}, state}
  end

  def handle_call(
        {:count, trade_mode, now, window_ms},
        _from,
        %{table: table, synced: true} = state
      ) do
    {:reply, {:ok, ets_count(table, trade_mode, now, window_ms)}, state}
  end

  def handle_call({:warm_from_db, opts}, _from, %{table: table} = state) do
    case replace_from_db(table, opts) do
      :ok ->
        {:reply, :ok, %{state | synced: true}}

      {:error, reason} = error ->
        Bitflyer.Telemetry.log(:error, "failure rate warm failed; keeping prior ETS", %{
          reason: inspect(reason)
        })

        {:reply, error, state}
    end
  end

  def handle_call(:clear, _from, %{table: table} = state) do
    true = :ets.delete_all_objects(table)
    {:reply, :ok, %{state | synced: true}}
  end

  def handle_call(:mark_unsynced, _from, state) do
    {:reply, :ok, %{state | synced: false}}
  end

  def handle_call(:mark_synced, _from, state) do
    {:reply, :ok, %{state | synced: true}}
  end

  def handle_call(:synced?, _from, state) do
    {:reply, state.synced, state}
  end

  defp replace_from_db(table, opts) do
    window_ms = Keyword.get(opts, :window_ms, window_ms())
    now_utc = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    now_mono = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    loader = Keyword.get(opts, :loader, &load_recent_rejected/2)

    case loader.(window_ms, now_utc) do
      {:ok, orders} when is_list(orders) ->
        true = :ets.delete_all_objects(table)

        Enum.each(orders, fn order ->
          at = Map.get(order, :updated_at) || Map.get(order, :inserted_at)

          true =
            :ets.insert(table, {order.trade_mode, wall_to_monotonic(at, now_utc, now_mono)})
        end)

        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_loader_result, other}}
    end
  end

  # trade_mode ごとに最大 max_errors 件（サーキット判定に足りる上限）。
  # 窓内が極端に多くても起動を重くしない。
  defp load_recent_rejected(window_ms, %DateTime{} = now_utc) do
    since = DateTime.add(now_utc, -window_ms, :millisecond)
    limit = max_errors()

    Enum.reduce_while(@trade_modes, {:ok, []}, fn trade_mode, {:ok, acc} ->
      case load_rejected_for_mode(trade_mode, since, limit) do
        {:ok, orders} -> {:cont, {:ok, acc ++ orders}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_rejected_for_mode(trade_mode, since, limit) do
    case Order
         |> Ash.Query.filter(
           status == :rejected and trade_mode == ^trade_mode and updated_at >= ^since
         )
         |> Ash.Query.sort(updated_at: :desc)
         |> Ash.Query.limit(limit)
         |> Ash.read() do
      {:ok, orders} -> {:ok, orders}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wall_to_monotonic(%DateTime{} = at, %DateTime{} = now_utc, now_mono)
       when is_integer(now_mono) do
    age_ms = max(DateTime.diff(now_utc, at, :millisecond), 0)
    now_mono - age_ms
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
