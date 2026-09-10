defmodule Bitflyer.MarketData.NormalizeTest do
  use ExUnit.Case, async: true

  alias Bitflyer.MarketData.Normalize

  test "from_ticker normalizes REST ticker body with source_timestamp" do
    assert {:ok, {:ticker, "FX_BTC_JPY"}, %{ltp: ltp, source_timestamp: ts}} =
             Normalize.from_ticker(%{
               "product_code" => "FX_BTC_JPY",
               "ltp" => 5_000_000,
               "timestamp" => "2015-07-08T02:50:59.97"
             })

    assert Decimal.equal?(ltp, Decimal.new(5_000_000))
    assert %DateTime{} = ts
    assert ts.year == 2015
    assert ts.month == 7
    assert ts.day == 8
  end

  test "from_ticker allows missing timestamp as nil" do
    assert {:ok, {:ticker, "FX_BTC_JPY"}, %{ltp: ltp, source_timestamp: nil}} =
             Normalize.from_ticker(%{"product_code" => "FX_BTC_JPY", "ltp" => 5_000_000})

    assert Decimal.equal?(ltp, Decimal.new(5_000_000))
  end

  test "from_ticker rejects invalid timestamp without raising" do
    assert :error =
             Normalize.from_ticker(%{
               "product_code" => "FX_BTC_JPY",
               "ltp" => 5_000_000,
               "timestamp" => "not-a-datetime"
             })
  end

  test "from_ws_frame extracts channelMessage ticker" do
    frame =
      Jason.encode!(%{
        "method" => "channelMessage",
        "params" => %{
          "channel" => "lightning_ticker_FX_BTC_JPY",
          "message" => %{
            "product_code" => "FX_BTC_JPY",
            "ltp" => "5100000",
            "timestamp" => "2015-07-08T02:50:59.97Z"
          }
        }
      })

    assert {:ok, {:ticker, "FX_BTC_JPY"}, %{ltp: ltp, source_timestamp: %DateTime{}}} =
             Normalize.from_ws_frame(frame)

    assert Decimal.equal?(ltp, Decimal.new("5100000"))
  end

  test "from_ws_frame rejects channel and product_code mismatch" do
    frame =
      Jason.encode!(%{
        "method" => "channelMessage",
        "params" => %{
          "channel" => "lightning_ticker_BTC_JPY",
          "message" => %{
            "product_code" => "FX_BTC_JPY",
            "ltp" => "5100000",
            "timestamp" => "2015-07-08T02:50:59.97Z"
          }
        }
      })

    assert :error = Normalize.from_ws_frame(frame)
  end

  test "from_ws_frame ignores non channelMessage" do
    assert :ignore = Normalize.from_ws_frame(~s({"id":1,"result":true}))
  end

  test "from_ticker rejects invalid ltp without raising" do
    assert :error =
             Normalize.from_ticker(%{"product_code" => "FX_BTC_JPY", "ltp" => "not-a-number"})
  end
end
