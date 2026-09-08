defmodule Bitflyer.MarketData.NormalizeTest do
  use ExUnit.Case, async: true

  alias Bitflyer.MarketData.Normalize

  test "from_ticker normalizes REST ticker body" do
    assert {:ok, {:ticker, "FX_BTC_JPY"}, %{ltp: ltp}} =
             Normalize.from_ticker(%{"product_code" => "FX_BTC_JPY", "ltp" => 5_000_000})

    assert Decimal.equal?(ltp, Decimal.new(5_000_000))
  end

  test "from_ws_frame extracts channelMessage ticker" do
    frame =
      Jason.encode!(%{
        "method" => "channelMessage",
        "params" => %{
          "channel" => "lightning_ticker_FX_BTC_JPY",
          "message" => %{"product_code" => "FX_BTC_JPY", "ltp" => "5100000"}
        }
      })

    assert {:ok, {:ticker, "FX_BTC_JPY"}, %{ltp: ltp}} = Normalize.from_ws_frame(frame)
    assert Decimal.equal?(ltp, Decimal.new("5100000"))
  end

  test "from_ws_frame ignores non channelMessage" do
    assert :ignore = Normalize.from_ws_frame(~s({"id":1,"result":true}))
  end
end
