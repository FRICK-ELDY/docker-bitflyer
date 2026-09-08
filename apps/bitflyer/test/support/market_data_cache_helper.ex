defmodule Bitflyer.TestSupport.MarketDataCacheHelper do
  @moduledoc false

  alias Bitflyer.MarketData.Cache

  @doc """
  共有 MarketData.Cache を空にする（テスト間の汚染防止）。
  """
  def reset_market_data_cache do
    Cache.clear()
  end
end
