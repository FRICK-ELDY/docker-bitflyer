defmodule Bitflyer.Startup.BaselineTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Startup.{Baseline, Reconcile, Reconciler}
  alias Bitflyer.Trading.{BalanceSnapshot, BaselineImport}

  @jpy Decimal.new("1000000")
  @btc Decimal.new("0.5")

  defmodule MatchingExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [],
         balances: [
           %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("1000000")},
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")},
           %{currency: "ETH", amount: Decimal.new("1"), available: Decimal.new("1")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used}
  end

  defmodule IncompleteExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [],
         balances: [
           %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("1000000")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used}
  end

  setup do
    reset_readiness()
    :ok
  end

  test "rejects missing confirm/dry-run and missing operator" do
    assert {:error, :confirm_required} = Baseline.import(operator: "alice")
    assert {:error, :operator_required} = Baseline.import(dry_run?: true)

    assert {:error, :ambiguous_mode} =
             Baseline.import(dry_run?: true, confirm?: true, operator: "a")
  end

  test "live only" do
    assert {:error, :live_only, %{trade_mode: :paper}} =
             Baseline.import(
               dry_run?: true,
               operator: "alice",
               trade_mode: :paper,
               exchange: MatchingExchange
             )
  end

  test "dry-run previews hash without writing snapshots or marking ready" do
    readiness_before = Readiness.get()

    assert {:ok, preview} =
             Baseline.import(
               dry_run?: true,
               operator: "alice",
               trade_mode: :live,
               exchange: MatchingExchange
             )

    assert preview.dry_run? == true
    assert preview.operator == "alice"
    assert preview.currencies == ["JPY", "BTC"]
    assert preview.snapshot_hash == Baseline.snapshot_hash(preview.balances)
    refute Enum.any?(preview.balances, &(&1.currency == "ETH"))

    assert {:ok, []} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :live)
             |> Ash.read()

    assert {:ok, []} = BaselineImport |> Ash.read()
    assert Readiness.get() == readiness_before
    refute Readiness.ready?()
  end

  test "confirm requires expected_hash matching dry-run" do
    assert {:error, :expected_hash_required} =
             Baseline.import(
               confirm?: true,
               operator: "bob",
               trade_mode: :live,
               exchange: MatchingExchange
             )

    assert {:error, :snapshot_hash_mismatch, %{expected: "deadbeef", actual: actual}} =
             Baseline.import(
               confirm?: true,
               operator: "bob",
               trade_mode: :live,
               exchange: MatchingExchange,
               expected_hash: "deadbeef"
             )

    assert actual ==
             Baseline.snapshot_hash([
               %{currency: "JPY", amount: @jpy, available: @jpy},
               %{currency: "BTC", amount: @btc, available: @btc}
             ])
  end

  test "confirm writes snapshots and audit row but does not mark ready" do
    {:ok, preview} =
      Baseline.import(
        dry_run?: true,
        operator: "bob",
        trade_mode: :live,
        exchange: MatchingExchange
      )

    assert %{operator: "bob", snapshot_hash: hash} =
             Bitflyer.Telemetry.sanitize_metadata(%{
               operator: "bob",
               snapshot_hash: preview.snapshot_hash,
               api_secret: "nope"
             })

    assert hash == preview.snapshot_hash

    assert {:ok, result} =
             Baseline.import(
               confirm?: true,
               operator: "bob",
               trade_mode: :live,
               exchange: MatchingExchange,
               expected_hash: preview.snapshot_hash
             )

    assert result.dry_run? == false
    assert %BaselineImport{} = result.import
    assert result.import.operator == "bob"
    assert result.import.snapshot_hash == result.snapshot_hash
    assert result.import.payload["balances"] |> length() == 2

    assert {:ok, snaps} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :live)
             |> Ash.read()

    assert length(snaps) == 2
    jpy = Enum.find(snaps, &(&1.currency == "JPY"))
    btc = Enum.find(snaps, &(&1.currency == "BTC"))
    assert Decimal.eq?(jpy.amount, @jpy)
    assert Decimal.eq?(btc.amount, @btc)

    refute Readiness.ready?()
  end

  test "confirm fills only missing required currencies" do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: "JPY",
               amount: @jpy,
               available: @jpy,
               captured_at: captured_at,
               trade_mode: :live
             })
             |> Ash.create()

    {:ok, preview} =
      Baseline.import(
        dry_run?: true,
        operator: "alice",
        trade_mode: :live,
        exchange: MatchingExchange
      )

    assert preview.currencies == ["BTC"]

    assert {:ok, result} =
             Baseline.import(
               confirm?: true,
               operator: "alice",
               trade_mode: :live,
               exchange: MatchingExchange,
               expected_hash: preview.snapshot_hash
             )

    assert result.currencies == ["BTC"]

    assert {:ok, snaps} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :live)
             |> Ash.read()

    assert length(snaps) == 2
    assert Enum.any?(snaps, &(&1.currency == "BTC"))
  end

  test "confirm refuses when all required tips already exist" do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {currency, amount} <- [{"JPY", @jpy}, {"BTC", @btc}] do
      assert {:ok, _} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: currency,
                 amount: amount,
                 available: amount,
                 captured_at: captured_at,
                 trade_mode: :live
               })
               |> Ash.create()
    end

    assert {:error, :baseline_already_complete, _} =
             Baseline.import(
               confirm?: true,
               operator: "alice",
               trade_mode: :live,
               exchange: MatchingExchange,
               expected_hash: "unused"
             )
  end

  test "fails when exchange lacks a required missing currency" do
    assert {:error, :exchange_currency_missing, %{currency: "BTC"}} =
             Baseline.import(
               dry_run?: true,
               operator: "alice",
               trade_mode: :live,
               exchange: IncompleteExchange
             )
  end

  test "after confirm, matching reconcile can become ready via reconciler" do
    {:ok, preview} =
      Baseline.import(
        dry_run?: true,
        operator: "carol",
        trade_mode: :live,
        exchange: MatchingExchange
      )

    assert {:ok, _} =
             Baseline.import(
               confirm?: true,
               operator: "carol",
               trade_mode: :live,
               exchange: MatchingExchange,
               expected_hash: preview.snapshot_hash
             )

    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, MatchingExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: MatchingExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.ready?()
  end
end
