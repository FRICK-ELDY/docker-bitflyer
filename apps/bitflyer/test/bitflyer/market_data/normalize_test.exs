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

  test "decode_ws_frame decodes JSON once" do
    assert {:ok, %{"id" => 1, "result" => true}} =
             Normalize.decode_ws_frame(~s({"id":1,"result":true}))

    assert :error = Normalize.decode_ws_frame("not-json")
  end

  test "from_ws_frame ignores non channelMessage" do
    assert :ignore = Normalize.from_ws_frame(~s({"id":1,"result":true}))
  end

  test "rpc_response accepts only result true as subscribe ACK" do
    assert {:ok, 7} = Normalize.rpc_response(~s({"jsonrpc":"2.0","id":7,"result":true}))
    assert {:ok, 8} = Normalize.rpc_response(%{"id" => "8", "result" => true})

    assert {:error, 8, :subscribe_rejected} =
             Normalize.rpc_response(%{"id" => 8, "result" => nil})

    assert {:error, 8, :subscribe_rejected} =
             Normalize.rpc_response(%{"id" => 8, "result" => false})

    assert {:error, 8, :subscribe_rejected} = Normalize.rpc_response(%{"id" => 8})

    assert {:error, 9, "denied"} =
             Normalize.rpc_response(%{"id" => 9, "error" => %{"message" => "denied"}})

    assert {:error, 1, :channel_error} =
             Normalize.rpc_response(%{"method" => "channelError", "id" => 1})

    assert :not_rpc =
             Normalize.rpc_response(%{
               "method" => "channelMessage",
               "id" => 1,
               "params" => %{}
             })

    assert :not_rpc = Normalize.rpc_response(%{"result" => true})
    assert {:error, "x", :invalid_id} = Normalize.rpc_response(%{"id" => "x", "result" => true})
  end

  test "from_ticker rejects invalid ltp without raising" do
    assert :error =
             Normalize.from_ticker(%{"product_code" => "FX_BTC_JPY", "ltp" => "not-a-number"})
  end
end
