defmodule Bitflyer.OrderExecutor.LiveFills do
  @moduledoc """
  live 注文の約定を取引所照会から内部建玉へ反映する。

  - 建玉: `Positions.apply_fill` で差分反映（Risk が DB Position を見るため必須）
  - 残高: **触らない**。live の残高正本は `getbalance` 突合（紙の `Balances.apply_fill` は FX と矛盾する）
  - 発注認可前（`System.submit_order`）・発注後・取消後・定期突合前に呼ぶ
  - `sync_open_orders/1` は最小間隔で間引き（認可前の連打抑制）。突合は `:force`

  間引き中は直近の試行を信頼して `:ok` を返す（1s 以内に他 open の未反映約定があると
  認可時建玉が古くなりうる意図的トレードオフ。最終安全網は起動・定期突合の `:force`）。

  ## Options（`sync_open_orders/1`）
  - `:exchange` — 既定 `Bitflyer.Exchange`
  - `:force` — true なら最小間隔を無視（起動・定期突合用）
  - `:now` — monotonic ms（テスト用）
  """

  require Ash.Query

  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Trading.Order

  @last_sync_key {__MODULE__, :last_open_orders_sync_ms}
  @sync_lock_resource {__MODULE__, :open_orders_sync}
  @default_min_sync_interval_ms 1_000

  @doc """
  `pending` / `partially_filled` の live 注文を取引所状態に合わせて進める。

  最小間隔の判定・ロック取得・時計更新は同一クリティカルセクションで行う。
  時計は成功/失敗を問わず「試行開始時」に進め、失敗連打での private REST 連打を抑える。
  """
  @spec sync_open_orders(keyword()) :: :ok | {:error, atom(), map()}
  def sync_open_orders(opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    now = Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)

    if not force? and recently_synced_open_orders?(now) do
      :ok
    else
      with_open_orders_sync_lock(force?, fn ->
        # ロック後に再判定（並行 submit の間引きすり抜け防止）
        if not force? and recently_synced_open_orders?(now) do
          :ok
        else
          # 試行時点で時計を進める（失敗継続でも間隔を守る）
          _ = mark_open_orders_synced(now)
          do_sync_open_orders(opts)
        end
      end)
    end
  end

  @doc false
  @spec clear_open_orders_sync_clock() :: :ok
  def clear_open_orders_sync_clock do
    :persistent_term.erase(@last_sync_key)
    :ok
  end

  defp with_open_orders_sync_lock(force?, fun) when is_function(fun, 0) do
    lock_id = {@sync_lock_resource, self()}
    nodes = [Node.self()]

    acquired? =
      if force? do
        # 突合は他の認可前 sync 完了を待つ（スキップしない）
        true = :global.set_lock(lock_id, nodes)
        true
      else
        :global.set_lock(lock_id, nodes, 0)
      end

    if acquired? do
      try do
        fun.()
      after
        :global.del_lock(lock_id, nodes)
      end
    else
      # 他プロセスが sync 中 → 間引き扱い（過大 REST 防止）
      :ok
    end
  end

  defp do_sync_open_orders(opts) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    case list_open_live_orders() do
      {:ok, orders} ->
        Enum.reduce_while(orders, :ok, fn order, :ok ->
          case sync_order(order, exchange: exchange) do
            :ok -> {:cont, :ok}
            {:ok, _} -> {:cont, :ok}
            {:error, _, _} = error -> {:halt, error}
          end
        end)

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp recently_synced_open_orders?(now) when is_integer(now) do
    case :persistent_term.get(@last_sync_key, :missing) do
      last when is_integer(last) ->
        now - last < min_sync_interval_ms()

      :missing ->
        false
    end
  end

  defp mark_open_orders_synced(now) when is_integer(now) do
    :persistent_term.put(@last_sync_key, now)
    :ok
  end

  defp min_sync_interval_ms do
    Application.get_env(:bitflyer, __MODULE__, [])
    |> Keyword.get(:min_sync_interval_ms, @default_min_sync_interval_ms)
  end

  @doc """
  1 注文を取引所状態へ寄せる。取消直後の fill 回収にも使う。
  """
  @spec sync_order(Order.t(), keyword()) :: :ok | {:ok, Order.t()} | {:error, atom(), map()}
  def sync_order(%Order{} = order, opts \\ []) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    if order.trade_mode != :live or is_nil(order.exchange_order_id) do
      :ok
    else
      with :ok <- ensure_consistent_filled_baseline(order) do
        do_sync(order, exchange)
      end
    end
  end

  defp list_open_live_orders do
    Order
    |> Ash.Query.filter(
      trade_mode == :live and status in [:pending, :partially_filled] and
        not is_nil(exchange_order_id)
    )
    |> Ash.read()
  end

  defp do_sync(%Order{} = order, exchange) do
    request = %{
      product_code: order.product_code,
      exchange_order_id: order.exchange_order_id
    }

    case exchange.fetch_order(request) do
      {:ok, info} ->
        apply_order_info(order, info, exchange)

      {:error, :order_not_found} ->
        recover_missing_order(order, exchange)

      {:error, reason} ->
        {:error, :exchange_error, %{reason: reason, internal_order_id: order.internal_order_id}}
    end
  end

  # getchildorders に出ない（未約定取消・窓外など）。約定があれば載せてから終端化する。
  defp recover_missing_order(%Order{} = order, exchange) do
    Bitflyer.Telemetry.log(
      :warning,
      "live order not found on exchange; recovering via executions",
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        product_code: order.product_code,
        trade_mode: :live
      }
    )

    case exchange.fetch_executions(%{
           product_code: order.product_code,
           exchange_order_id: order.exchange_order_id
         }) do
      {:ok, executions} ->
        remote_filled =
          Enum.reduce(executions, Decimal.new("0"), fn exec, acc ->
            Decimal.add(acc, exec.size)
          end)

        local_filled = order.filled_size || Decimal.new("0")
        delta = Decimal.sub(remote_filled, local_filled)

        info = %{
          exchange_order_id: order.exchange_order_id,
          product_code: order.product_code,
          side: order.side,
          size: order.size,
          filled_size: remote_filled,
          average_price: average_price_from_executions(executions),
          # 一覧に無い = 板から消えている。fill 後は cancelled（全量なら filled）
          status: :canceled
        }

        cond do
          Decimal.compare(delta, 0) == :gt ->
            reflect_fill(order, info, delta, exchange)

          Decimal.compare(remote_filled, 0) == :gt ->
            # 既にローカルへ載せ済み。終端化のみ
            terminal =
              if Decimal.compare(remote_filled, order.size) != :lt,
                do: :filled,
                else: :cancelled

            mark_terminal(order, terminal, remote_filled)

          true ->
            # 約定なしで消えた → 未約定取消扱い
            mark_terminal(order, :cancelled, local_filled)
        end

      {:error, reason} ->
        # 照会不能は fail-closed（黙って open のままにしない）
        {:error, :exchange_error,
         %{
           reason: reason,
           internal_order_id: order.internal_order_id,
           cause: :order_not_found_recovery_failed
         }}
    end
  end

  defp average_price_from_executions([]), do: nil

  defp average_price_from_executions(executions) do
    case avg_from_executions(executions) do
      {:ok, price} -> price
      _ -> nil
    end
  end

  defp apply_order_info(%Order{} = order, info, exchange) do
    remote_filled = info.filled_size
    local_filled = order.filled_size || Decimal.new("0")
    delta = Decimal.sub(remote_filled, local_filled)

    cond do
      Decimal.compare(delta, 0) == :gt ->
        reflect_fill(order, info, delta, exchange)

      info.status in [:canceled, :expired, :rejected] ->
        mark_terminal(order, map_terminal_status(info.status), remote_filled)

      info.status == :completed and order.status != :filled ->
        mark_terminal(order, :filled, remote_filled)

      true ->
        :ok
    end
  end

  defp reflect_fill(%Order{} = order, info, delta, exchange) do
    case fill_price(order, info, exchange) do
      {:ok, price, new_filled_notional} ->
        apply_fill_transaction(order, info, delta, price, new_filled_notional)

      {:error, _, _} = error ->
        error
    end
  end

  # 取引所の累積 average_price から、未反映分の増分約定価格を求める。
  # incremental = (remote_avg × remote_filled − local_notional) / delta
  defp fill_price(%Order{} = order, info, exchange) do
    with {:ok, remote_avg} <- remote_average_price(order, info, exchange) do
      incremental_fill_price(order, remote_avg, info.filled_size)
    end
  end

  defp remote_average_price(%Order{} = order, info, exchange) do
    cond do
      match?(%Decimal{}, info.average_price) and Decimal.positive?(info.average_price) ->
        {:ok, info.average_price}

      true ->
        case exchange.fetch_executions(%{
               product_code: order.product_code,
               exchange_order_id: order.exchange_order_id
             }) do
          {:ok, executions} ->
            avg_from_executions(executions)

          {:error, reason} ->
            {:error, :exchange_error, %{reason: reason}}
        end
    end
  end

  defp incremental_fill_price(%Order{} = order, remote_avg, remote_filled) do
    local_notional = order.filled_notional || Decimal.new("0")
    local_filled = order.filled_size || Decimal.new("0")
    delta = Decimal.sub(remote_filled, local_filled)
    remote_notional = Decimal.mult(remote_avg, remote_filled)
    incremental_notional = Decimal.sub(remote_notional, local_notional)

    cond do
      inconsistent_filled_baseline?(local_filled, local_notional) ->
        refuse_inconsistent_filled_notional(order, local_filled, local_notional)

      Decimal.compare(delta, 0) != :gt ->
        {:error, :fill_price_unavailable, %{reason: :non_positive_delta}}

      Decimal.compare(incremental_notional, 0) != :gt ->
        Bitflyer.Telemetry.log(
          :error,
          "live fill refused: non-positive incremental notional",
          %{
            internal_order_id: order.internal_order_id,
            exchange_order_id: order.exchange_order_id,
            local_notional: local_notional,
            remote_notional: remote_notional,
            incremental_notional: incremental_notional,
            trade_mode: :live
          }
        )

        {:error, :fill_price_unavailable,
         %{
           reason: :non_positive_incremental_notional,
           local_notional: local_notional,
           remote_notional: remote_notional,
           incremental_notional: incremental_notional,
           internal_order_id: order.internal_order_id
         }}

      true ->
        {:ok, Decimal.div(incremental_notional, delta), remote_notional}
    end
  end

  # オープン注文の列挙・sync 入口で検査する。delta=0 でも黙って通さない。
  defp ensure_consistent_filled_baseline(%Order{} = order) do
    local_filled = order.filled_size || Decimal.new("0")
    local_notional = order.filled_notional || Decimal.new("0")

    if inconsistent_filled_baseline?(local_filled, local_notional) do
      refuse_inconsistent_filled_notional(order, local_filled, local_notional)
    else
      :ok
    end
  end

  defp refuse_inconsistent_filled_notional(%Order{} = order, local_filled, local_notional) do
    Bitflyer.Telemetry.log(
      :error,
      "live fill refused: inconsistent filled_notional baseline",
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        filled_size: local_filled,
        filled_notional: local_notional,
        trade_mode: :live
      }
    )

    {:error, :fill_price_unavailable,
     %{
       reason: :inconsistent_filled_notional,
       filled_size: local_filled,
       filled_notional: local_notional,
       internal_order_id: order.internal_order_id
     }}
  end

  # filled_size と filled_notional は対で進む。片方だけ動いている状態では増分を計算しない。
  defp inconsistent_filled_baseline?(local_filled, local_notional) do
    size_positive? = Decimal.compare(local_filled, 0) == :gt
    notional_positive? = Decimal.compare(local_notional, 0) == :gt

    (size_positive? and not notional_positive?) or (notional_positive? and not size_positive?)
  end

  defp avg_from_executions([]), do: {:error, :fill_price_unavailable, %{}}

  defp avg_from_executions(executions) do
    {notional, size} =
      Enum.reduce(executions, {Decimal.new("0"), Decimal.new("0")}, fn exec, {n, s} ->
        {Decimal.add(n, Decimal.mult(exec.price, exec.size)), Decimal.add(s, exec.size)}
      end)

    if Decimal.equal?(size, Decimal.new("0")) do
      {:error, :fill_price_unavailable, %{}}
    else
      {:ok, Decimal.div(notional, size)}
    end
  end

  defp apply_fill_transaction(%Order{} = order, info, delta, fill_price, new_filled_notional) do
    new_filled = Decimal.add(order.filled_size || Decimal.new("0"), delta)
    status = status_after_fill(order.size, new_filled, info.status)

    # 差分サイズだけ建玉へ。残高は live では更新しない（getbalance 突合が正本）
    delta_order = %{order | size: delta, filled_size: delta}

    Bitflyer.OrderExecutor.DailyLossSync.around_fill(:live, fn ->
      case Bitflyer.Repo.transaction(fn ->
             with {:ok, updated, order_notifications} <-
                    update_order(order, %{
                      status: status,
                      filled_size: new_filled,
                      filled_notional: new_filled_notional
                    }),
                  {:ok, position_notifications, _fill_meta} <-
                    Positions.apply_fill(delta_order, fill_price) do
               {updated, order_notifications ++ position_notifications}
             else
               {:error, code, meta} when is_atom(code) and is_map(meta) ->
                 Bitflyer.Repo.rollback({code, meta})

               other ->
                 Bitflyer.Repo.rollback(other)
             end
           end) do
        {:ok, {updated, notifications}} ->
          _ = Ash.Notifier.notify(notifications)
          _ = consume_live_hold(order, delta)

          if updated.status == :filled do
            _ = Bitflyer.Risk.BalanceCache.discard_hold(:live, updated.internal_order_id)
          end

          Bitflyer.Telemetry.execute(
            :order_filled,
            %{count: 1},
            %{
              internal_order_id: updated.internal_order_id,
              exchange_order_id: updated.exchange_order_id,
              product_code: updated.product_code,
              side: updated.side,
              trade_mode: :live,
              status: updated.status
            }
          )

          {:ok, updated}

        {:error, {code, meta}} when is_atom(code) and is_map(meta) ->
          {:error, code, meta}

        {:error, error} ->
          {:error, :persist_failed, %{error: error}}
      end
    end)
  end

  defp consume_live_hold(%Order{} = order, %Decimal{} = delta) do
    remaining_before = Decimal.sub(order.size, order.filled_size || Decimal.new("0"))

    Bitflyer.Risk.BalanceCache.consume_hold_proportional(
      :live,
      order.internal_order_id,
      delta,
      remaining_before
    )
  end

  defp status_after_fill(order_size, filled_size, remote_status) do
    cond do
      remote_status in [:canceled, :expired, :rejected] ->
        # 取消・失効後に未反映 fill を載せた場合は open に残さない
        if Decimal.compare(filled_size, order_size) != :lt,
          do: :filled,
          else: map_terminal_status(remote_status)

      remote_status == :completed ->
        :filled

      Decimal.compare(filled_size, order_size) != :lt ->
        :filled

      true ->
        :partially_filled
    end
  end

  defp map_terminal_status(:canceled), do: :cancelled
  defp map_terminal_status(:expired), do: :expired
  defp map_terminal_status(:rejected), do: :rejected
  defp map_terminal_status(_), do: :cancelled

  defp mark_terminal(%Order{} = order, status, filled_size) do
    local_filled = order.filled_size || Decimal.new("0")
    local_notional = order.filled_notional || Decimal.new("0")

    cond do
      # 終端化だけで filled_size を動かすと notional と対にならず増分 baseline が壊れる
      Decimal.compare(filled_size, local_filled) != :eq ->
        Bitflyer.Telemetry.log(
          :error,
          "live fill refused: terminal filled_size mismatch without notional update",
          %{
            internal_order_id: order.internal_order_id,
            exchange_order_id: order.exchange_order_id,
            local_filled: local_filled,
            terminal_filled: filled_size,
            trade_mode: :live
          }
        )

        {:error, :fill_price_unavailable,
         %{
           reason: :terminal_filled_size_mismatch,
           local_filled: local_filled,
           terminal_filled: filled_size,
           internal_order_id: order.internal_order_id
         }}

      # size 一致でも notional 欠落のまま cancelled にすると Fill 未記帳のまま閉じる
      inconsistent_filled_baseline?(local_filled, local_notional) ->
        refuse_inconsistent_filled_notional(order, local_filled, local_notional)

      true ->
        case update_order(order, %{status: status, filled_size: filled_size}) do
          {:ok, updated, notifications} ->
            _ = Ash.Notifier.notify(notifications)
            _ = settle_hold_on_terminal(updated)
            {:ok, updated}

          {:error, _, _} = error ->
            error
        end
    end
  end

  defp settle_hold_on_terminal(%Order{status: :filled} = order) do
    Bitflyer.Risk.BalanceCache.discard_hold(:live, order.internal_order_id)
  end

  defp settle_hold_on_terminal(%Order{status: status} = order)
       when status in [:cancelled, :expired, :rejected] do
    filled = order.filled_size || Decimal.new(0)

    _ =
      Bitflyer.Risk.BalanceCache.align_hold_to_filled(
        :live,
        order.internal_order_id,
        filled,
        order.size
      )

    Bitflyer.Risk.BalanceCache.release_hold(:live, order.internal_order_id)
  end

  defp settle_hold_on_terminal(%Order{}), do: :ok

  defp update_order(%Order{} = order, attrs) do
    case order
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(return_notifications?: true) do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end
end
