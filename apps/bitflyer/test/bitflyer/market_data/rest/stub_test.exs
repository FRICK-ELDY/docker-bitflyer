defmodule Bitflyer.MarketData.Rest.StubTest do
  use ExUnit.Case, async: false

  alias Bitflyer.MarketData.Rest.Stub

  setup do
    previous = Application.get_env(:bitflyer, Stub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bitflyer, Stub)
      else
        Application.put_env(:bitflyer, Stub, previous)
      end
    end)

    :ok
  end

  test "fetch_ticker returns :stub when response is :error" do
    Application.put_env(:bitflyer, Stub, response: :error)
    assert {:error, :stub} = Stub.fetch_ticker("FX_BTC_JPY")
  end

  test "fetch_ticker returns fresh ticker when response is :ok" do
    Application.put_env(:bitflyer, Stub, response: :ok)

    assert {:ok, %{"product_code" => "FX_BTC_JPY", "ltp" => 5_000_000, "timestamp" => ts}} =
             Stub.fetch_ticker("FX_BTC_JPY")

    assert is_binary(ts)
  end
end
