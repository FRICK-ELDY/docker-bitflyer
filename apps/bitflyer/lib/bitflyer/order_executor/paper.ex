defmodule Bitflyer.OrderExecutor.Paper do
  @moduledoc false

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Trading.Order

  @doc """
  取引所 REST を呼ばず、キャッシュ価格で即時擬似約定し建玉を更新する。

  注文の filled 更新と建玉反映は同一トランザクションで行い、片側だけ成功しないようにする。
  """
  @spec execute(Order.t(), map(), keyword()) :: {:ok, Order.t()} | {:error, atom(), map()}
  def execute(%Order{} = order, command, opts) do
    with {:ok, fill_price} <- fill_price(order, command, opts) do
      case Bitflyer.Repo.transaction(fn ->
             with {:ok, filled_order, order_notifications} <- mark_filled(order, fill_price),
                  {:ok, position_notifications} <- Positions.apply_fill(filled_order, fill_price) do
               {filled_order, order_notifications ++ position_notifications}
             else
               {:error, code, meta} when is_atom(code) and is_map(meta) ->
                 Bitflyer.Repo.rollback({code, meta})

               other ->
                 Bitflyer.Repo.rollback(other)
             end
           end) do
        {:ok, {filled_order, notifications}} ->
          _ = Ash.Notifier.notify(notifications)

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
    end
  end

  defp fill_price(%Order{order_type: :limit, price: %Decimal{} = price}, _command, _opts) do
    {:ok, price}
  end

  defp fill_price(%Order{order_type: :market}, command, opts) do
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

  defp fill_price(%Order{}, _command, _opts) do
    {:error, :invalid_command, %{field: :price}}
  end

  defp extract_ltp(%{ltp: ltp}), do: cast_ltp(ltp)
  defp extract_ltp(%{"ltp" => ltp}), do: cast_ltp(ltp)
  defp extract_ltp(_), do: :error

  defp cast_ltp(%Decimal{} = ltp), do: {:ok, ltp}
  defp cast_ltp(ltp) when is_binary(ltp), do: {:ok, Decimal.new(ltp)}
  defp cast_ltp(ltp) when is_integer(ltp), do: {:ok, Decimal.new(ltp)}
  defp cast_ltp(ltp) when is_float(ltp), do: {:ok, Decimal.from_float(ltp)}
  defp cast_ltp(_), do: :error

  defp mark_filled(%Order{} = order, fill_price) do
    attrs = %{
      status: :filled,
      filled_size: order.size,
      # limit は指値を維持。market は約定価格を残す
      price: order.price || fill_price,
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
