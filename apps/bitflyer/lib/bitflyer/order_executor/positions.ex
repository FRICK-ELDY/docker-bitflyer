defmodule Bitflyer.OrderExecutor.Positions do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{Order, Position}

  @doc """
  擬似約定を建玉へ反映する（paper 用）。

  トランザクション内では `return_notifications?: true` で通知を返し、
  呼び出し側がコミット後に `Ash.Notifier.notify/1` する。
  """
  @spec apply_fill(Order.t(), Decimal.t()) :: {:ok, list()} | {:error, atom(), map()}
  def apply_fill(%Order{} = order, %Decimal{} = fill_price) do
    trade_mode = order.trade_mode
    product_code = order.product_code
    side = order.side
    size = order.size

    case find_position(product_code, trade_mode) do
      {:ok, nil} ->
        create_position(product_code, trade_mode, side, size, fill_price)

      {:ok, %Position{} = position} ->
        merge_position(position, side, size, fill_price)

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp find_position(product_code, trade_mode) do
    Position
    |> Ash.Query.filter(product_code == ^product_code and trade_mode == ^trade_mode)
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
      {:ok, _, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp merge_position(%Position{} = position, side, size, fill_price) do
    cond do
      position.side == side ->
        new_size = Decimal.add(position.size, size)

        new_avg =
          position.size
          |> Decimal.mult(position.average_price)
          |> Decimal.add(Decimal.mult(size, fill_price))
          |> Decimal.div(new_size)

        update_position(position, %{size: new_size, average_price: new_avg})

      Decimal.compare(size, position.size) == :lt ->
        new_size = Decimal.sub(position.size, size)
        update_position(position, %{size: new_size})

      Decimal.equal?(size, position.size) ->
        case Ash.destroy(position, return_notifications?: true) do
          :ok -> {:ok, []}
          {:ok, _, notifications} -> {:ok, notifications}
          {:ok, _} -> {:ok, []}
          {:error, error} -> {:error, :persist_failed, %{error: error}}
        end

      true ->
        remainder = Decimal.sub(size, position.size)

        update_position(position, %{
          side: side,
          size: remainder,
          average_price: fill_price
        })
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
end
