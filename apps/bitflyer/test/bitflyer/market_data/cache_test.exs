defmodule Bitflyer.MarketData.CacheTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.MarketDataCacheHelper

  alias Bitflyer.MarketData.Cache

  setup do
    reset_market_data_cache()

    on_exit(fn ->
      reset_market_data_cache()
    end)

    :ok
  end

  test "put/get stores value with received_at without requiring a read call" do
    assert Cache.put({:ticker, "FX_BTC_JPY"}, %{ltp: Decimal.new("5000000")}) == :ok

    assert {:ok, %{ltp: ltp}, received_at} = Cache.get({:ticker, "FX_BTC_JPY"})
    assert Decimal.eq?(ltp, Decimal.new("5000000"))
    assert is_integer(received_at)

    assert [{_, value, ets_received_at}] =
             :ets.lookup(Cache, {:ticker, "FX_BTC_JPY"})

    assert value == %{ltp: ltp}
    assert ets_received_at == received_at
  end

  test "fresh?/2 is fail-closed on miss and after max_age" do
    refute Cache.fresh?(:missing, 1_000)

    now = 100_000
    assert Cache.put(:board, %{bids: []}, received_at: now) == :ok

    assert Cache.fresh?(:board, 500, now: now)
    assert Cache.fresh?(:board, 500, now: now + 500)
    refute Cache.fresh?(:board, 500, now: now + 501)

    assert Cache.age_ms(:board, now: now + 200) == 200
    assert Cache.age_ms(:missing) == :miss
  end

  test "entry_fresh?/3 is a pure gate for risk-manager" do
    assert Cache.entry_fresh?(1_000, 100, 1_100)
    refute Cache.entry_fresh?(1_000, 100, 1_101)
  end

  test "delete and clear remove entries" do
    assert Cache.put(:a, 1) == :ok
    assert Cache.put(:b, 2) == :ok

    assert Cache.delete(:a) == :ok
    assert Cache.get(:a) == :miss
    assert {:ok, 2, _} = Cache.get(:b)

    assert Cache.clear() == :ok
    assert Cache.get(:b) == :miss
  end

  test "default_max_age_ms is configured" do
    assert Cache.default_max_age_ms() == 5_000
  end
end
