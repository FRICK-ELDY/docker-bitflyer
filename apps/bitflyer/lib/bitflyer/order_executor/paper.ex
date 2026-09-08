defmodule Bitflyer.OrderExecutor.Paper do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Trading.Order

  @doc """
  取引所 REST を呼ばず、キャッシュ価格で即時擬似約定し建玉を更新する。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, command, opts) do
    with {:ok, fill_price} <- fill_price(order, command, opts),
         {:ok, order} <- mark_filled(order, fill_price),
         :ok <- Positions.apply_fill(order, fill_price) do
      Bitflyer.Telemetry.execute(
        :order_filled,
        %{count: 1},
        %{
          internal_order_id: order.internal_order_id,
          exchange_order_id: order.exchange_order_id,
          product_code: order.product_code,
          side: order.side,
          trade_mode: :paper,
          status: :filled
        }
      )

      {:ok, order}
    end
  end

  defp fill_price(%Order{order_type: :limit, price: %Decimal{} = price}, _command, _opts) do
    {:ok, price}
  end

  defp fill_price(%Order{order_type: :market}, command, opts) do
    key = Map.fetch!(command, :market_key)
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
  end

  defp fill_price(%Order{}, _command, _opts) do
    {:error, :invalid_command, %{field: :price}}
  end

  defp extract_ltp(%{ltp: %Decimal{} = ltp}), do: {:ok, ltp}

  defp extract_ltp(%{ltp: ltp}) when is_binary(ltp) or is_integer(ltp),
    do: {:ok, Decimal.new(ltp)}

  defp extract_ltp(%{"ltp" => %Decimal{} = ltp}), do: {:ok, ltp}

  defp extract_ltp(%{"ltp" => ltp}) when is_binary(ltp) or is_integer(ltp),
    do: {:ok, Decimal.new(ltp)}

  defp extract_ltp(_), do: :error

  defp mark_filled(%Order{} = order, _fill_price) do
    attrs = %{
      status: :filled,
      filled_size: order.size,
      exchange_order_id: order.exchange_order_id || "paper:#{order.internal_order_id}"
    }

    case order |> Ash.Changeset.for_update(:update, attrs) |> Ash.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end
end
