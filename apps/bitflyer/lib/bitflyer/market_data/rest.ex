defmodule Bitflyer.MarketData.Rest do
  @moduledoc """
  bitFlyer 公開 REST で ticker を取得する（穴埋め用）。
  """

  @behaviour Bitflyer.MarketData.Rest.Client

  @impl true
  def fetch_ticker(product_code) when is_binary(product_code) do
    base = Keyword.get(Bitflyer.MarketData.config(), :rest_base_url, "https://api.bitflyer.com")
    url = String.trim_trailing(base, "/") <> "/v1/ticker"

    case Req.get(url, params: [product_code: product_code], receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
