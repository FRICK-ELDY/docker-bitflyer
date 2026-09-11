defmodule Bitflyer.TestSupport.FillExecutions do
  @moduledoc false

  # テスト用 Exchange が getexecutions を返す共通ヘルパ。
  # Process に {:fill_execs, id} があればそれを優先。なければ fill_order / after_cancel_order から 1 本合成。

  @spec from_process(String.t()) :: [map()]
  def from_process(exchange_order_id) when is_binary(exchange_order_id) do
    case Process.get({:fill_execs, exchange_order_id}) do
      list when is_list(list) ->
        list

      _ ->
        info =
          Process.get({:fill_order, exchange_order_id}) ||
            Process.get({:after_cancel_order, exchange_order_id})

        from_order_info(exchange_order_id, info)
    end
  end

  @spec from_order_info(String.t(), map() | nil | :missing) :: [map()]
  def from_order_info(_exchange_order_id, nil), do: []
  def from_order_info(_exchange_order_id, :missing), do: []

  def from_order_info(exchange_order_id, info) when is_map(info) do
    filled = Map.get(info, :filled_size) || Map.get(info, "filled_size") || Decimal.new(0)

    case Decimal.compare(filled, 0) do
      :gt ->
        price =
          Map.get(info, :average_price) || Map.get(info, "average_price") ||
            Decimal.new("5000000")

        product =
          Map.get(info, :product_code) || Map.get(info, "product_code") || "BTC_JPY"

        side = Map.get(info, :side) || Map.get(info, "side") || :buy

        [
          %{
            id: "auto-#{exchange_order_id}-#{Decimal.to_string(filled)}",
            exchange_order_id: exchange_order_id,
            product_code: product,
            side: side,
            price: price,
            size: filled,
            executed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          }
        ]

      _ ->
        []
    end
  end
end
