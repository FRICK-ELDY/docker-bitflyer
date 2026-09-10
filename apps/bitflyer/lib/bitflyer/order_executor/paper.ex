defmodule Bitflyer.OrderExecutor.Paper do
  @moduledoc false

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor.Paper.FillPricing
  alias Bitflyer.OrderExecutor.{Balances, Positions}
  alias Bitflyer.Trading.Order

  @doc """
  取引所 REST を呼ばず、キャッシュ価格で擬似約定し建玉・残高を更新する。

  - market: LTP を基準に不利方向へ slippage / fee（bps）を加味して即時全量約定
  - limit: LTP が指値に交差したときだけ、指値に **fee のみ** を加味して約定（未交差は pending）
    （スリッページは掛けない。指値より悪い約定価格を避ける）

  注文・建玉・残高の更新は同一トランザクションで行い、片側だけ成功しないようにする。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, command, opts) do
    with {:ok, decision} <- decide_fill(order, command, opts) do
      case decision do
        :leave_pending ->
          {:ok, order}

        {:fill, fill_price} ->
          apply_fill_transaction(order, fill_price)
      end
    end
  end

  defp apply_fill_transaction(%Order{} = order, fill_price) do
    Bitflyer.OrderExecutor.DailyLossSync.around_fill(:paper, fn ->
      Bitflyer.OrderExecutor.BalanceCacheSync.around_fill(:paper, fn ->
        case Bitflyer.Repo.transaction(fn ->
               with {:ok, filled_order, order_notifications} <- mark_filled(order, fill_price),
                    {:ok, position_notifications, _fill_meta} <-
                      Positions.apply_fill(filled_order, fill_price),
                    {:ok, balance_notifications} <- Balances.apply_fill(filled_order, fill_price) do
                 {filled_order,
                  order_notifications ++ position_notifications ++ balance_notifications}
               else
                 {:error, code, meta} when is_atom(code) and is_map(meta) ->
                   Bitflyer.Repo.rollback({code, meta})

                 other ->
                   Bitflyer.Repo.rollback(other)
               end
             end) do
          {:ok, {filled_order, notifications}} ->
            _ = Ash.Notifier.notify(notifications)
            _ = Bitflyer.Risk.BalanceCache.discard_hold(:paper, filled_order.internal_order_id)

            Bitflyer.Telemetry.execute(
              :order_filled,
              %{count: 1},
              %{
                internal_order_id: filled_order.internal_order_id,
                exchange_order_id: filled_order.exchange_order_id,
                product_code: filled_order.product_code,
                side: filled_order.side,
                trade_mode: :paper,
                status: :filled
              }
            )

            {:ok, filled_order}

          {:error, {code, meta}} when is_atom(code) and is_map(meta) ->
            {:error, code, meta}

          {:error, error} ->
            {:error, :persist_failed, %{error: error}}
        end
      end)
    end)
  end

  defp decide_fill(%Order{order_type: :market, side: side} = _order, command, opts) do
    with {:ok, ltp} <- fetch_ltp(command, opts),
         {:ok, fill_price} <- FillPricing.effective_price(side, ltp, pricing_opts(opts)) do
      {:ok, {:fill, fill_price}}
    end
  end

  defp decide_fill(
         %Order{order_type: :limit, price: %Decimal{} = price, side: side},
         command,
         opts
       ) do
    with {:ok, ltp} <- fetch_ltp(command, opts) do
      if limit_crossed?(side, price, ltp) do
        case FillPricing.limit_fill_price(side, price, pricing_opts(opts)) do
          {:ok, fill_price} -> {:ok, {:fill, fill_price}}
          {:error, _, _} = error -> error
        end
      else
        {:ok, :leave_pending}
      end
    end
  end

  defp decide_fill(%Order{}, _command, _opts) do
    {:error, :invalid_command, %{field: :price}}
  end

  defp pricing_opts(opts) do
    Keyword.take(opts, [:slippage_bps, :fee_bps])
  end

  defp limit_crossed?(:buy, limit_price, ltp) do
    Decimal.compare(ltp, limit_price) != :gt
  end

  defp limit_crossed?(:sell, limit_price, ltp) do
    Decimal.compare(ltp, limit_price) != :lt
  end

  defp fetch_ltp(command, opts) do
    case Map.fetch(command, :market_key) do
      {:ok, key} ->
        server = Keyword.get(opts, :server, Cache)

        case Cache.get(key, server) do
          {:ok, value, _received_at} ->
            case extract_ltp(value) do
              {:ok, ltp} -> {:ok, ltp}
              :error -> {:error, :fill_price_unavailable, %{market_key: key}}
            end

          :miss ->
            {:error, :fill_price_unavailable, %{market_key: key}}
        end

      :error ->
        {:error, :invalid_command, %{field: :market_key}}
    end
  end

  defp extract_ltp(%{ltp: ltp}), do: cast_ltp(ltp)
  defp extract_ltp(%{"ltp" => ltp}), do: cast_ltp(ltp)
  defp extract_ltp(_), do: :error

  defp cast_ltp(%Decimal{} = ltp) do
    if Decimal.positive?(ltp), do: {:ok, ltp}, else: :error
  end

  defp cast_ltp(ltp) when is_binary(ltp) do
    case Decimal.parse(ltp) do
      {decimal, ""} -> cast_ltp(decimal)
      _ -> :error
    end
  end

  defp cast_ltp(ltp) when is_integer(ltp), do: cast_ltp(Decimal.new(ltp))
  defp cast_ltp(ltp) when is_float(ltp), do: cast_ltp(Decimal.from_float(ltp))
  defp cast_ltp(_), do: :error

  defp mark_filled(%Order{} = order, fill_price) do
    attrs = %{
      status: :filled,
      filled_size: order.size,
      # paper は Fill/建玉と同じ不利化後価格を Order にも残す
      price: fill_price,
      exchange_order_id: order.exchange_order_id || "paper:#{order.internal_order_id}"
    }

    case order
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(return_notifications?: true) do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end
end
