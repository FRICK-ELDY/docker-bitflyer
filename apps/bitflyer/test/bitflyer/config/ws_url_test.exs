defmodule Bitflyer.Config.WsUrlTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Config.WsUrl

  @inject "wss://127.0.0.1:1/json-rpc"

  test "empty or missing leaves the official default unchanged" do
    assert WsUrl.resolve(nil, :paper, :dev) == :unchanged
    assert WsUrl.resolve("", :paper, :dev) == :unchanged
    assert WsUrl.resolve("   ", :live, :prod) == :unchanged
  end

  test "test env ignores a leftover inject so Socket.Local stays" do
    assert WsUrl.resolve(@inject, :paper, :test) == :ignored_in_test
    assert WsUrl.resolve(@inject, :live, :test) == :ignored_in_test
  end

  test "dry_run and paper accept an inject override" do
    assert WsUrl.resolve(@inject, :dry_run, :dev) == {:override, @inject}
    assert WsUrl.resolve("  #{@inject}  ", :paper, :prod) == {:override, @inject}
  end

  test "live refuses any leftover URL so forged ticks cannot pass freshness" do
    assert_raise ArgumentError, ~r/BITFLYER_WS_URL cannot be set when TRADE_MODE=live/, fn ->
      WsUrl.resolve(@inject, :live, :prod)
    end

    assert_raise ArgumentError, ~r/forged ticks/, fn ->
      WsUrl.resolve("wss://ws.lightstream.bitflyer.com/json-rpc", :live, :dev)
    end
  end

  test "host_label drops path and query" do
    assert WsUrl.host_label("wss://evil.example/json-rpc?token=secret") ==
             "wss://evil.example"

    assert WsUrl.host_label("not a url") == "unparseable"
  end
end
