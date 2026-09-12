defmodule Bitflyer.Observe.Exposure do
  @moduledoc """
  運用画面向け exposure スナップショット（建玉・未約定・当日損益・残高・halt 手順）。

  Status のポーリング向け。発注ホットパスではない。
  `Risk.Equity.snapshot/1` は `record_peak: false` で読む（HWM を更新しない）。
  `enforce/1` は呼ばない（表示だけで halt しない）。
  """

  require Ash.Query

  alias Bitflyer.Readiness
  alias Bitflyer.Risk.{BalanceCache, DailyLoss, Equity, HaltRecovery, Limits}
  alias Bitflyer.TradeMode
  alias Bitflyer.Trading.{Order, Position}

  @open_statuses [:pending, :partially_filled, :submission_unknown]
  @open_order_limit 20
  @balance_currencies ["JPY", "BTC"]

  @type position_row :: %{
          id: String.t(),
          product_code: String.t(),
          side: atom(),
          size: Decimal.t(),
          average_price: Decimal.t(),
          mark: Decimal.t() | nil,
          unrealized: Decimal.t() | nil
        }

  @type order_row :: %{
          id: String.t(),
          internal_order_id: String.t(),
          exchange_order_id: String.t() | nil,
          product_code: String.t(),
          side: atom(),
          status: atom(),
          order_type: atom(),
          price: Decimal.t() | nil,
          size: Decimal.t(),
          filled_size: Decimal.t(),
          remaining_size: Decimal.t(),
          age_ms: non_neg_integer()
        }

  @type balance_row :: %{
          id: String.t(),
          currency: String.t(),
          amount: Decimal.t() | nil
        }

  @type pnl :: %{
          status: :ok | :stale | :unsynced,
          realized_net: Decimal.t() | nil,
          realized_loss: Decimal.t() | nil,
          unrealized: Decimal.t() | nil,
          equity_pnl: Decimal.t() | nil,
          peak: Decimal.t() | nil,
          drawdown: Decimal.t() | nil,
          max_daily_loss: Decimal.t(),
          max_daily_drawdown: Decimal.t(),
          loss_headroom: Decimal.t() | nil,
          drawdown_headroom: Decimal.t() | nil
        }

  @type t :: %{
          trade_mode: TradeMode.t(),
          positions: [position_row()],
          positions_error: atom() | nil,
          open_orders: [order_row()],
          open_order_count: non_neg_integer(),
          oldest_open_age_ms: non_neg_integer() | nil,
          open_orders_error: atom() | nil,
          balances: [balance_row()],
          balances_error: atom() | nil,
          pnl: pnl(),
          halt_reason: atom() | nil,
          halt_steps: [atom()]
        }

  @doc """
  現時点の exposure。UI は描画のみ。ピーク更新も halt もしない。
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &TradeMode.current/0)
    readiness = Keyword.get(opts, :readiness, Readiness)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    limits = opts |> Keyword.get_lazy(:limits, &Limits.current/0) |> Limits.normalize()

    halt_reason =
      case readiness.get() do
        {:halted, reason} -> reason
        _ -> nil
      end

    {positions, positions_error} = load_positions(trade_mode)

    {open_orders, open_order_count, oldest_open_age_ms, open_orders_error} =
      load_open_orders(trade_mode, now)

    {balances, balances_error} = load_balances(trade_mode, opts)

    %{
      trade_mode: trade_mode,
      positions: Enum.map(positions, &position_row(&1, limits, opts)),
      positions_error: positions_error,
      open_orders: open_orders,
      open_order_count: open_order_count,
      oldest_open_age_ms: oldest_open_age_ms,
      open_orders_error: open_orders_error,
      balances: balances,
      balances_error: balances_error,
      pnl: build_pnl(trade_mode, positions, positions_error, limits, opts),
      halt_reason: halt_reason,
      halt_steps: HaltRecovery.steps(halt_reason)
    }
  end

  defp load_positions(trade_mode) do
    case Position
         |> Ash.Query.filter(trade_mode == ^trade_mode)
         |> Ash.Query.sort(product_code: :asc)
         |> Ash.read() do
      {:ok, positions} -> {positions, nil}
      {:error, _} -> {[], :load_failed}
    end
  rescue
    _ -> {[], :load_failed}
  catch
    :exit, _ -> {[], :load_failed}
  end

  defp load_open_orders(trade_mode, now) do
    base =
      Order
      |> Ash.Query.filter(trade_mode == ^trade_mode and status in ^@open_statuses)

    with {:ok, count} <- Ash.count(base),
         {:ok, orders} <-
           base
           |> Ash.Query.sort(inserted_at: :asc)
           |> Ash.Query.limit(@open_order_limit)
           |> Ash.read() do
      rows = Enum.map(orders, &order_row(&1, now))
      oldest = rows |> List.first() |> then(&(&1 && &1.age_ms))
      {rows, count, oldest, nil}
    else
      {:error, _} -> {[], 0, nil, :load_failed}
    end
  rescue
    _ -> {[], 0, nil, :load_failed}
  catch
    :exit, _ -> {[], 0, nil, :load_failed}
  end

  defp load_balances(trade_mode, opts) do
    balance_opts =
      case Keyword.fetch(opts, :balance_server) do
        {:ok, server} -> [server: server]
        :error -> []
      end

    case BalanceCache.get(trade_mode, balance_opts) do
      {:ok, map} -> {balance_rows(map), nil}
      {:error, :unsynced} -> {balance_rows(%{}), :unsynced}
    end
  rescue
    _ -> {balance_rows(%{}), :load_failed}
  catch
    :exit, _ -> {balance_rows(%{}), :load_failed}
  end

  defp balance_rows(map) do
    extras =
      map
      |> Map.keys()
      |> Enum.reject(&(&1 in @balance_currencies))
      |> Enum.sort()

    Enum.map(@balance_currencies ++ extras, fn currency ->
      %{
        id: "exposure-balance-#{currency}",
        currency: currency,
        amount: Map.get(map, currency)
      }
    end)
  end

  defp position_row(position, limits, opts) do
    mark_opts =
      opts
      |> Keyword.take([:now, :server, :limits])
      |> Keyword.put(:limits, limits)

    {mark, unrealized} =
      case Equity.mark_position(position, mark_opts) do
        {:ok, %{mark: ltp, unrealized: pnl}} -> {ltp, pnl}
        {:error, _, _} -> {nil, nil}
      end

    %{
      id: "exposure-position-#{position.product_code}",
      product_code: position.product_code,
      side: position.side,
      size: position.size,
      average_price: position.average_price,
      mark: mark,
      unrealized: unrealized
    }
  end

  defp order_row(order, now) do
    filled = order.filled_size || Decimal.new(0)

    %{
      id: "exposure-open-order-#{order.internal_order_id}",
      internal_order_id: order.internal_order_id,
      exchange_order_id: order.exchange_order_id,
      product_code: order.product_code,
      side: order.side,
      status: order.status,
      order_type: order.order_type,
      price: order.price,
      size: order.size,
      filled_size: filled,
      remaining_size: Decimal.sub(order.size, filled),
      age_ms: age_ms(order.inserted_at, now)
    }
  end

  defp age_ms(%DateTime{} = at, %DateTime{} = now) do
    max(DateTime.diff(now, at, :millisecond), 0)
  end

  defp age_ms(%NaiveDateTime{} = at, %DateTime{} = now) do
    at
    |> DateTime.from_naive!("Etc/UTC")
    |> age_ms(now)
  end

  defp age_ms(_, _), do: 0

  defp build_pnl(_trade_mode, _positions, :load_failed, limits, _opts) do
    empty_pnl(:unsynced, limits, %{})
  end

  defp build_pnl(trade_mode, positions, _positions_error, limits, opts) do
    equity_opts =
      opts
      |> Keyword.take([:now, :now_dt, :server, :daily_loss_server, :limits])
      |> Keyword.put(:trade_mode, trade_mode)
      |> Keyword.put(:positions, positions)
      |> Keyword.put(:record_peak, false)

    daily = daily_fields(trade_mode, opts)

    case Equity.snapshot(equity_opts) do
      {:ok, snap} ->
        empty_pnl(:ok, limits, daily)
        |> Map.merge(%{
          realized_net: snap.realized_net,
          unrealized: snap.unrealized,
          equity_pnl: snap.equity_pnl,
          peak: snap.peak,
          drawdown: snap.drawdown,
          drawdown_headroom: Decimal.sub(limits.max_daily_drawdown, snap.drawdown)
        })

      {:error, :stale, _} ->
        empty_pnl(:stale, limits, daily)

      {:error, :unsynced, _} ->
        empty_pnl(:unsynced, limits, daily)
    end
  end

  defp daily_fields(trade_mode, opts) do
    daily_opts =
      case Keyword.fetch(opts, :daily_loss_server) do
        {:ok, server} -> [server: server]
        :error -> []
      end
      |> Keyword.merge(Keyword.take(opts, [:now_dt]))

    case DailyLoss.snapshot(trade_mode, daily_opts) do
      {:ok, %{loss: loss, net: net, peak: peak}} ->
        %{realized_loss: loss, realized_net: net, peak: peak}

      {:error, :unsynced} ->
        %{}
    end
  end

  defp empty_pnl(status, limits, daily) do
    realized_loss = Map.get(daily, :realized_loss)

    %{
      status: status,
      realized_net: Map.get(daily, :realized_net),
      realized_loss: realized_loss,
      unrealized: nil,
      equity_pnl: nil,
      peak: Map.get(daily, :peak),
      drawdown: nil,
      max_daily_loss: limits.max_daily_loss,
      max_daily_drawdown: limits.max_daily_drawdown,
      loss_headroom:
        if(realized_loss, do: Decimal.sub(limits.max_daily_loss, realized_loss), else: nil),
      drawdown_headroom: nil
    }
  end
end
