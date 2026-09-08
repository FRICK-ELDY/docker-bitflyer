defmodule Bitflyer.MarketData.Rest.Client do
  @moduledoc """
  公開 REST ticker 取得の契約。
  """

  @callback fetch_ticker(product_code :: String.t()) :: {:ok, map()} | {:error, term()}
end
