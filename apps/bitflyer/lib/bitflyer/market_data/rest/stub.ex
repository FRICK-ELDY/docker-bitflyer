defmodule Bitflyer.MarketData.Rest.Stub do
  @moduledoc false
  @behaviour Bitflyer.MarketData.Rest.Client

  @impl true
  def fetch_ticker(_product_code), do: {:error, :stub}
end
