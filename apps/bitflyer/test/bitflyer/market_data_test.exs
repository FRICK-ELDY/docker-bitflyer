defmodule Bitflyer.MarketDataTest do
  use ExUnit.Case, async: false

  alias Bitflyer.MarketData

  setup do
    previous = Application.get_env(:bitflyer, MarketData)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:bitflyer, MarketData)
      else
        Application.put_env(:bitflyer, MarketData, previous)
      end
    end)

    :ok
  end

  test "config returns [] when env is explicitly nil" do
    Application.put_env(:bitflyer, MarketData, nil)
    assert MarketData.config() == []
    assert MarketData.product_codes() == ["BTC_JPY"]
  end

  test "product_codes falls back when list is empty" do
    Application.put_env(:bitflyer, MarketData, product_codes: [])
    assert MarketData.product_codes() == ["BTC_JPY"]
  end

  test "product_codes normalizes atoms and binaries" do
    Application.put_env(:bitflyer, MarketData, product_codes: [:BTC_JPY, "ETH_JPY"])
    assert MarketData.product_codes() == ["BTC_JPY", "ETH_JPY"]
  end
end
