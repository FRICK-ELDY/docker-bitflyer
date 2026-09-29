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
  Risk.authorize が通る鮮度付き ticker 値（LTP 層の取引所時刻とタイトな book 付き）。
  """
  def fresh_ticker_value(ltp \\ Decimal.new("5000000")) do
    # 片側 ~1 bps。既定 max_spread_pct 0.5% を余裕で下回る
    half = Decimal.max(Decimal.new("1"), Decimal.mult(ltp, Decimal.new("0.0001")))

    %{
      ltp: %{
        price: ltp,
        source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
      },
      book: %{
        best_bid: Decimal.sub(ltp, half),
        best_ask: Decimal.add(ltp, half),
        # live 成行買いは最上段数量が必要。テストの通常サイズより厚い段にする。
        best_ask_size: Decimal.new("100")
      }
    }
  end

  @doc """
  既定銘柄へ鮮度付き ticker を書く。
  """
  def put_fresh_ticker(key \\ {:ticker, "BTC_JPY"}, ltp \\ Decimal.new("5000000"), opts \\ []) do
    Cache.put(key, fresh_ticker_value(ltp), opts)
  end
end
