defmodule Bitflyer.Trading.SpotInventory do
  @moduledoc """
  live spot の在庫不変条件。

  売れるのは買い `Position.size` から未約定売りを引いた分まで。
  ベースラインに乗っているだけの通貨（Position なし）は売らない
  （平均単価が無く、約定すると売建玉＝内部 short になる）。
  認可（`Risk`）と突合（`LiveInventory`）が同じ集計を使う。
  """

  alias Bitflyer.Trading.Product

  @doc """
  通貨ごとの買い建玉。FX と売り建玉は含めない。
  """
  @spec buy_claimed([map()]) :: %{optional(String.t()) => Decimal.t()}
  def buy_claimed(positions) when is_list(positions) do
    Enum.reduce(positions, %{}, fn position, acc ->
      code = Map.get(position, :product_code)
      size = Map.get(position, :size)

      if spot_buy?(code, Map.get(position, :side), size) do
        currency = Product.base_currency(code)
        Map.update(acc, currency, size, &Decimal.add(&1, size))
      else
        acc
      end
    end)
  end

  @doc """
  通貨ごとの未約定売り残。
  """
  @spec sell_holds([map()]) :: %{optional(String.t()) => Decimal.t()}
  def sell_holds(open_orders) when is_list(open_orders) do
    Enum.reduce(open_orders, %{}, fn order, acc ->
      code = Map.get(order, :product_code)
      unfilled = unfilled_size(order)

      if spot_sell?(code, Map.get(order, :side), unfilled) do
        currency = Product.base_currency(code)
        Map.update(acc, currency, unfilled, &Decimal.add(&1, unfilled))
      else
        acc
      end
    end)
  end

  @doc """
  最初の spot 売建玉（ドテン・short）。無ければ `nil`。
  """
  @spec first_short_spot([map()]) :: String.t() | nil
  def first_short_spot(positions) when is_list(positions) do
    Enum.find_value(positions, fn position ->
      code = Map.get(position, :product_code)
      size = Map.get(position, :size)

      if spot_sell?(code, Map.get(position, :side), size) do
        Product.base_currency(code)
      end
    end)
  end

  @doc """
  新規売り `size` が、買い建玉 − 既存売り残に収まるか。
  """
  @spec sell_covered?([map()], [map()], String.t(), Decimal.t()) :: boolean()
  def sell_covered?(positions, open_orders, product_code, %Decimal{} = size)
      when is_list(positions) and is_list(open_orders) and is_binary(product_code) do
    currency = Product.base_currency(product_code)
    claimed = Map.get(buy_claimed(positions), currency, Decimal.new(0))
    held = Map.get(sell_holds(open_orders), currency, Decimal.new(0))
    cover = Decimal.sub(claimed, held)
    Decimal.compare(size, cover) != :gt
  end

  defp spot_buy?(code, :buy, size), do: spot_size?(code, size)
  defp spot_buy?(_, _, _), do: false

  defp spot_sell?(code, :sell, size), do: spot_size?(code, size)
  defp spot_sell?(_, _, _), do: false

  defp spot_size?(code, %Decimal{} = size) when is_binary(code) do
    Product.spot?(code) and Decimal.compare(size, 0) == :gt
  end

  defp spot_size?(_, _), do: false

  defp unfilled_size(order) do
    size = Map.get(order, :size)
    filled = Map.get(order, :filled_size) || Decimal.new(0)

    cond do
      not match?(%Decimal{}, size) ->
        Decimal.new(0)

      not match?(%Decimal{}, filled) ->
        size

      true ->
        leftover = Decimal.sub(size, filled)

        if Decimal.compare(leftover, 0) == :gt do
          leftover
        else
          Decimal.new(0)
        end
    end
  end
end
