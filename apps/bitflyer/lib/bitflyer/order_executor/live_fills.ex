defmodule Bitflyer.OrderExecutor.LiveFills do
  @moduledoc """
  live 注文の約定を取引所照会から内部建玉へ反映する。

  - 建玉: `Positions.apply_fill` で **execution 単位**に反映（`exchange_execution_id` 付き）
  - 残高: **触らない**。live の残高正本は `getbalance` 突合（紙の `Balances.apply_fill` は FX と矛盾する）
  - 発注認可前（`System.submit_order`）・発注後・取消後・定期突合前に呼ぶ
  - `sync_open_orders/1` は `LiveFills.Gate` で最小間隔＋単一ノード直列化（認可前の連打抑制）。
    突合は `:force`
  - 増分があるとき `getexecutions` 必須。サイズが remote_filled と一致しない・id 欠落は fail-closed
  - 旧経路の live Fill（`exchange_execution_id` nil）上での追加約定は `:legacy_nil_execution_id` で拒否
  - API の同一 execution id 二重返却は `uniq` してから coverage する
  - Gate は失敗試行でも時計を進める（P0 #5）。legacy は恒久失敗になりやすいので
    **デプロイ前に open live の nil id Fill がゼロであること**が前提（`Fill` moduledoc の SQL）

  間引き中は直近の試行を信頼して `:ok` を返す（1s 以内に他 open の未反映約定があると
  認可時建玉が古くなりうる意図的トレードオフ。最終安全網は起動・定期突合の `:force`）。

  ## Options（`sync_open_orders/1`）
  - `:exchange` — 既定 `Bitflyer.Exchange`
  - `:force` — true なら最小間隔を無視（起動・定期突合用）
  - `:now` — monotonic ms（テスト用）
  """

  require Ash.Query

  alias Bitflyer.OrderExecutor.LiveFills.Gate
  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Trading.{Fill, Order}

  @doc """
  `pending` / `partially_filled` の live 注文を取引所状態に合わせて進める。

  最小間隔の判定・直列化・時計更新は `Gate` が担う（sync 本体は呼び出し元で実行）。
  時計は成功/失敗を問わず「試行開始時」に進め、失敗連打での private REST 連打を抑える。
  """
  @spec sync_open_orders(keyword()) :: :ok | {:error, atom(), map()}
  def sync_open_orders(opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    now = Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)

    case Gate.begin(force?, now) do
      :skip ->
        :ok

      :run ->
        try do
          do_sync_open_orders(opts)
        after
          Gate.release()
        end
    end
  end

  @doc false
  @spec clear_open_orders_sync_clock() :: :ok
  def clear_open_orders_sync_clock do
    Gate.clear_clock()
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
          average_price: nil,
          # 一覧に無い = 板から消えている。fill 後は cancelled（全量なら filled）
          status: :canceled
        }

        cond do
          Decimal.compare(delta, 0) == :gt ->
            apply_executions(order, info, executions)

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

  defp apply_order_info(%Order{} = order, info, exchange) do
    remote_filled = info.filled_size
    local_filled = order.filled_size || Decimal.new("0")
    delta = Decimal.sub(remote_filled, local_filled)

    cond do
      Decimal.compare(delta, 0) == :gt ->
        reflect_fill(order, info, exchange)

      info.status in [:canceled, :expired, :rejected] ->
        mark_terminal(order, map_terminal_status(info.status), remote_filled)

      info.status == :completed and order.status != :filled ->
        mark_terminal(order, :filled, remote_filled)

      true ->
        :ok
    end
  end

  defp reflect_fill(%Order{} = order, info, exchange) do
    case exchange.fetch_executions(%{
           product_code: order.product_code,
           exchange_order_id: order.exchange_order_id
         }) do
      {:ok, executions} ->
        apply_executions(order, info, executions)

      {:error, reason} ->
        {:error, :exchange_error,
         %{
           reason: reason,
           internal_order_id: order.internal_order_id,
           cause: :executions_required_for_fill
         }}
    end
  end

  defp apply_executions(%Order{} = order, info, executions) when is_list(executions) do
    executions = uniq_executions(executions)

    with :ok <- ensure_consistent_filled_baseline(order),
         {:ok, legacy_nil?} <- has_legacy_nil_execution_fills?(order),
         {:ok, known_ids} <- known_execution_ids(order) do
      new_execs = new_executions(executions, known_ids)
      remote = info.filled_size || Decimal.new("0")
      local = order.filled_size || Decimal.new("0")
      delta = Decimal.sub(remote, local)

      cond do
        # 本変更以前の live Fill は id=nil。known_ids から落ちるため追加約定を
        # 再記帳しようとすると new_total != delta で恒久失敗する。増分があるうちは明示拒否。
        # 呼び出し側: 認可前 sync は当該 submit 拒否のみ / post-place・reconcile は halt しうる。
        legacy_nil? and Decimal.compare(delta, 0) == :gt ->
          refuse_legacy_nil_execution_id(order)

        # 数量は一致済みなら終端ステータスだけ進める（再記帳しない）
        legacy_nil? ->
          apply_order_info_without_delta(order, info)

        true ->
          with :ok <- ensure_execution_coverage(order, info, executions, new_execs) do
            if new_execs == [] do
              apply_order_info_without_delta(order, info)
            else
              apply_new_executions_transaction(order, info, new_execs)
            end
          end
      end
    end
  end

  defp apply_order_info_without_delta(%Order{} = order, info) do
    remote_filled = info.filled_size

    cond do
      info.status in [:canceled, :expired, :rejected] ->
        mark_terminal(order, map_terminal_status(info.status), remote_filled)

      info.status == :completed and order.status != :filled ->
        mark_terminal(order, :filled, remote_filled)

      true ->
        :ok
    end
  end

  defp known_execution_ids(%Order{} = order) do
    case Fill
         |> Ash.Query.filter(
           trade_mode == ^order.trade_mode and internal_order_id == ^order.internal_order_id and
             not is_nil(exchange_execution_id)
         )
         |> Ash.read() do
      {:ok, fills} ->
        {:ok, MapSet.new(Enum.map(fills, & &1.exchange_execution_id))}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  # live かつ exchange_execution_id IS NULL の Fill は旧経路の証跡。追加約定の差分記帳に使えない。
  defp has_legacy_nil_execution_fills?(%Order{} = order) do
    case Fill
         |> Ash.Query.filter(
           trade_mode == :live and internal_order_id == ^order.internal_order_id and
             is_nil(exchange_execution_id)
         )
         |> Ash.read() do
      {:ok, []} ->
        {:ok, false}

      {:ok, _} ->
        {:ok, true}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp refuse_legacy_nil_execution_id(%Order{} = order) do
    Bitflyer.Telemetry.log(
      :error,
      "live fill refused: legacy nil exchange_execution_id baseline (deploy SQL must be 0 for open live)",
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        trade_mode: :live
      }
    )

    {:error, :fill_price_unavailable,
     %{
       reason: :legacy_nil_execution_id,
       internal_order_id: order.internal_order_id
     }}
  end

  defp uniq_executions(executions) when is_list(executions) do
    executions
    |> Enum.reduce({[], MapSet.new()}, fn exec, {acc, seen} ->
      id = normalize_execution_id(exec.id)

      cond do
        is_nil(id) ->
          {[exec | acc], seen}

        MapSet.member?(seen, id) ->
          {acc, seen}

        true ->
          {[exec | acc], MapSet.put(seen, id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp new_executions(executions, %MapSet{} = known_ids) do
    executions
    |> Enum.filter(fn exec ->
      id = normalize_execution_id(exec.id)
      is_binary(id) and not MapSet.member?(known_ids, id)
    end)
    |> Enum.sort_by(fn exec ->
      at = Map.get(exec, :executed_at)

      {if(match?(%DateTime{}, at), do: DateTime.to_unix(at, :microsecond), else: 0),
       normalize_execution_id(exec.id)}
    end)
  end

  defp normalize_execution_id(id) when is_binary(id), do: id
  defp normalize_execution_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_execution_id(_), do: nil

  # API 全約定サイズが remote_filled と一致し、未反映分の合計が delta と一致すること。
  defp ensure_execution_coverage(%Order{} = order, info, all_execs, new_execs) do
    remote = info.filled_size || Decimal.new("0")
    local = order.filled_size || Decimal.new("0")
    delta = Decimal.sub(remote, local)

    exec_total =
      Enum.reduce(all_execs, Decimal.new("0"), fn exec, acc -> Decimal.add(acc, exec.size) end)

    new_total =
      Enum.reduce(new_execs, Decimal.new("0"), fn exec, acc -> Decimal.add(acc, exec.size) end)

    cond do
      Enum.any?(all_execs, fn exec -> is_nil(normalize_execution_id(exec.id)) end) ->
        {:error, :fill_price_unavailable,
         %{reason: :missing_execution_id, internal_order_id: order.internal_order_id}}

      Decimal.compare(exec_total, remote) != :eq ->
        meta = %{
          reason: :execution_size_mismatch,
          exec_total: exec_total,
          remote_filled: remote,
          exec_count: length(all_execs),
          internal_order_id: order.internal_order_id
        }

        # bitFlyer getexecutions の count 上限付近。ページ欠けの可能性を観測用に残す。
        meta =
          if length(all_execs) >= 500 do
            Map.put(meta, :hint, :execution_page_may_be_truncated)
          else
            meta
          end

        {:error, :fill_price_unavailable, meta}

      Decimal.compare(new_total, delta) != :eq ->
        {:error, :fill_price_unavailable,
         %{
           reason: :new_execution_delta_mismatch,
           new_total: new_total,
           delta: delta,
           internal_order_id: order.internal_order_id
         }}

      true ->
        :ok
    end
  end

  defp apply_new_executions_transaction(%Order{} = order, info, new_execs) do
    total_delta =
      Enum.reduce(new_execs, Decimal.new("0"), fn exec, acc -> Decimal.add(acc, exec.size) end)

    Bitflyer.OrderExecutor.DailyLossSync.around_fill(:live, fn ->
      case Bitflyer.Repo.transaction(fn ->
             Enum.reduce_while(new_execs, {order, []}, fn exec, {current, notifications} ->
               case apply_one_execution(current, info, exec) do
                 {:ok, updated, more} ->
                   {:cont, {updated, notifications ++ more}}

                 {:error, code, meta} when is_atom(code) and is_map(meta) ->
                   Bitflyer.Repo.rollback({code, meta})

                 other ->
                   Bitflyer.Repo.rollback(other)
               end
             end)
           end) do
        {:ok, {updated, notifications}} ->
          _ = Ash.Notifier.notify(notifications)
          _ = consume_live_hold(order, total_delta)

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

  defp apply_one_execution(%Order{} = order, info, exec) do
    exec_id = normalize_execution_id(exec.id)
    fill_price = exec.price
    size = exec.size
    filled_at = execution_filled_at(exec)

    new_filled = Decimal.add(order.filled_size || Decimal.new("0"), size)

    new_notional =
      Decimal.add(order.filled_notional || Decimal.new("0"), Decimal.mult(fill_price, size))

    status = status_after_fill(order.size, new_filled, info.status)
    delta_order = %{order | size: size, filled_size: size}

    with {:ok, updated, order_notifications} <-
           update_order(order, %{
             status: status,
             filled_size: new_filled,
             filled_notional: new_notional
           }),
         {:ok, position_notifications, _fill_meta} <-
           Positions.apply_fill(delta_order, fill_price,
             exchange_execution_id: exec_id,
             filled_at: filled_at,
             order_id: order.id
           ) do
      {:ok, updated, order_notifications ++ position_notifications}
    end
  end

  defp execution_filled_at(%{executed_at: %DateTime{} = dt}), do: dt
  defp execution_filled_at(_), do: DateTime.utc_now()

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
