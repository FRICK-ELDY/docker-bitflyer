defmodule Bitflyer.Strategy.FixedOnce do
  @moduledoc """
  固定ルール 1 本: 銘柄ごとに同じ冪等キーの成行買い意図を返す。

  dry_run / paper 向けの縦貫通用。`TRADE_MODE=live` では意図を返さない
  （runtime でも FixedOnce の有効化を拒否する）。

  実際に 1 回だけ通す制御は Runner（成功後にマーク）。evaluate 自体は純関数に近い。
  """

  @behaviour Bitflyer.Strategy

  @impl true
  def evaluate(market, _positions, params) when is_map(market) and is_map(params) do
    # live では自動成行を出さない（runtime 既定無効の二重防護）
    if Application.get_env(:bitflyer, :trade_mode) == :live do
      []
    else
      product_code = Map.fetch!(market, :product_code)
      market_key = Map.fetch!(market, :market_key)
      size = size_from(params)
      side = Map.get(params, :side, :buy)

      [
        %{
          internal_order_id: "strategy-fixed-once-#{product_code}",
          product_code: product_code,
          side: side,
          size: size,
          market_key: market_key,
          order_type: :market
        }
      ]
    end
  end

  defp size_from(params) do
    case Map.get(params, :size, "0.01") do
      %Decimal{} = size -> size
      raw when is_binary(raw) -> Decimal.new(raw)
      raw when is_integer(raw) -> Decimal.new(raw)
      raw when is_float(raw) -> Decimal.from_float(raw)
      _ -> Decimal.new("0.01")
    end
  end
end
