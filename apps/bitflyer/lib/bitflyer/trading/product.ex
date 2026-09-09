defmodule Bitflyer.Trading.Product do
  @moduledoc """
  銘柄コードから基軸・決済通貨を取り出す。
  """

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
end
