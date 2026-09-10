defmodule Bitflyer.Risk.BalanceCacheTest do
  use Bitflyer.DataCase, async: false

  alias Bitflyer.Risk.BalanceCache
  alias Bitflyer.Trading.BalanceSnapshot

  setup do
    BalanceCache.reset()

    on_exit(fn -> BalanceCache.reset() end)

    :ok
  end

  test "starts unsynced and put/get round-trips" do
    assert {:error, :unsynced} = BalanceCache.get(:paper)

    assert :ok =
             BalanceCache.put(:paper, %{
               "JPY" => Decimal.new("1000"),
               "BTC" => Decimal.new("0.1")
             })

    assert {:ok, balances} = BalanceCache.get(:paper)
    assert Decimal.equal?(balances["JPY"], Decimal.new("1000"))
    assert Decimal.equal?(balances["BTC"], Decimal.new("0.1"))
  end

  test "empty put stays unsynced" do
    assert {:error, :empty} = BalanceCache.put(:paper, %{})
    assert {:error, :unsynced} = BalanceCache.get(:paper)
  end

  test "refresh loads latest BalanceSnapshot tips" do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: "JPY",
               amount: Decimal.new("5000"),
               available: Decimal.new("5000"),
               captured_at: captured_at,
               trade_mode: :paper
             })
             |> Ash.create()

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: "BTC",
               amount: Decimal.new("0.2"),
               available: Decimal.new("0.2"),
               captured_at: captured_at,
               trade_mode: :paper
             })
             |> Ash.create()

    assert :ok = BalanceCache.refresh(:paper)
    assert {:ok, balances} = BalanceCache.get(:paper)
    assert Decimal.equal?(balances["JPY"], Decimal.new("5000"))
    assert Decimal.equal?(balances["BTC"], Decimal.new("0.2"))
  end

  test "invalidate keeps get unsynced until matching release reload" do
    balances = %{
      "JPY" => Decimal.new("1000"),
      "BTC" => Decimal.new("1")
    }

    assert :ok = BalanceCache.put(:paper, balances)

    assert {:ok, gen} = BalanceCache.invalidate(:paper)
    assert {:error, :unsynced} = BalanceCache.get(:paper)

    assert {:ok, :deferred} = BalanceCache.put(:paper, balances)
    assert {:error, :unsynced} = BalanceCache.get(:paper)

    assert :ok =
             BalanceCache.put(:paper, balances,
               generation: gen,
               release_barrier: true
             )

    assert {:ok, _} = BalanceCache.get(:paper)
  end

  test "reserve deducts and blocks overspend" do
    assert :ok =
             BalanceCache.put(:live, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert :ok =
             BalanceCache.reserve(:live, "JPY", Decimal.new("60000"), hold_id: "hold-a")

    assert {:ok, balances} = BalanceCache.get(:live)
    assert Decimal.equal?(balances["JPY"], Decimal.new("40000"))

    assert {:error, :insufficient_balance, %{currency: "JPY"}} =
             BalanceCache.reserve(:live, "JPY", Decimal.new("50000"), hold_id: "hold-b")
  end

  test "release_hold returns the reserved amount not a recomputed notional" do
    assert :ok =
             BalanceCache.put(:live, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert :ok =
             BalanceCache.reserve(:live, "JPY", Decimal.new("50000"), hold_id: "mkt-1")

    assert :ok = BalanceCache.release_hold(:live, "mkt-1")
    assert {:ok, balances} = BalanceCache.get(:live)
    assert Decimal.equal?(balances["JPY"], Decimal.new("100000"))
  end

  test "absolute put reapplies remaining holds" do
    assert :ok =
             BalanceCache.put(:paper, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert :ok =
             BalanceCache.reserve(:paper, "JPY", Decimal.new("30000"), hold_id: "pending-a")

    # Snapshot tip は pending を知らない絶対値
    assert :ok =
             BalanceCache.put(:paper, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert {:ok, balances} = BalanceCache.get(:paper)
    assert Decimal.equal?(balances["JPY"], Decimal.new("70000"))

    assert :ok = BalanceCache.release_hold(:paper, "pending-a")
    assert {:ok, after_release} = BalanceCache.get(:paper)
    assert Decimal.equal?(after_release["JPY"], Decimal.new("100000"))
  end

  test "consume_hold_proportional leaves remainder for cancel release" do
    assert :ok =
             BalanceCache.put(:live, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert :ok =
             BalanceCache.reserve(:live, "JPY", Decimal.new("100000"), hold_id: "partial-1")

    assert :ok =
             BalanceCache.consume_hold_proportional(
               :live,
               "partial-1",
               Decimal.new("0.01"),
               Decimal.new("0.02")
             )

    assert {:ok, mid} = BalanceCache.get(:live)
    assert Decimal.equal?(mid["JPY"], Decimal.new("0"))

    assert :ok = BalanceCache.release_hold(:live, "partial-1")
    assert {:ok, after_release} = BalanceCache.get(:live)
    assert Decimal.equal?(after_release["JPY"], Decimal.new("50000"))
  end

  test "align_hold_to_filled caps release after missed consume" do
    assert :ok =
             BalanceCache.put(:live, %{
               "JPY" => Decimal.new("100000"),
               "BTC" => Decimal.new("0")
             })

    assert :ok =
             BalanceCache.reserve(:live, "JPY", Decimal.new("100000"), hold_id: "missed-1")

    # consume 欠落: hold は当初全額のまま。filled 半分に揃えてから release
    assert :ok =
             BalanceCache.align_hold_to_filled(
               :live,
               "missed-1",
               Decimal.new("0.01"),
               Decimal.new("0.02")
             )

    assert :ok = BalanceCache.release_hold(:live, "missed-1")
    assert {:ok, balances} = BalanceCache.get(:live)
    assert Decimal.equal?(balances["JPY"], Decimal.new("50000"))
  end
end
