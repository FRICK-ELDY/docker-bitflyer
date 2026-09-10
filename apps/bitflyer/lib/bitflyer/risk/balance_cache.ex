defmodule Bitflyer.Risk.BalanceCache do
  @moduledoc """
  利用可能残高の ETS キャッシュ（発注ホットパスから DB を叩かない）。

  ## 更新契約

  - paper fill: `invalidate` → DB コミット → `reload(generation:, release_barrier: true)`
  - live 突合成功: 取引所残高を `put`（barrier 中は synced 化しない）
  - live/paper 発注: `reserve(..., hold_id:)` で原子的減額
  - live 部分約定: `consume_hold_proportional` / `align_hold_to_filled`
  - **終端**（cancelled 等）でのみ `release_hold`。未終端の cancel 受付では hold を残す
  - Snapshot / exchange の絶対 `put` 後は残 hold を再適用（`clear_holds` 時は破棄）

  crash で barrier が残れば `get` は unsynced（過大評価しない）。
  プロセス再起動時は全モード unsynced（fail-closed）。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Trading.BalanceSnapshot

  @name __MODULE__
  @trade_modes [:dry_run, :paper, :live]

  @type trade_mode :: Bitflyer.TradeMode.t()
  @type balances :: %{optional(String.t()) => Decimal.t()}
  @type reload_result :: :ok | {:ok, :deferred} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: name}, name: name)
  end

  @doc """
  残高を返す。未同期・barrier 中・テーブル消失は `{:error, :unsynced}`。
  """
  @spec get(trade_mode(), keyword()) :: {:ok, balances()} | {:error, :unsynced}
  def get(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:get, trade_mode})
  end

  @doc """
  Fill / 更新コミット直前に呼ぶ。synced を外し barrier を増やす。
  """
  @spec invalidate(trade_mode(), keyword()) :: {:ok, non_neg_integer()}
  def invalidate(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:invalidate, trade_mode})
  end

  @doc """
  残高マップを書く。正規化後が空なら `{:error, :empty}`。

  ## Options
  - `:generation` / `:release_barrier` — Fill 経路（DailyLoss と同型）
  - `:clear_holds` — true かつ synced 化に成功したら拘束記録を破棄（取引所残高の絶対 put 用）
  - barrier>0 かつ release なしの put は synced 化せず `{:ok, :deferred}`
  """
  @spec put(trade_mode(), balances(), keyword()) ::
          :ok | {:ok, :deferred} | {:error, :empty} | {:error, term()}
  def put(trade_mode, balances, opts \\ [])
      when trade_mode in @trade_modes and is_map(balances) do
    server = Keyword.get(opts, :server, @name)
    normalized = normalize_balances(balances)

    if map_size(normalized) == 0 do
      _ = GenServer.call(server, {:mark_unsynced, trade_mode})
      {:error, :empty}
    else
      GenServer.call(server, {:put, trade_mode, normalized, opts})
    end
  end

  @doc """
  BalanceSnapshot 先端から読み直して put する（DB 読取は呼び出し元プロセス）。
  """
  @spec reload(keyword()) :: reload_result()
  def reload(opts \\ []) do
    trade_mode = Keyword.fetch!(opts, :trade_mode)
    true = trade_mode in @trade_modes

    case load_latest(trade_mode) do
      {:ok, balances} ->
        case put(trade_mode, balances, opts) do
          :ok -> :ok
          {:ok, :deferred} -> {:ok, :deferred}
          {:error, _} = error -> error
        end

      {:error, reason} = error ->
        _ = mark_unsynced(trade_mode, opts)

        Bitflyer.Telemetry.log(:error, "balance cache reload failed; marked unsynced", %{
          reason: inspect(reason),
          trade_mode: trade_mode
        })

        error
    end
  end

  @doc """
  Snapshot からの安全 reload（突合・resume 用。barrier 中は deferred）。
  """
  @spec refresh(trade_mode(), keyword()) :: reload_result()
  def refresh(trade_mode, opts \\ []) when trade_mode in @trade_modes do
    reload(Keyword.put(opts, :trade_mode, trade_mode))
  end

  @doc """
  利用可能額を原子的に減額する。不足・未同期はエラー。

  `:hold_id`（通常は `internal_order_id`）を渡すと拘束額を記録し、
  取消時は `release_hold/3` で **同じ額** を戻す（LTP 再計算しない）。
  """
  @spec reserve(trade_mode(), String.t(), Decimal.t(), keyword()) ::
          :ok
          | {:error, :unsynced}
          | {:error, :insufficient_balance, map()}
          | {:error, :hold_exists}
  def reserve(trade_mode, currency, %Decimal{} = amount, opts \\ [])
      when trade_mode in @trade_modes and is_binary(currency) do
    server = Keyword.get(opts, :server, @name)
    hold_id = Keyword.get(opts, :hold_id)
    GenServer.call(server, {:reserve, trade_mode, currency, amount, hold_id})
  end

  @doc """
  拘束の一部を消費する（残高は足さない）。live 部分約定用。

  `amount` は拘束残のうち消化する額。残が 0 以下なら hold を削除する。
  """
  @spec consume_hold(trade_mode(), String.t(), Decimal.t(), keyword()) :: :ok
  def consume_hold(trade_mode, hold_id, %Decimal{} = amount, opts \\ [])
      when trade_mode in @trade_modes and is_binary(hold_id) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:consume_hold, trade_mode, hold_id, amount})
  end

  @doc """
  約定サイズ比で拘束を減らす（残高は足さない）。

  `consume = hold_amount * filled_delta / size_remaining_before`
  """
  @spec consume_hold_proportional(
          trade_mode(),
          String.t(),
          Decimal.t(),
          Decimal.t(),
          keyword()
        ) :: :ok
  def consume_hold_proportional(
        trade_mode,
        hold_id,
        %Decimal{} = filled_delta,
        %Decimal{} = size_remaining_before,
        opts \\ []
      )
      when trade_mode in @trade_modes and is_binary(hold_id) do
    server = Keyword.get(opts, :server, @name)

    GenServer.call(
      server,
      {:consume_hold_proportional, trade_mode, hold_id, filled_delta, size_remaining_before}
    )
  end

  @doc """
  注文の `filled_size` に合わせて hold 残を切り詰める（残高は足さない）。

  consume 欠落後でも `original * (size - filled) / size` を上限に揃える。
  """
  @spec align_hold_to_filled(trade_mode(), String.t(), Decimal.t(), Decimal.t(), keyword()) :: :ok
  def align_hold_to_filled(
        trade_mode,
        hold_id,
        %Decimal{} = filled_size,
        %Decimal{} = order_size,
        opts \\ []
      )
      when trade_mode in @trade_modes and is_binary(hold_id) do
    server = Keyword.get(opts, :server, @name)

    GenServer.call(
      server,
      {:align_hold_to_filled, trade_mode, hold_id, filled_size, order_size}
    )
  end

  @doc """
  `reserve(..., hold_id:)` で記録した拘束を、記録どおりの残額で戻す。
  未知の hold_id は no-op（`:ok`）。
  """
  @spec release_hold(trade_mode(), String.t(), keyword()) :: :ok
  def release_hold(trade_mode, hold_id, opts \\ [])
      when trade_mode in @trade_modes and is_binary(hold_id) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:release_hold, trade_mode, hold_id, :credit})
  end

  @doc """
  拘束記録だけ捨てる（残高は足さない）。paper fill 後の Snapshot 正本 reload 用。
  """
  @spec discard_hold(trade_mode(), String.t(), keyword()) :: :ok
  def discard_hold(trade_mode, hold_id, opts \\ [])
      when trade_mode in @trade_modes and is_binary(hold_id) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:release_hold, trade_mode, hold_id, :discard})
  end

  @doc """
  予約を戻す（hold_id 無しの即時経路・テスト用）。
  """
  @spec release(trade_mode(), String.t(), Decimal.t(), keyword()) :: :ok
  def release(trade_mode, currency, %Decimal{} = amount, opts \\ [])
      when trade_mode in @trade_modes and is_binary(currency) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:release, trade_mode, currency, amount})
  end

  @doc """
  未同期にする（barrier は増やさない）。
  """
  @spec mark_unsynced(trade_mode() | :all, keyword()) :: :ok
  def mark_unsynced(trade_mode \\ :all, opts \\ [])

  def mark_unsynced(:all, opts) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :mark_all_unsynced)
  end

  def mark_unsynced(trade_mode, opts) when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:mark_unsynced, trade_mode})
  end

  @doc """
  テスト用。全モードを unsynced・barrier 0 に戻す。
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :reset)
  end

  @impl true
  def init(%{table: table}) do
    _ = ensure_table(table)

    Enum.each(@trade_modes, fn mode ->
      insert_row(table, {mode, %{}, false, 0, 0})
      true = :ets.insert(table, {holds_key(mode), %{}})
    end)

    {:ok, table}
  end

  @impl true
  def handle_call({:get, trade_mode}, _from, table) do
    reply =
      try do
        case read_mode(table, trade_mode) do
          {balances, true, 0, _gen} when map_size(balances) > 0 ->
            {:ok, balances}

          _ ->
            {:error, :unsynced}
        end
      rescue
        ArgumentError -> {:error, :unsynced}
      end

    {:reply, reply, table}
  end

  def handle_call({:invalidate, trade_mode}, _from, table) do
    {balances, _synced, barrier, gen} = read_mode(table, trade_mode)
    new_gen = gen + 1
    insert_row(table, {trade_mode, balances, false, barrier + 1, new_gen})
    {:reply, {:ok, new_gen}, table}
  end

  def handle_call({:put, trade_mode, balances, opts}, _from, table) do
    release? = Keyword.get(opts, :release_barrier, false)
    load_gen = Keyword.get(opts, :generation)
    clear_holds? = Keyword.get(opts, :clear_holds, false)

    {old_balances, _synced, barrier, gen} = read_mode(table, trade_mode)

    reply =
      cond do
        release? and is_integer(load_gen) and gen != load_gen ->
          new_barrier = max(barrier - 1, 0)
          insert_row(table, {trade_mode, old_balances, false, new_barrier, gen})
          {:ok, :deferred}

        release? and is_integer(load_gen) ->
          new_barrier = max(barrier - 1, 0)
          synced? = new_barrier == 0
          insert_row(table, {trade_mode, balances, synced?, new_barrier, gen})

          if synced? do
            finalize_absolute_put!(table, trade_mode, clear_holds?)
            :ok
          else
            {:ok, :deferred}
          end

        barrier > 0 ->
          # 突合側: in-flight 中は古い／別経路の put で synced 化しない
          {:ok, :deferred}

        true ->
          insert_row(table, {trade_mode, balances, true, 0, gen})
          finalize_absolute_put!(table, trade_mode, clear_holds?)
          :ok
      end

    {:reply, reply, table}
  end

  def handle_call({:reserve, trade_mode, currency, amount, hold_id}, _from, table) do
    reply =
      case read_mode(table, trade_mode) do
        {balances, true, 0, gen} when map_size(balances) > 0 ->
          holds = read_holds(table, trade_mode)

          cond do
            is_binary(hold_id) and Map.has_key?(holds, hold_id) ->
              {:error, :hold_exists}

            true ->
              case Map.fetch(balances, currency) do
                :error ->
                  {:error, :unsynced}

                {:ok, available} ->
                  if Decimal.lt?(available, amount) do
                    {:error, :insufficient_balance,
                     %{
                       currency: currency,
                       available: available,
                       required: amount
                     }}
                  else
                    next = Map.put(balances, currency, Decimal.sub(available, amount))
                    insert_row(table, {trade_mode, next, true, 0, gen})

                    if is_binary(hold_id) do
                      write_holds!(
                        table,
                        trade_mode,
                        Map.put(holds, hold_id, {currency, amount, amount})
                      )
                    end

                    :ok
                  end
              end
          end

        _ ->
          {:error, :unsynced}
      end

    {:reply, reply, table}
  end

  def handle_call({:consume_hold, trade_mode, hold_id, amount}, _from, table) do
    holds = read_holds(table, trade_mode)

    case Map.fetch(holds, hold_id) do
      :error ->
        {:reply, :ok, table}

      {:ok, hold} ->
        {currency, remaining, original} = hold_parts(hold)
        next_remaining = Decimal.sub(remaining, amount)

        holds =
          if Decimal.compare(next_remaining, 0) != :gt do
            Map.delete(holds, hold_id)
          else
            Map.put(holds, hold_id, {currency, next_remaining, original})
          end

        write_holds!(table, trade_mode, holds)
        {:reply, :ok, table}
    end
  end

  def handle_call(
        {:consume_hold_proportional, trade_mode, hold_id, filled_delta, size_remaining_before},
        _from,
        table
      ) do
    holds = read_holds(table, trade_mode)

    reply =
      cond do
        Decimal.compare(size_remaining_before, 0) != :gt ->
          :ok

        true ->
          case Map.fetch(holds, hold_id) do
            :error ->
              :ok

            {:ok, hold} ->
              {currency, remaining, original} = hold_parts(hold)

              consumed =
                remaining
                |> Decimal.mult(filled_delta)
                |> Decimal.div(size_remaining_before)

              next_remaining = Decimal.sub(remaining, consumed)

              holds =
                if Decimal.compare(next_remaining, 0) != :gt do
                  Map.delete(holds, hold_id)
                else
                  Map.put(holds, hold_id, {currency, next_remaining, original})
                end

              write_holds!(table, trade_mode, holds)
              :ok
          end
      end

    {:reply, reply, table}
  end

  def handle_call(
        {:align_hold_to_filled, trade_mode, hold_id, filled_size, order_size},
        _from,
        table
      ) do
    holds = read_holds(table, trade_mode)

    reply =
      cond do
        Decimal.compare(order_size, 0) != :gt ->
          :ok

        true ->
          case Map.fetch(holds, hold_id) do
            :error ->
              :ok

            {:ok, hold} ->
              {currency, remaining, original} = hold_parts(hold)
              unfilled = Decimal.sub(order_size, filled_size)

              unfilled =
                if Decimal.compare(unfilled, 0) == :lt, do: Decimal.new(0), else: unfilled

              desired =
                original
                |> Decimal.mult(unfilled)
                |> Decimal.div(order_size)

              next_remaining =
                if Decimal.compare(remaining, desired) == :gt, do: desired, else: remaining

              holds =
                if Decimal.compare(next_remaining, 0) != :gt do
                  Map.delete(holds, hold_id)
                else
                  Map.put(holds, hold_id, {currency, next_remaining, original})
                end

              write_holds!(table, trade_mode, holds)
              :ok
          end
      end

    {:reply, reply, table}
  end

  def handle_call({:release_hold, trade_mode, hold_id, mode}, _from, table) do
    holds = read_holds(table, trade_mode)

    case Map.pop(holds, hold_id) do
      {nil, _} ->
        {:reply, :ok, table}

      {hold, rest} ->
        {currency, amount, _original} = hold_parts(hold)
        write_holds!(table, trade_mode, rest)

        if mode == :credit do
          {balances, synced, barrier, gen} = read_mode(table, trade_mode)

          next =
            Map.update(balances, currency, amount, fn available ->
              Decimal.add(available, amount)
            end)

          insert_row(
            table,
            {trade_mode, next, synced and barrier == 0 and map_size(next) > 0, barrier, gen}
          )
        end

        {:reply, :ok, table}
    end
  end

  def handle_call({:release, trade_mode, currency, amount}, _from, table) do
    {balances, synced, barrier, gen} = read_mode(table, trade_mode)

    next =
      Map.update(balances, currency, amount, fn available ->
        Decimal.add(available, amount)
      end)

    # release だけでは synced 化しない（barrier / 未同期を維持）
    insert_row(
      table,
      {trade_mode, next, synced and barrier == 0 and map_size(next) > 0, barrier, gen}
    )

    {:reply, :ok, table}
  end

  def handle_call({:mark_unsynced, trade_mode}, _from, table) do
    {balances, _synced, barrier, gen} = read_mode(table, trade_mode)
    insert_row(table, {trade_mode, balances, false, barrier, gen})
    {:reply, :ok, table}
  end

  def handle_call(:mark_all_unsynced, _from, table) do
    Enum.each(@trade_modes, fn mode ->
      {balances, _synced, barrier, gen} = read_mode(table, mode)
      insert_row(table, {mode, balances, false, barrier, gen})
    end)

    {:reply, :ok, table}
  end

  def handle_call(:reset, _from, table) do
    Enum.each(@trade_modes, fn mode ->
      insert_row(table, {mode, %{}, false, 0, 0})
      clear_holds!(table, mode)
    end)

    {:reply, :ok, table}
  end

  defp holds_key(trade_mode), do: {:holds, trade_mode}

  defp hold_parts({currency, remaining, original}), do: {currency, remaining, original}
  defp hold_parts({currency, remaining}), do: {currency, remaining, remaining}

  defp read_holds(table, trade_mode) do
    case :ets.lookup(table, holds_key(trade_mode)) do
      [{_, holds}] when is_map(holds) -> holds
      _ -> %{}
    end
  end

  defp write_holds!(table, trade_mode, holds) do
    true = :ets.insert(table, {holds_key(trade_mode), holds})
  end

  defp clear_holds!(table, trade_mode), do: write_holds!(table, trade_mode, %{})

  defp finalize_absolute_put!(table, trade_mode, true = _clear_holds?) do
    clear_holds!(table, trade_mode)
  end

  defp finalize_absolute_put!(table, trade_mode, false) do
    reapply_holds!(table, trade_mode)
  end

  # Snapshot / tip の絶対残高の上に、未決済 hold を再度減額する。
  # 足りなければ fail-closed で unsynced。
  defp reapply_holds!(table, trade_mode) do
    holds = read_holds(table, trade_mode)
    {balances, _synced, barrier, gen} = read_mode(table, trade_mode)

    case Enum.reduce_while(holds, {:ok, balances}, fn {_id, hold}, {:ok, acc} ->
           {currency, amount, _original} = hold_parts(hold)

           case Map.fetch(acc, currency) do
             :error ->
               {:halt, :unsynced}

             {:ok, available} ->
               if Decimal.lt?(available, amount) do
                 {:halt, :unsynced}
               else
                 {:cont, {:ok, Map.put(acc, currency, Decimal.sub(available, amount))}}
               end
           end
         end) do
      {:ok, next} ->
        synced? = barrier == 0 and map_size(next) > 0
        insert_row(table, {trade_mode, next, synced?, barrier, gen})

      :unsynced ->
        insert_row(table, {trade_mode, balances, false, barrier, gen})

        Bitflyer.Telemetry.log(
          :error,
          "balance cache reapply holds failed; marked unsynced",
          %{trade_mode: trade_mode, holds: map_size(holds)}
        )
    end
  end

  defp read_mode(table, trade_mode) do
    case :ets.lookup(table, trade_mode) do
      [{^trade_mode, balances, synced, barrier, gen}] ->
        {balances, synced, barrier, gen}

      [] ->
        {%{}, false, 0, 0}
    end
  end

  defp insert_row(table, {mode, balances, synced, barrier, gen}) do
    true = :ets.insert(table, {mode, balances, synced, barrier, gen})
  end

  defp ensure_table(table) when is_atom(table) do
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
  end

  defp normalize_balances(balances) do
    balances
    |> Enum.map(fn {currency, value} ->
      available =
        case value do
          %{available: val} -> to_decimal(val)
          %{"available" => val} -> to_decimal(val)
          %Decimal{} = val -> val
          val -> to_decimal(val)
        end

      {normalize_currency(currency), available}
    end)
    |> Enum.reject(fn {currency, available} -> is_nil(currency) or is_nil(available) end)
    |> Map.new()
  end

  defp normalize_currency(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_currency(key) when is_binary(key), do: key
  defp normalize_currency(_), do: nil

  defp to_decimal(%Decimal{} = d), do: d

  defp to_decimal(raw) when is_binary(raw) do
    case Decimal.parse(raw) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp to_decimal(raw) when is_integer(raw), do: Decimal.new(raw)
  defp to_decimal(raw) when is_float(raw), do: Decimal.from_float(raw)
  defp to_decimal(_), do: nil

  defp load_latest(trade_mode) do
    case BalanceSnapshot
         |> Ash.Query.filter(trade_mode == ^trade_mode)
         |> Ash.Query.sort(captured_at: :desc, id: :desc)
         |> Ash.read() do
      {:ok, rows} ->
        balances =
          rows
          |> Enum.reduce(%{}, fn row, acc ->
            Map.put_new(acc, row.currency, row.available || row.amount)
          end)

        {:ok, balances}

      {:error, error} ->
        {:error, error}
    end
  end
end
