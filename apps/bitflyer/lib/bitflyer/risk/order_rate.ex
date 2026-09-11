defmodule Bitflyer.Risk.OrderRate do
  @moduledoc """
  直近の発注件数を ETS で数える（発注ホットパスから DB を叩かない）。

  - `reserve/3` — `Risk.authorize/2` 時に原子的に枠を確保（count と確保が同一 GenServer 境界）
  - `commit/2` — pending 作成成功時。予約枠を確定（現状は枠を残すだけ）
  - `release/2` — 認可後の失敗・未使用トークン破棄時に枠を返す
  - `record/2` — テスト／互換用に確定枠を直接挿入
  - `count/2` — 直近 `window_ms`（既定 60_000）の件数（予約＋確定）。未同期は `{:error, :unsynced}`
  - 起動時 / `warm_from_db/1` — 直近 1 分の Order を ETS に温める（未 commit 予約は残す）

  ETS 行は `{trade_mode, monotonic_ms, id}`。`id` は予約 `reference()` または確定 `:committed`。
  warm は DB 読取成功後にだけ ETS を置き換える。起動時 warm 失敗は空＋unsynced。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Trading.Order

  @name __MODULE__
  @default_window_ms 60_000
  @trade_modes [:dry_run, :paper, :live]

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type reservation :: %{id: reference(), trade_mode: trade_mode(), at_ms: integer()} | :skip
  @type count_result :: {:ok, non_neg_integer()} | {:error, :unsynced}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    warm_opts = Keyword.take(opts, [:loader, :window_ms, :now_dt, :now])
    GenServer.start_link(__MODULE__, %{table: name, warm_opts: warm_opts}, name: name)
  end

  @doc """
  上限未満なら原子的に 1 枠予約する。`count >= max` なら拒否。
  """
  @spec reserve(trade_mode(), non_neg_integer(), keyword()) ::
          {:ok, reservation()}
          | {:error, :limit_exceeded, %{count: non_neg_integer(), max: non_neg_integer()}}
          | {:error, :unsynced}
  def reserve(trade_mode, max, opts \\ [])
      when trade_mode in @trade_modes and is_integer(max) and max >= 0 do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:reserve, trade_mode, max, opts})
  end

  @doc """
  予約を確定する。枠は既に count に含まれるため、現状は存在確認のみ。
  """
  @spec commit(reservation(), keyword()) :: :ok
  def commit(reservation, opts \\ [])

  def commit(:skip, _opts), do: :ok
  def commit(nil, _opts), do: :ok

  def commit(%{id: id, trade_mode: trade_mode, at_ms: at_ms} = reservation, opts)
      when is_reference(id) and trade_mode in @trade_modes and is_integer(at_ms) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:commit, reservation})
  end

  @doc """
  予約枠を取り消す（認可後失敗・未使用トークン破棄）。
  """
  @spec release(reservation(), keyword()) :: :ok
  def release(reservation, opts \\ [])

  def release(:skip, _opts), do: :ok
  def release(nil, _opts), do: :ok

  def release(%{id: id, trade_mode: trade_mode, at_ms: at_ms} = reservation, opts)
      when is_reference(id) and trade_mode in @trade_modes and is_integer(at_ms) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:release, reservation})
  end

  @doc """
  確定枠を 1 件記録する（テスト／warm 互換。本番ホットパスは reserve→commit）。
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
  def handle_call({:reserve, _trade_mode, _max, _opts}, _from, %{synced: false} = state) do
    {:reply, {:error, :unsynced}, state}
  end

  def handle_call(
        {:reserve, trade_mode, max, opts},
        _from,
        %{table: table, synced: true} = state
      ) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    _ = prune(table, trade_mode, now, window_ms)
    count = ets_count(table, trade_mode, now, window_ms)

    if count >= max do
      {:reply, {:error, :limit_exceeded, %{count: count, max: max}}, state}
    else
      id = make_ref()
      true = :ets.insert(table, {trade_mode, now, id})
      reservation = %{id: id, trade_mode: trade_mode, at_ms: now}
      {:reply, {:ok, reservation}, state}
    end
  end

  def handle_call({:commit, reservation}, _from, %{table: table} = state) do
    # 予約行が残っていれば確定タグへ（無くても :ok — 二重 commit 耐性）
    %{id: id, trade_mode: trade_mode, at_ms: at_ms} = reservation

    case :ets.match_object(table, {trade_mode, at_ms, id}) do
      [{^trade_mode, ^at_ms, ^id}] ->
        true = :ets.delete_object(table, {trade_mode, at_ms, id})
        true = :ets.insert(table, {trade_mode, at_ms, :committed})

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:release, reservation}, _from, %{table: table} = state) do
    %{id: id, trade_mode: trade_mode, at_ms: at_ms} = reservation
    _ = :ets.delete_object(table, {trade_mode, at_ms, id})
    {:reply, :ok, state}
  end

  def handle_call({:record, trade_mode, opts}, _from, %{table: table} = state) do
    now = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    true = :ets.insert(table, {trade_mode, now, :committed})
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

  # DB 成功後にだけ committed 行を差し替える。未 commit の予約 (reference id) は残す
  # （実行中 warm で枠が消えて頻度上限をすり抜けるのを防ぐ）。
  defp replace_from_db(table, opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now_utc = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    now_mono = Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    loader = Keyword.get(opts, :loader, &load_recent_orders/2)

    case loader.(window_ms, now_utc) do
      {:ok, orders} when is_list(orders) ->
        rows =
          Enum.map(orders, fn order ->
            {order.trade_mode, wall_to_monotonic(order.inserted_at, now_utc, now_mono),
             :committed}
          end)

        _ = :ets.select_delete(table, [{{:_, :_, :committed}, [], [true]}])
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

    case Order
         |> Ash.Query.filter(inserted_at >= ^since)
         |> Ash.read() do
      {:ok, orders} -> {:ok, orders}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wall_to_monotonic(%DateTime{} = inserted_at, %DateTime{} = now_utc, now_mono)
       when is_integer(now_mono) do
    age_ms = max(DateTime.diff(now_utc, inserted_at, :millisecond), 0)
    now_mono - age_ms
  end

  defp ensure_table(table) when is_atom(table) do
    # 同一ミリ秒の複数枠を数えるため duplicate_bag
    :ets.new(table, [:named_table, :protected, :duplicate_bag, read_concurrency: true])
  end

  defp ets_count(table, trade_mode, now, window_ms)
       when is_atom(table) or is_reference(table) do
    since = now - window_ms

    try do
      :ets.select_count(table, [
        {{trade_mode, :"$1", :_}, [{:>=, :"$1", since}], [true]}
      ])
    rescue
      ArgumentError -> 0
    end
  end

  defp prune(table, trade_mode, now, window_ms) do
    since = now - window_ms

    _ =
      :ets.select_delete(table, [
        {{trade_mode, :"$1", :_}, [{:<, :"$1", since}], [true]}
      ])

    :ok
  end
end
