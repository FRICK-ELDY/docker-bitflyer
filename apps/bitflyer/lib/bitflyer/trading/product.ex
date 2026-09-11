defmodule Bitflyer.Trading.Product do
  @moduledoc """
  銘柄コードから基軸・決済通貨と市場種別を取り出す。

  live の残高モデルは現物（`getbalance`）のみ。FX/CFD（`getcollateral`）は未実装のため、
  live 対象は allowlist の `:spot` に限定する（improvement-plan P0 #2 B）。
  """

  @type market_type :: :spot | :fx | :unsupported

  # bitFlyer Lightning 現物。ここに無い BASE_QUOTE は :unsupported（安易に spot 扱いしない）。
  @spot_products MapSet.new([
                   "BTC_JPY",
                   "ETH_JPY",
                   "XRP_JPY",
                   "XLM_JPY",
                   "MONA_JPY",
                   "BCH_JPY",
                   "ETH_BTC",
                   "BCH_BTC"
                 ])

  @spec quote_currency(String.t()) :: String.t()
  def quote_currency("FX_BTC_JPY"), do: "JPY"
  def quote_currency("BTC_JPY"), do: "JPY"

  def quote_currency(product_code) when is_binary(product_code) do
    product_code
    |> String.split("_")
    |> List.last()
    |> String.split("-")
    |> List.first()
  end

  @spec base_currency(String.t()) :: String.t()
  def base_currency("FX_BTC_JPY"), do: "BTC"
  def base_currency("BTC_JPY"), do: "BTC"

  def base_currency(product_code) when is_binary(product_code) do
    parts = String.split(product_code, "_")

    parts
    |> Enum.at(max(length(parts) - 2, 0))
    |> String.split("-")
    |> List.first()
  end

  @doc """
  銘柄の市場種別。

  - `:spot` — allowlist の現物（残高は getbalance）。既定運用は `BTC_JPY`
  - `:fx` — `FX_*`（証拠金。live 未対応）
  - `:unsupported` — 先物・未登録ペア等
  """
  @spec market_type(String.t()) :: market_type()
  def market_type(<<"FX_", _::binary>>), do: :fx

  def market_type(product_code) when is_binary(product_code) do
    if MapSet.member?(@spot_products, product_code) do
      :spot
    else
      :unsupported
    end
  end

  @spec spot?(String.t()) :: boolean()
  def spot?(product_code) when is_binary(product_code), do: market_type(product_code) == :spot

  @spec fx?(String.t()) :: boolean()
  def fx?(product_code) when is_binary(product_code), do: market_type(product_code) == :fx

  @doc false
  def spot_products, do: MapSet.to_list(@spot_products)
end
