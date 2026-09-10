defmodule Bitflyer.TestSupport.MarketDataCacheHelper do
  @moduledoc false

  alias Bitflyer.MarketData.Cache

  @doc """
  共有 MarketData.Cache を空にする（テスト間の汚染防止）。
  """
  def reset_market_data_cache do
    Cache.clear()
  end

  @doc """
  Risk.authorize が通る鮮度付き ticker 値（取引所時刻付き）。
  """
  def fresh_ticker_value(ltp \\ Decimal.new("5000000")) do
    %{
      ltp: ltp,
      source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
    }
  end

  @doc """
  既定銘柄へ鮮度付き ticker を書く。
  """
  def put_fresh_ticker(key \\ {:ticker, "FX_BTC_JPY"}, ltp \\ Decimal.new("5000000"), opts \\ []) do
    Cache.put(key, fresh_ticker_value(ltp), opts)
  end
end
