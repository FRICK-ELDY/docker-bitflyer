defmodule Bitflyer.Risk.DailyLoss do
  @moduledoc """
  当日実現損失の ETS キャッシュ（発注ホットパスから DB を叩かない）。

  正本は `Fill.realized_pnl`。ETS は Fill からの再集計結果と、
  当日 equity ピーク（`DailyEquityPeak`）を持つ。ピーク上昇の persist は
  GenServer の外で行い、init / reload / reinit で当日行を読む。
  読取・永続化失敗は unsynced（fail-closed）。

  認可は `persist: false` で ETS だけ上げる。永続化は Fill 後 / 突合 /
  resume の `Equity.enforce`（既定 persist）。HWM は Fill 合計ではない。
  reload は同日 ETS と DB の高い方を残し、日付跨ぎは当日行だけを使う。

  ## 競合安全（invalidate 窓）

  Fill 反映は次の手順:

  1. `invalidate/2` — `barrier` を増やし synced を外す。世代トークンを返す
  2. DB コミット
  3. `reload(generation:, release_barrier: true)` — 同じ世代でのみ解放・synced 化

  突合・resume・boot の `reload/1` は、barrier>0 または読取開始時と世代が
  食い違うスナップショットを **決して synced にしない**。
  `force: true` も barrier を無視しない（in-flight Fill 中の Ready 化を防ぐ）。

  crash で barrier が張り付いた場合は DailyLoss プロセス再起動（`init` で正本再読）
  かテスト用 `reset/1` で復旧する。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Trading.{DailyEquityPeak, Fill}

  @name __MODULE__
  @trade_modes [:dry_run, :paper, :live]
  # bitFlyer は日本市場。JST は通年 UTC+9（DST なし）なので tzdata 不要。
  @jst_offset_seconds 9 * 60 * 60

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type reload_result :: :ok | {:ok, :deferred} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  当日損失・実現 net・equity ピーク（HWM）を返す。
  未同期・barrier 中・日付未再集計は `{:error, :unsynced}`。
  """
  @spec snapshot(trade_mode(), keyword()) ::
          {:ok, %{loss: Decimal.t(), net: Decimal.t(), peak: Decimal.t()}} | {:error, :unsynced}
  def snapshot(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)

    case GenServer.call(server, {:peek_snapshot, trade_mode, now}) do
      {:ok, loss, net, peak} ->
        {:ok, %{loss: loss, net: net, peak: peak}}

      :stale_day ->
        case reload(Keyword.merge(opts, trade_mode: trade_mode, now_dt: now)) do
          :ok ->
            case GenServer.call(server, {:peek_snapshot, trade_mode, now}) do
              {:ok, loss, net, peak} -> {:ok, %{loss: loss, net: net, peak: peak}}
              _ -> {:error, :unsynced}
            end

          _ ->
            {:error, :unsynced}
        end

      :unsynced ->
        {:error, :unsynced}
    end
  end

  @doc """
  当日損失を返す。未同期・barrier 中・日付未再集計は `{:error, :unsynced}`。
  """
  @spec get(trade_mode(), keyword()) :: {:ok, Decimal.t()} | {:error, :unsynced}
  def get(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    case snapshot(trade_mode, opts) do
      {:ok, %{loss: loss}} -> {:ok, loss}
      {:error, :unsynced} -> {:error, :unsynced}
    end
  end

  @doc """
  Fill コミット直前に呼ぶ。synced を外し barrier を増やす。

  戻り値の世代は、対応する `reload(generation:, release_barrier: true)` に渡す。
  """
  @spec invalidate(trade_mode(), keyword()) :: {:ok, non_neg_integer()}
  def invalidate(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:invalidate, trade_mode})
  end

  @doc """
  Fill から当日損失を再集計する（DB 読取は呼び出し元）。

  ## Options
  - `:trade_mode` — 1 モードだけ（未指定なら全モード）
  - `:generation` — `invalidate/2` が返した世代（fill 経路で必須相当）
  - `:release_barrier` — true なら当該 invalidate の barrier を 1 減らす
  - `:force` — 互換のため残すが **barrier を無視しない**（安全 reload と同じ）
  - `:now_dt` / `:server`

  戻り値:
  - `:ok` — 対象モードが synced
  - `{:ok, :deferred}` — barrier / 世代競合で synced にしていない（fail-closed）
  - `{:error, reason}` — DB 読取失敗（対象は unsynced）
  """
  @spec reload(keyword()) :: reload_result()
  def reload(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    force? = Keyword.get(opts, :force, false)
    release? = Keyword.get(opts, :release_barrier, false)

    modes =
      case Keyword.get(opts, :trade_mode) do
        nil -> @trade_modes
        mode when mode in @trade_modes -> [mode]
      end

    load_gens =
      case Keyword.fetch(opts, :generation) do
        {:ok, gen} when is_integer(gen) and length(modes) == 1 ->
          %{hd(modes) => gen}

        :error ->
          GenServer.call(server, {:snapshot_generations, modes})

        {:ok, _} ->
          raise ArgumentError, ":generation requires a single :trade_mode"
      end

    case load_modes(modes, now) do
      {:ok, rows} ->
        GenServer.call(server, {:apply_rows, rows, load_gens, force?, release?})

      {:error, reason} = error ->
        _ = GenServer.call(server, {:mark_unsynced_keep_barrier, modes})

        Bitflyer.Telemetry.log(:error, "daily loss reload failed; marked unsynced", %{
          reason: inspect(reason),
          trade_modes: modes
        })

        error
    end
  end

  @doc """
  テスト用。synced・barrier 0・損失 0 に戻す（Fill は触らない）。
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    GenServer.call(server, {:reset, now})
  end

  @doc """
  テスト用。未計測扱いにする（barrier は増やさない）。
  """
  @spec mark_unsynced(keyword()) :: :ok
  def mark_unsynced(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :mark_unsynced)
  end

  @doc """
  テスト用。Fill を経由せず当日損失を直接置く（peak は 0 に戻す）。
  """
  @spec seed_loss(trade_mode(), Decimal.t(), keyword()) :: :ok
  def seed_loss(trade_mode, %Decimal{} = loss, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    GenServer.call(server, {:seed_loss, trade_mode, loss, now})
  end

  @doc """
  テスト用。Fill を経由せず当日実現 net を直接置く（peak は維持）。
  """
  @spec seed_net(trade_mode(), Decimal.t(), keyword()) :: :ok
  def seed_net(trade_mode, %Decimal{} = net, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    GenServer.call(server, {:seed_net, trade_mode, net, now})
  end

  @doc """
  当日 equity PnL のピーク（HWM）を上げる。日始は 0。負のピークは持たない。

  上昇時だけ `DailyEquityPeak` に upsert する。Ash は GenServer の外。
  永続化失敗は当該モードを unsynced にして `{:error, :unsynced}`。
  ETS の日付が壁時計と違うときは先に `reload` し、当日の ETS も更新する。

  ## Options
  - `:persist` — `false` なら ETS のみ（認可ホットパス）。関数なら
    `(trade_mode, Date.t(), Decimal.t() -> :ok | {:error, term()})`（テスト用）
  """
  @spec record_peak(trade_mode(), Decimal.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, :unsynced}
  def record_peak(trade_mode, %Decimal{} = equity_pnl, opts \\ [])
      when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    persist = Keyword.get(opts, :persist, &DailyEquityPeak.upsert/3)
    do_record_peak(server, trade_mode, equity_pnl, now, persist, opts, false)
  end

  @doc """
  プロセス再起動相当。ETS を捨てて当日 Fill 合計と永続 HWM から読み直す。
  読取失敗は unsynced。
  """
  @spec reinit(keyword()) :: :ok | {:error, term()}
  def reinit(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    now = Keyword.get_lazy(opts, :now_dt, &DateTime.utc_now/0)
    GenServer.call(server, {:reinit, now})
  end

  @doc """
  壁時計 `now`（UTC）の JST 取引日。
  """
  @spec trading_day(DateTime.t()) :: Date.t()
  def trading_day(%DateTime{} = now) do
    now
    |> DateTime.add(@jst_offset_seconds, :second)
    |> DateTime.to_date()
  end

  defp do_record_peak(server, trade_mode, equity_pnl, now, persist, opts, reloaded?) do
    case GenServer.call(server, {:prepare_peak, trade_mode, equity_pnl, now}) do
      {:ok, peak} ->
        {:ok, peak}

      :stale_day when reloaded? ->
        {:error, :unsynced}

      :stale_day ->
        case reload(Keyword.merge(opts, trade_mode: trade_mode, now_dt: now)) do
          :ok ->
            do_record_peak(server, trade_mode, equity_pnl, now, persist, opts, true)

          _ ->
            {:error, :unsynced}
        end

      {:rise, day, new_peak} ->
        persist_and_commit(server, trade_mode, day, new_peak, persist)
    end
  end

  defp persist_and_commit(server, trade_mode, day, new_peak, false) do
    GenServer.call(server, {:commit_peak, trade_mode, day, new_peak})
  end

  defp persist_and_commit(server, trade_mode, day, new_peak, persist)
       when is_function(persist, 3) do
    case persist.(trade_mode, day, new_peak) do
      :ok ->
        GenServer.call(server, {:commit_peak, trade_mode, day, new_peak})

      {:error, reason} ->
        _ = GenServer.call(server, {:peak_persist_failed, trade_mode, day, reason})
        {:error, :unsynced}

      other ->
        _ = GenServer.call(server, {:peak_persist_failed, trade_mode, day, other})
        {:error, :unsynced}
    end
  end

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)
    now = DateTime.utc_now()

    case load_modes(@trade_modes, now) do
      {:ok, rows} ->
        Enum.each(rows, fn {mode, day, loss, net, true, peak} ->
          insert_row(table, {mode, day, loss, net, true, 0, 0, peak})
        end)

        {:ok, table}

      {:error, reason} ->
        Enum.each(@trade_modes, fn mode ->
          insert_row(
            table,
            {mode, trading_day(now), Decimal.new(0), Decimal.new(0), false, 0, 0, zero()}
          )
        end)

        Bitflyer.Telemetry.log(:error, "daily loss init load failed; marked unsynced", %{
          reason: inspect(reason)
        })

        {:ok, table}
    end
  end

  @impl true
  def handle_call({:peek_snapshot, trade_mode, now}, _from, table) do
    day = trading_day(now)

    reply =
      case :ets.lookup(table, trade_mode) do
        [{^trade_mode, ^day, loss, net, true, 0, _gen, peak}] ->
          {:ok, loss, net, peak}

        [{^trade_mode, other_day, _loss, _net, true, 0, _gen, _peak}] when other_day != day ->
          :stale_day

        _ ->
          :unsynced
      end

    {:reply, reply, table}
  end

  def handle_call({:invalidate, trade_mode}, _from, table) do
    {day, loss, net, _synced, barrier, gen, peak} = read_mode(table, trade_mode)
    new_gen = gen + 1
    new_barrier = barrier + 1
    insert_row(table, {trade_mode, day, loss, net, false, new_barrier, new_gen, peak})
    {:reply, {:ok, new_gen}, table}
  end

  def handle_call({:snapshot_generations, modes}, _from, table) do
    gens =
      Map.new(modes, fn mode ->
        {_day, _loss, _net, _synced, _barrier, gen, _peak} = read_mode(table, mode)
        {mode, gen}
      end)

    {:reply, gens, table}
  end

  def handle_call({:apply_rows, rows, load_gens, force?, release?}, _from, table) do
    outcomes =
      Enum.map(rows, fn {mode, day, loss, net, _true, loaded_peak} ->
        apply_one(
          table,
          mode,
          day,
          loss,
          net,
          loaded_peak,
          Map.fetch!(load_gens, mode),
          force?,
          release?
        )
      end)

    reply =
      cond do
        Enum.any?(outcomes, &(&1 == :error)) ->
          {:error, :apply_failed}

        Enum.any?(outcomes, &(&1 in [:deferred, :contended])) ->
          {:ok, :deferred}

        true ->
          :ok
      end

    {:reply, reply, table}
  end

  def handle_call({:mark_unsynced_keep_barrier, modes}, _from, table) do
    Enum.each(modes, fn mode ->
      {day, loss, net, _synced, barrier, gen, peak} = read_mode(table, mode)
      insert_row(table, {mode, day, loss, net, false, barrier, gen, peak})
    end)

    {:reply, :ok, table}
  end

  def handle_call({:reset, now}, _from, table) do
    day = trading_day(now)

    Enum.each(@trade_modes, fn mode ->
      insert_row(table, {mode, day, Decimal.new(0), Decimal.new(0), true, 0, 0, zero()})
    end)

    {:reply, :ok, table}
  end

  def handle_call(:mark_unsynced, _from, table) do
    Enum.each(@trade_modes, fn mode ->
      {day, loss, net, _synced, barrier, gen, peak} = read_mode(table, mode)
      insert_row(table, {mode, day, loss, net, false, barrier, gen, peak})
    end)

    {:reply, :ok, table}
  end

  def handle_call({:seed_loss, trade_mode, loss, now}, _from, table) do
    day = trading_day(now)
    net = Decimal.negate(loss)
    {_d, _l, _n, _s, _b, gen, _peak} = read_mode(table, trade_mode)
    insert_row(table, {trade_mode, day, loss, net, true, 0, gen, zero()})
    {:reply, :ok, table}
  end

  def handle_call({:seed_net, trade_mode, net, now}, _from, table) do
    day = trading_day(now)
    loss = loss_from_net(net)
    {_d, _l, _n, _s, _b, gen, peak} = read_mode(table, trade_mode)
    insert_row(table, {trade_mode, day, loss, net, true, 0, gen, peak})
    {:reply, :ok, table}
  end

  def handle_call({:reinit, now}, _from, table) do
    case load_modes(@trade_modes, now) do
      {:ok, rows} ->
        Enum.each(rows, fn {mode, day, loss, net, true, peak} ->
          insert_row(table, {mode, day, loss, net, true, 0, 0, peak})
        end)

        {:reply, :ok, table}

      {:error, reason} ->
        Enum.each(@trade_modes, fn mode ->
          insert_row(
            table,
            {mode, trading_day(now), Decimal.new(0), Decimal.new(0), false, 0, 0, zero()}
          )
        end)

        Bitflyer.Telemetry.log(:error, "daily loss reinit load failed; marked unsynced", %{
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, table}
    end
  end

  def handle_call({:prepare_peak, trade_mode, equity_pnl, now}, _from, table) do
    day = trading_day(now)
    {row_day, _loss, _net, _synced, _barrier, _gen, peak} = read_mode(table, trade_mode)

    cond do
      row_day != day ->
        {:reply, :stale_day, table}

      true ->
        new_peak = equity_pnl |> Decimal.max(peak) |> Decimal.max(zero())

        if Decimal.compare(new_peak, peak) == :gt do
          {:reply, {:rise, day, new_peak}, table}
        else
          {:reply, {:ok, new_peak}, table}
        end
    end
  end

  def handle_call({:commit_peak, trade_mode, day, new_peak}, _from, table) do
    {row_day, loss, net, synced, barrier, gen, peak} = read_mode(table, trade_mode)

    stored =
      if row_day == day do
        stored = Decimal.max(peak, new_peak)
        insert_row(table, {trade_mode, row_day, loss, net, synced, barrier, gen, stored})
        stored
      else
        peak
      end

    {:reply, {:ok, stored}, table}
  end

  def handle_call({:peak_persist_failed, trade_mode, day, reason}, _from, table) do
    {row_day, loss, net, _synced, barrier, gen, peak} = read_mode(table, trade_mode)
    insert_row(table, {trade_mode, row_day, loss, net, false, barrier, gen, peak})

    Bitflyer.Telemetry.log(
      :error,
      "daily equity peak persist failed; marked unsynced",
      %{reason: inspect(reason), trade_mode: trade_mode, trading_day: Date.to_iso8601(day)}
    )

    {:reply, :ok, table}
  end

  defp apply_one(table, mode, day, loss, net, loaded_peak, load_gen, true = _force?, release?) do
    # force でも in-flight barrier は尊重する（resume 並行 fill の過小評価を防ぐ）
    apply_one(table, mode, day, loss, net, loaded_peak, load_gen, false, release?)
  end

  defp apply_one(table, mode, day, loss, net, loaded_peak, load_gen, false, true = _release?) do
    {old_day, old_loss, old_net, _synced, barrier, gen, peak} = read_mode(table, mode)

    cond do
      gen != load_gen ->
        # 後続 invalidate で世代が進んだ。自分の barrier だけ返して破棄。
        new_barrier = max(barrier - 1, 0)
        insert_row(table, {mode, old_day, old_loss, old_net, false, new_barrier, gen, peak})
        :contended

      true ->
        new_barrier = max(barrier - 1, 0)
        synced? = new_barrier == 0

        insert_row(
          table,
          {mode, day, loss, net, synced?, new_barrier, gen,
           resolve_peak(old_day, day, peak, loaded_peak)}
        )

        if synced?, do: :ok, else: :deferred
    end
  end

  defp apply_one(table, mode, day, loss, net, loaded_peak, load_gen, false, false) do
    {old_day, _l, _n, _synced, barrier, gen, peak} = read_mode(table, mode)

    cond do
      barrier > 0 ->
        # in-flight Fill。古いスナップショットで synced に戻さない。
        :deferred

      gen != load_gen ->
        :deferred

      true ->
        insert_row(
          table,
          {mode, day, loss, net, true, 0, gen, resolve_peak(old_day, day, peak, loaded_peak)}
        )

        :ok
    end
  end

  defp read_mode(table, trade_mode) do
    case :ets.lookup(table, trade_mode) do
      [{^trade_mode, day, loss, net, synced, barrier, gen, peak}] ->
        {day, loss, net, synced, barrier, gen, peak}

      [] ->
        {trading_day(DateTime.utc_now()), Decimal.new(0), Decimal.new(0), false, 0, 0, zero()}
    end
  end

  defp insert_row(table, {mode, day, loss, net, synced, barrier, gen, peak}) do
    true = :ets.insert(table, {mode, day, loss, net, synced, barrier, gen, peak})
  end

  # 同日: ETS と DB の高い方（読取後の record_peak を戻さない、init 失敗の 0 は DB で埋める）。
  # 日付跨ぎ: 当日行だけ（昨日の ETS は捨てる）。
  defp resolve_peak(old_day, day, ets_peak, loaded_peak) when old_day == day do
    Decimal.max(ets_peak, loaded_peak)
  end

  defp resolve_peak(_old_day, _day, _ets_peak, loaded_peak), do: loaded_peak

  defp zero, do: Decimal.new(0)

  defp ensure_table(table) when is_atom(table) do
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
  end

  defp loss_from_net(%Decimal{} = net) do
    if Decimal.compare(net, Decimal.new(0)) == :lt do
      Decimal.negate(net)
    else
      Decimal.new(0)
    end
  end

  defp load_modes(modes, %DateTime{} = now) do
    day = trading_day(now)
    {start_utc, end_utc} = day_bounds_utc(day)

    with {:ok, peaks} <- load_peaks(modes, day) do
      Enum.reduce_while(modes, {:ok, []}, fn mode, {:ok, acc} ->
        case sum_realized(mode, start_utc, end_utc) do
          {:ok, net} ->
            peak = Map.fetch!(peaks, mode)
            {:cont, {:ok, [{mode, day, loss_from_net(net), net, true, peak} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp load_peaks(modes, %Date{} = day) do
    case DailyEquityPeak.fetch_day(day) do
      {:ok, rows} ->
        found = Map.new(rows, &{&1.trade_mode, &1.peak})
        {:ok, Map.new(modes, fn mode -> {mode, Map.get(found, mode, zero())} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sum_realized(trade_mode, start_utc, end_utc) do
    case Fill
         |> Ash.Query.filter(
           trade_mode == ^trade_mode and filled_at >= ^start_utc and filled_at < ^end_utc
         )
         |> Ash.read() do
      {:ok, fills} ->
        net =
          Enum.reduce(fills, Decimal.new(0), fn fill, acc ->
            Decimal.add(acc, fill.realized_pnl || Decimal.new(0))
          end)

        {:ok, net}

      {:error, error} ->
        {:error, error}
    end
  end

  defp day_bounds_utc(%Date{} = jst_day) do
    {:ok, jst_midnight_as_utc} = DateTime.new(jst_day, ~T[00:00:00], "Etc/UTC")
    start_utc = DateTime.add(jst_midnight_as_utc, -@jst_offset_seconds, :second)
    end_utc = DateTime.add(start_utc, 1, :day)
    {start_utc, end_utc}
  end
end
