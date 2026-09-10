defmodule Bitflyer.Risk.OrderRate do
  @moduledoc """
  直近の発注件数を ETS で数える（発注ホットパスから DB を叩かない）。

  - `record/2` — pending 作成成功時に呼ぶ
  - `count/2` — 直近 `window_ms`（既定 60_000）の件数。未同期は `{:error, :unsynced}`
  - 起動時 / `warm_from_db/1` — 直近 1 分の Order を ETS に温める（再起動後の頻度上限すり抜け防止）

  ETS は monotonic ms、Order は壁時計 `inserted_at`。温め時は年齢差分で写す。
  warm は DB 読取成功後にだけ ETS を置き換える。読取失敗時は既存件数を消しません。
  起動時の warm 失敗は空＋unsynced（fail-closed。件数 0 でのすり抜けを防ぐ）。

  直近窓は status を問わず読む（pending 作成後に状態が変わっても「試行」として残す）。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Trading.Order

  @name __MODULE__
  @default_window_ms 60_000
  @trade_modes [:dry_run, :paper, :live]

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type count_result :: {:ok, non_neg_integer()} | {:error, :unsynced}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    warm_opts = Keyword.take(opts, [:loader, :window_ms, :now_dt, :now])
    GenServer.start_link(__MODULE__, %{table: name, warm_opts: warm_opts}, name: name)
  end

  @doc """
  発注 1 件を記録する。
  """
  @spec record(trade_mode(), keyword()) :: :ok
  def record(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:record, trade_mode, opts})
  end

  @doc """
  直近窓の発注件数。未同期・テーブル消失は `{:error, :unsynced}`。
  """
  @spec count(trade_mode(), keyword()) :: count_result()
  def count(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    GenServer.call(server, {:count, trade_mode, now, window_ms})
  end

  @doc """
  DB の直近 Order で ETS を置き換えて温める。

  読取成功後にだけ既存 ETS を消して入れ替える。失敗時は既存件数を維持する。

  ## Options
  - `:window_ms` — 既定 60_000
  - `:now_dt` — 壁時計（窓の切断面）
  - `:now` — monotonic ms（ETS 写像用）
  - `:loader` — テスト用 `{window_ms, now_dt} -> {:ok, orders} | {:error, reason}`
  - `:server`
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

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc false
  @spec window_ms() :: pos_integer()
  def window_ms, do: @default_window_ms

  @impl true
  def init(%{table: table} = args) do
    warm_opts = Map.get(args, :warm_opts, [])
    _ = ensure_table(table)

    case replace_from_db(table, warm_opts) do
      :ok ->
        {:ok, %{table: table, synced: true}}

      {:error, reason} ->
        Bitflyer.Telemetry.log(:error, "order rate warm failed; marked unsynced", %{
          reason: inspect(reason)
        })

        {:ok, %{table: table, synced: false}}
    end
  end

  @impl true
  def handle_call({:record, trade_mode, opts}, _from, %{table: table} = state) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
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
        Bitflyer.Telemetry.log(:error, "order rate warm failed; keeping prior ETS", %{
          reason: inspect(reason)
        })

        # 既存件数は消さない。同期状態も変えない（init 失敗の unsynced は別経路）。
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

  # DB 成功後にだけ delete → insert（失敗時は ETS を触らない）
  defp replace_from_db(table, opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now_utc = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    now_mono = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    loader = Keyword.get(opts, :loader, &load_recent_orders/2)

    case loader.(window_ms, now_utc) do
      {:ok, orders} when is_list(orders) ->
        rows =
          Enum.map(orders, fn order ->
            {order.trade_mode, wall_to_monotonic(order.inserted_at, now_utc, now_mono)}
          end)

        true = :ets.delete_all_objects(table)
        Enum.each(rows, fn row -> true = :ets.insert(table, row) end)
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_loader_result, other}}
    end
  end

  defp load_recent_orders(window_ms, %DateTime{} = now_utc) do
    since = DateTime.add(now_utc, -window_ms, :millisecond)

    # status 不問: record は pending 作成時のみだが、その後の状態変化で試行を消さない
    case Order
         |> Ash.Query.filter(inserted_at >= ^since)
         |> Ash.read() do
      {:ok, orders} -> {:ok, orders}
      {:error, reason} -> {:error, reason}
    end
  end

  # 壁時計の年齢を monotonic に写す。未来時刻は age 0。
  defp wall_to_monotonic(%DateTime{} = inserted_at, %DateTime{} = now_utc, now_mono)
       when is_integer(now_mono) do
    age_ms = max(DateTime.diff(now_utc, inserted_at, :millisecond), 0)
    now_mono - age_ms
  end

  defp ensure_table(table) when is_atom(table) do
    # 同一ミリ秒の複数発注を数えるため duplicate_bag（:bag は同一タプルを1件に畳む）
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
