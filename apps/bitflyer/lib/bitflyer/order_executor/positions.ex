defmodule Bitflyer.OrderExecutor.Positions do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{Fill, Order, Position}

  @doc """
  約定を建玉へ反映し、Fill 行を同一トランザクション内に残す。

  戻り値の第 3 要素はコミット後に `Risk.DailyLoss.record_realized/2` へ渡す。
  既存建玉は `FOR UPDATE` でロックし、Lost Update を防ぐ。
  """
  @spec apply_fill(Order.t(), Decimal.t()) ::
          {:ok, list(), %{realized_pnl: Decimal.t()}} | {:error, atom(), map()}
  def apply_fill(%Order{} = order, %Decimal{} = fill_price) do
    trade_mode = order.trade_mode
    product_code = order.product_code
    side = order.side
    size = order.size

    case find_position(product_code, trade_mode) do
      {:ok, nil} ->
        case create_position(product_code, trade_mode, side, size, fill_price) do
          {:ok, notifications} ->
            with {:ok, fill_notifications} <-
                   insert_fill(order, fill_price, size, Decimal.new(0)) do
              {:ok, notifications ++ fill_notifications, %{realized_pnl: Decimal.new(0)}}
            end

          {:race, %Position{} = position} ->
            merge_position(position, order, side, size, fill_price)

          {:error, _, _} = error ->
            error
        end

      {:ok, %Position{} = position} ->
        merge_position(position, order, side, size, fill_price)

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp find_position(product_code, trade_mode) do
    Position
    |> Ash.Query.filter(product_code == ^product_code and trade_mode == ^trade_mode)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  defp create_position(product_code, trade_mode, side, size, fill_price) do
    case Position
         |> Ash.Changeset.for_create(:create, %{
           product_code: product_code,
           trade_mode: trade_mode,
           side: side,
           size: size,
           average_price: fill_price
         })
         |> Ash.create(return_notifications?: true) do
      {:ok, _, notifications} ->
        {:ok, notifications}

      {:error, error} ->
        case find_position(product_code, trade_mode) do
          {:ok, %Position{} = position} ->
            {:race, position}

          _ ->
            {:error, :persist_failed, %{error: error}}
        end
    end
  end

  defp merge_position(%Position{} = position, %Order{} = order, side, size, fill_price) do
    cond do
      position.side == side ->
        new_size = Decimal.add(position.size, size)

        new_avg =
          position.size
          |> Decimal.mult(position.average_price)
          |> Decimal.add(Decimal.mult(size, fill_price))
          |> Decimal.div(new_size)

        with {:ok, notifications} <-
               update_position(position, %{size: new_size, average_price: new_avg}),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, size, Decimal.new(0)) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: Decimal.new(0)}}
        end

      Decimal.compare(size, position.size) == :lt ->
        closed = size
        realized = realized_pnl(position.side, position.average_price, fill_price, closed)
        new_size = Decimal.sub(position.size, size)

        with {:ok, notifications} <- update_position(position, %{size: new_size}),
             {:ok, fill_notifications} <- insert_fill(order, fill_price, size, realized) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      Decimal.equal?(size, position.size) ->
        closed = position.size
        realized = realized_pnl(position.side, position.average_price, fill_price, closed)

        with {:ok, notifications} <- destroy_position(position),
             {:ok, fill_notifications} <- insert_fill(order, fill_price, size, realized) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      true ->
        closed = position.size
        realized = realized_pnl(position.side, position.average_price, fill_price, closed)
        remainder = Decimal.sub(size, position.size)

        with {:ok, notifications} <-
               update_position(position, %{
                 side: side,
                 size: remainder,
                 average_price: fill_price
               }),
             {:ok, fill_notifications} <- insert_fill(order, fill_price, size, realized) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end
    end
  end

  defp destroy_position(%Position{} = position) do
    case Ash.destroy(position, return_notifications?: true) do
      :ok -> {:ok, []}
      {:ok, notifications} when is_list(notifications) -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp update_position(%Position{} = position, attrs) do
    case position
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(return_notifications?: true) do
      {:ok, _, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp realized_pnl(:buy, avg_price, fill_price, closed_size) do
    fill_price
    |> Decimal.sub(avg_price)
    |> Decimal.mult(closed_size)
  end

  defp realized_pnl(:sell, avg_price, fill_price, closed_size) do
    avg_price
    |> Decimal.sub(fill_price)
    |> Decimal.mult(closed_size)
  end

  defp insert_fill(%Order{} = order, fill_price, size, realized_pnl) do
    attrs = %{
      internal_order_id: order.internal_order_id,
      exchange_execution_id: nil,
      product_code: order.product_code,
      side: order.side,
      size: size,
      price: fill_price,
      realized_pnl: realized_pnl,
      trade_mode: order.trade_mode,
      filled_at: DateTime.utc_now()
    }

    case Fill
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(return_notifications?: true) do
      {:ok, _, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end
end
