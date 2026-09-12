defmodule Bitflyer.OrderExecutor do
  @moduledoc """
  order-executor の公開境界。

  `Risk.AuthorizedOrder`（`Risk.authorize/2` 成功時のみ）だけを受け、取引モード別の出口へ送る。
  raw command map では呼べない（型で境界を強制する）。
  冪等キーは `internal_order_id`（Order の unique）。
  停止時は `InFlight` で進行中 submit/cancel を追跡し、`prep_stop` が完了を待つ。

  - `dry_run` — 送らず記録のみ（建玉は動かさない）
  - `paper` — 擬似約定 → datastore（取引所 REST は呼ばない）
  - `live` — `exchange_order_gate` 通過時のみ REST

  取消は `cancel/2`。live のみ取引所 REST を呼ぶ。
  """

  require Ash.Query

  alias Bitflyer.OrderExecutor.{DryRun, InFlight, Live, Paper}
  alias Bitflyer.Risk
  alias Bitflyer.Risk.AuthorizedOrder
  alias Bitflyer.TradeMode
  alias Bitflyer.Trading.Order

  @type result ::
          {:ok, Order.t()}
          | {:ok, Order.t(), :idempotent}
          | {:error, atom(), map()}

  @doc """
  live submit 前の未反映約定同期。`System.submit_order/2` が認可前に呼ぶ。

  失敗時は当該 submit のみ拒否する（circuit は開けない）。未発注のため
  post-place の `:fill_sync_failed`（受注済み → halt）とは意図的に非対称。
  """
  @spec sync_live_fills_before_authorize(atom(), keyword()) :: :ok | {:error, atom(), map()}
  def sync_live_fills_before_authorize(trade_mode, opts \\ []) do
    maybe_sync_live_fills(trade_mode, opts)
  end

  @cancellable_statuses [:pending, :partially_filled]

  @doc """
  認可済み注文を実行する。既存 `internal_order_id` があれば再送しない。

  `AuthorizedOrder.consume/1` で Risk 発行トークンをワンショット検証する（偽造・再利用不可）。
  InFlight 閉鎖後は consume 後に予約を `OrderRate.release` してから `:shutting_down` を返す
  （トークンは take 済みのため purge に頼れない）。
  live の open-order 同期は `System.submit_order/2` の認可前のみ（ここでは再同期しない）。
  認可検査自体は呼び出し側（通常は `System.submit_order/2`）で済んでいる前提。

  ## Options
  - Risk.authorize/2 と同じオプションのうち出口・同期用（`:positions` は認可時に使用済み）
  - `:trade_mode` — 出口上書き（既定は `TradeMode.current/0`）
  - `:authorized_order_server` — 認可トークン GenServer（Cache の `:server` とは別）
  - `:persist_exchange_order_id` — live のみ。受注 ID 永続化の差し替え（テスト用）
  - `:exchange` — live fill 同期先（テスト用）
  """
  @spec submit(AuthorizedOrder.t(), keyword()) :: result()
  def submit(%AuthorizedOrder{} = authorized, opts \\ []) do
    # consume を先に行う。ゲート閉鎖との競合で track が :closed でも、
    # トークンは take 済みなのでここで OrderRate 予約を必ず release する。
    with {:ok, command} <- AuthorizedOrder.consume(authorized, opts) do
      reservation = Map.get(command, AuthorizedOrder.reservation_key())

      case enter_submit(command, reservation) do
        {:ok, ref} ->
          try do
            do_submit(command, opts)
          after
            InFlight.untrack(ref)
          end

        {:error, _, _} = error ->
          error
      end
    end
  end

  defp enter_submit(command, reservation) do
    meta = %{
      kind: :submit,
      internal_order_id:
        Map.get(command, :internal_order_id) || Map.get(command, "internal_order_id")
    }

    cond do
      InFlight.closed?() ->
        _ = Bitflyer.Risk.OrderRate.release(reservation)
        {:error, :shutting_down, %{reason: :inflight_closed}}

      true ->
        case InFlight.track(meta) do
          {:ok, ref} ->
            {:ok, ref}

          {:error, :closed} ->
            _ = Bitflyer.Risk.OrderRate.release(reservation)
            {:error, :shutting_down, %{reason: :inflight_closed}}
        end
    end
  end

  defp do_submit(command, opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &TradeMode.current/0)
    reservation = Map.get(command, AuthorizedOrder.reservation_key())

    with :ok <- early_submit_gates(command, trade_mode, opts, reservation),
         {:new, command} <- idempotent_lookup_releasing(command, reservation),
         {:ok, hold} <- reserve_balance_releasing(trade_mode, command, opts, reservation),
         {:ok, order} <- create_pending_releasing(command, trade_mode, hold),
         {:ok, order} <- dispatch_releasing(order, command, trade_mode, opts, hold) do
      emit_submitted(order)
      {:ok, order}
    else
      {:idempotent, %Order{} = order} ->
        {:ok, order, :idempotent}

      other ->
        other
    end
  end

  defp early_submit_gates(command, _trade_mode, _opts, reservation) do
    case validate_command(command) do
      :ok ->
        :ok

      {:error, _, _} = error ->
        _ = Bitflyer.Risk.OrderRate.release(reservation)
        error
    end
  end

  @doc """
  未約定（または部分約定）注文を取消する。

  - `dry_run` / `paper` — 内部 status のみ `cancelled`（REST なし）
  - `live` — `Exchange.cancel_order/1` のあと fill 同期して終端化。
    発注ゲート（halt）中でもエクスポージャ削減のため取消 REST は許可する。

  出口は注文自身の `trade_mode` に固定する（opts で上書きしない）。
  """
  @spec cancel(String.t() | Order.t(), keyword()) :: result()
  def cancel(internal_order_id_or_order, opts \\ [])

  def cancel(internal_order_id, opts) when is_binary(internal_order_id) do
    case fetch_order(internal_order_id) do
      {:ok, %Order{} = order} -> cancel(order, opts)
      {:ok, nil} -> {:error, :not_found, %{internal_order_id: internal_order_id}}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  def cancel(%Order{} = order, opts) do
    meta = %{kind: :cancel, internal_order_id: order.internal_order_id}

    case InFlight.track(meta) do
      {:ok, ref} ->
        try do
          do_cancel(order, opts)
        after
          InFlight.untrack(ref)
        end

      {:error, :closed} ->
        {:error, :shutting_down, %{reason: :inflight_closed}}
    end
  end

  @doc """
  ポリシーに従い未約定注文を逐次取消する（halt cancel-all / open age）。

  ## Options
  - `:trade_modes` — 既定 `[:live]`
  - `:older_than` — `%DateTime{}` のとき `inserted_at` 以前のみ
  - `:exchange` — live cancel へ転送
  - `:cause` / `:halt_reason` — ログ用
  """
  @spec cancel_open_orders(keyword()) :: {:ok, [{String.t(), result()}]} | {:error, atom(), map()}
  def cancel_open_orders(opts \\ []) do
    case Risk.OpenOrderPolicy.list_open_orders(opts) do
      {:ok, orders} ->
        cause = Keyword.get(opts, :cause)
        halt_reason = Keyword.get(opts, :halt_reason)

        Bitflyer.Telemetry.log(
          :info,
          "cancel_open_orders starting",
          %{
            count: length(orders),
            cause: cause,
            halt_reason: halt_reason,
            trade_mode: TradeMode.current()
          }
        )

        cancel_opts = Keyword.take(opts, [:exchange])

        results =
          Enum.map(orders, fn order ->
            {order.internal_order_id, cancel(order, cancel_opts)}
          end)

        failed =
          Enum.count(results, fn
            {_, {:ok, _}} -> false
            {_, {:ok, _, :idempotent}} -> false
            _ -> true
          end)

        if failed > 0 do
          Bitflyer.Telemetry.log(
            :warning,
            "cancel_open_orders completed with failures",
            %{failed: failed, total: length(results), cause: cause, halt_reason: halt_reason}
          )
        end

        {:ok, results}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp do_cancel(%Order{} = order, opts) do
    # opts の :trade_mode は無視。live 注文を dry_run 取消にして取引所に残骸を残さない。
    trade_mode = order.trade_mode

    cond do
      order.status not in @cancellable_statuses ->
        {:error, :not_cancellable, %{status: order.status}}

      trade_mode == :live ->
        case Live.Cancel.execute(order, opts) do
          {:ok, updated} = ok ->
            _ = maybe_settle_live_hold(updated)
            ok

          other ->
            other
        end

      trade_mode in [:dry_run, :paper] ->
        case cancel_local(order) do
          {:ok, updated} = ok ->
            _ = settle_cancelled_hold(updated)
            ok

          other ->
            other
        end

      true ->
        {:error, :invalid_trade_mode, %{trade_mode: trade_mode}}
    end
  end

  defp maybe_sync_live_fills(:live, opts) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    case Bitflyer.OrderExecutor.LiveFills.sync_open_orders(exchange: exchange) do
      :ok ->
        :ok

      {:error, reason, meta} ->
        Bitflyer.Telemetry.log(
          :error,
          "live fill sync before authorize failed: #{inspect(reason)}",
          Map.merge(%{trade_mode: :live}, meta || %{})
        )

        {:error, :fill_sync_failed, Map.put(meta || %{}, :reason, reason)}
    end
  end

  defp maybe_sync_live_fills(_mode, _opts), do: :ok

  defp cancel_local(%Order{} = order) do
    case order
         |> Ash.Changeset.for_update(:update, %{status: :cancelled})
         |> Ash.update() do
      {:ok, updated} ->
        Bitflyer.Telemetry.log(
          :info,
          "#{order.trade_mode} order cancelled (local)",
          %{
            internal_order_id: order.internal_order_id,
            product_code: order.product_code,
            trade_mode: order.trade_mode,
            status: :cancelled
          }
        )

        {:ok, updated}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp validate_command(command) do
    id = Map.get(command, :internal_order_id)
    product_code = Map.get(command, :product_code)
    side = Map.get(command, :side)
    size = Map.get(command, :size)
    order_type = Map.get(command, :order_type, :market)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :invalid_command, %{field: :internal_order_id}}

      not is_binary(product_code) or product_code == "" ->
        {:error, :invalid_command, %{field: :product_code}}

      side not in [:buy, :sell] ->
        {:error, :invalid_command, %{field: :side}}

      not match?(%Decimal{}, size) or not Decimal.positive?(size) ->
        {:error, :invalid_command, %{field: :size}}

      order_type not in [:limit, :market] ->
        {:error, :invalid_command, %{field: :order_type}}

      order_type == :limit and not valid_limit_price?(Map.get(command, :price)) ->
        {:error, :invalid_command, %{field: :price}}

      true ->
        :ok
    end
  end

  defp valid_limit_price?(%Decimal{} = price), do: Decimal.positive?(price)
  defp valid_limit_price?(_), do: false

  defp idempotent_lookup(command) do
    id = Map.fetch!(command, :internal_order_id)

    case fetch_order(id) do
      {:ok, %Order{} = order} -> {:idempotent, order}
      {:ok, nil} -> {:new, command}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp idempotent_lookup_releasing(command, reservation) do
    case idempotent_lookup(command) do
      {:idempotent, order} ->
        _ = Bitflyer.Risk.OrderRate.release(reservation)
        {:idempotent, order}

      {:error, _, _} = error ->
        _ = Bitflyer.Risk.OrderRate.release(reservation)
        error

      other ->
        other
    end
  end

  defp create_pending(command, trade_mode) do
    order_type = Map.get(command, :order_type, :market)
    reservation = Map.get(command, AuthorizedOrder.reservation_key())

    attrs =
      %{
        internal_order_id: Map.fetch!(command, :internal_order_id),
        product_code: Map.fetch!(command, :product_code),
        side: Map.fetch!(command, :side),
        size: Map.fetch!(command, :size),
        order_type: order_type,
        price: Map.get(command, :price),
        status: :pending,
        trade_mode: trade_mode
      }
      |> maybe_put_attr(
        :strategy_parameter_revision_id,
        Map.get(command, :strategy_parameter_revision_id)
      )
      |> maybe_put_attr(:strategy_module, Map.get(command, :strategy_module))
      |> maybe_put_attr(:command_hash, Map.get(command, :command_hash))

    case Order |> Ash.Changeset.for_create(:create, attrs) |> Ash.create() do
      {:ok, order} ->
        _ = Bitflyer.Risk.OrderRate.commit(reservation)
        {:ok, order}

      {:error, error} ->
        # 競合時は既存行を返す（二重 REST を防ぐ）
        case fetch_order(attrs.internal_order_id) do
          {:ok, %Order{} = order} ->
            _ = Bitflyer.Risk.OrderRate.release(reservation)
            {:idempotent, order}

          _ ->
            _ = Bitflyer.Risk.OrderRate.release(reservation)
            {:error, :persist_failed, %{error: error}}
        end
    end
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp create_pending_releasing(command, trade_mode, hold) do
    case create_pending(command, trade_mode) do
      {:ok, order} ->
        {:ok, order}

      {:idempotent, order} ->
        _ = release_hold(trade_mode, hold)
        {:idempotent, order}

      {:error, _, _} = error ->
        _ = release_hold(trade_mode, hold)
        error
    end
  end

  defp dispatch(order, command, :dry_run, opts), do: DryRun.execute(order, command, opts)
  defp dispatch(order, command, :paper, opts), do: Paper.execute(order, command, opts)
  defp dispatch(order, command, :live, opts), do: Live.execute(order, command, opts)

  defp dispatch_releasing(order, command, trade_mode, opts, hold) do
    case dispatch(order, command, trade_mode, opts) do
      {:ok, _updated} = ok ->
        # paper 即時 fill は BalanceCacheSync が Snapshot で上書き。
        # live 成功は予約を残し、突合 put / 取消 release まで拘束する。
        ok

      {:error, :exchange_halted, _} = error ->
        _ = release_hold(trade_mode, hold)
        error

      {:error, :exchange_error, _} = error ->
        _ = release_hold(trade_mode, hold)
        error

      {:error, _, _} = error ->
        # submission_unknown / persist_failed / fill_sync_failed(order_accepted) 等:
        # 取引所側に拘束の可能性 → 残高 hold は残す（失敗＝注文なしと誤解しないこと）
        error
    end
  end

  defp reserve_balance(trade_mode, command, opts) do
    case Risk.balance_hold(command, Keyword.put(opts, :trade_mode, trade_mode)) do
      {:ok, :skip} ->
        {:ok, :skip}

      {:ok, %{currency: currency, amount: amount}} ->
        hold_id = Map.fetch!(command, :internal_order_id)

        case Bitflyer.Risk.BalanceCache.reserve(trade_mode, currency, amount, hold_id: hold_id) do
          :ok ->
            {:ok, %{hold_id: hold_id}}

          {:error, :unsynced} ->
            {:error, :unsynced, %{reason: :balance_unsynced}}

          {:error, :hold_exists} ->
            {:error, :unsynced, %{reason: :balance_hold_exists}}

          {:error, :insufficient_balance, meta} ->
            {:error, :limit_exceeded, Map.put(meta, :limit, :insufficient_balance)}
        end

      {:error, _, _} = error ->
        error
    end
  end

  defp reserve_balance_releasing(trade_mode, command, opts, reservation) do
    case reserve_balance(trade_mode, command, opts) do
      {:ok, hold} ->
        {:ok, hold}

      {:error, _, _} = error ->
        _ = Bitflyer.Risk.OrderRate.release(reservation)
        error
    end
  end

  defp release_hold(_trade_mode, :skip), do: :ok

  defp release_hold(trade_mode, %{hold_id: hold_id}) when is_binary(hold_id) do
    Bitflyer.Risk.BalanceCache.release_hold(trade_mode, hold_id)
  end

  # live: 未終端の cancel 受付では hold を残す（遅延約定の consume 余地を残す）
  defp maybe_settle_live_hold(%Order{status: status} = order)
       when status in [:cancelled, :expired, :rejected] do
    settle_cancelled_hold(order)
  end

  defp maybe_settle_live_hold(%Order{status: :filled} = order) do
    Bitflyer.Risk.BalanceCache.discard_hold(order.trade_mode, order.internal_order_id)
  end

  defp maybe_settle_live_hold(%Order{}), do: :ok

  defp settle_cancelled_hold(%Order{trade_mode: :dry_run}), do: :ok

  defp settle_cancelled_hold(%Order{} = order) do
    filled = order.filled_size || Decimal.new(0)

    _ =
      Bitflyer.Risk.BalanceCache.align_hold_to_filled(
        order.trade_mode,
        order.internal_order_id,
        filled,
        order.size
      )

    Bitflyer.Risk.BalanceCache.release_hold(order.trade_mode, order.internal_order_id)
  end

  defp fetch_order(internal_order_id) do
    Order
    |> Ash.Query.filter(internal_order_id == ^internal_order_id)
    |> Ash.read_one()
  end

  defp emit_submitted(%Order{} = order) do
    Bitflyer.Telemetry.execute(
      :order_submitted,
      %{count: 1},
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        product_code: order.product_code,
        side: order.side,
        trade_mode: order.trade_mode,
        status: order.status
      }
    )
  end
end
