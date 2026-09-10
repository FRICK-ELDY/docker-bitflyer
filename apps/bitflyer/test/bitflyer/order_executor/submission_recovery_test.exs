defmodule Bitflyer.OrderExecutor.SubmissionRecoveryTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.OrderExecutor.SubmissionRecovery
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.Order

  @size Decimal.new("0.01")
  @price Decimal.new("5000000")

  defmodule UniqueExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(%{product_code: "FX_BTC_JPY"}) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok,
       [
         %{
           exchange_order_id: "JRF-unique-1",
           product_code: "FX_BTC_JPY",
           side: :buy,
           size: Decimal.new("0.01"),
           filled_size: Decimal.new("0"),
           average_price: nil,
           status: :active,
           price: Decimal.new("5000000"),
           order_type: :limit,
           ordered_at: now
         }
       ]}
    end
  end

  defmodule AmbiguousExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(%{product_code: "FX_BTC_JPY"}) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      base = %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        average_price: nil,
        status: :active,
        price: Decimal.new("5000000"),
        order_type: :limit,
        ordered_at: now
      }

      {:ok,
       [
         Map.put(base, :exchange_order_id, "JRF-a"),
         Map.put(base, :exchange_order_id, "JRF-b")
       ]}
    end
  end

  defmodule EmptyExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule BadDateExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(_), do: {:error, :invalid_datetime}
  end

  defmodule TruncExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(%{count: probe}) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = fn id ->
        %{
          exchange_order_id: id,
          product_code: "FX_BTC_JPY",
          side: :sell,
          size: Decimal.new("9"),
          filled_size: Decimal.new("0"),
          average_price: nil,
          status: :active,
          price: Decimal.new("1"),
          order_type: :limit,
          ordered_at: now
        }
      end

      # probe 件ちょうど返す → 要求 count (= probe-1) を超えるので切り捨て
      {:ok, Enum.map(1..probe, fn i -> row.("JRF-t#{i}") end)}
    end
  end

  defmodule ExactPageExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def list_child_orders(%{count: 3}) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # 要求 count=2 に対する probe=3 だが、実体は 2 件のみ → 成功
      {:ok,
       [
         %{
           exchange_order_id: "JRF-exact-1",
           product_code: "FX_BTC_JPY",
           side: :buy,
           size: Decimal.new("0.01"),
           filled_size: Decimal.new("0"),
           average_price: nil,
           status: :active,
           price: Decimal.new("5000000"),
           order_type: :limit,
           ordered_at: now
         },
         %{
           exchange_order_id: "JRF-noise",
           product_code: "FX_BTC_JPY",
           side: :sell,
           size: Decimal.new("9"),
           filled_size: Decimal.new("0"),
           average_price: nil,
           status: :active,
           price: Decimal.new("1"),
           order_type: :limit,
           ordered_at: now
         }
       ]}
    end
  end

  setup do
    reset_readiness()
    :ok
  end

  test "dry-run unique candidate without writing" do
    order = create_unknown!("ord-unique")

    assert {:ok, preview} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               exchange: UniqueExchange
             )

    assert preview.match == :unique
    assert length(preview.candidates) == 1
    assert hd(preview.candidates).exchange_order_id == "JRF-unique-1"

    reloaded = reload!(order.internal_order_id)
    assert reloaded.exchange_order_id == nil
    assert reloaded.status == :submission_unknown
  end

  test "confirm unique binds id and does not mark ready" do
    order = create_unknown!("ord-bind")
    _ = Readiness.halt(:submission_unknown)

    {:ok, preview} =
      SubmissionRecovery.recover(
        dry_run?: true,
        operator: "bob",
        internal_order_id: order.internal_order_id,
        exchange: UniqueExchange
      )

    assert {:ok, result} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "bob",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               exchange: UniqueExchange
             )

    assert result.action == :bound
    assert result.exchange_order_id == "JRF-unique-1"

    reloaded = reload!(order.internal_order_id)
    assert reloaded.exchange_order_id == "JRF-unique-1"
    assert reloaded.status in [:pending, :partially_filled, :filled, :cancelled, :expired]
    refute Readiness.ready?()
    assert match?({:halted, _}, Readiness.get())
  end

  test "ambiguous requires exchange_order_id approval" do
    order = create_unknown!("ord-amb")

    {:ok, preview} =
      SubmissionRecovery.recover(
        dry_run?: true,
        operator: "alice",
        internal_order_id: order.internal_order_id,
        exchange: AmbiguousExchange
      )

    assert preview.match == :ambiguous

    assert {:error, :ambiguous_requires_id} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               exchange: AmbiguousExchange
             )

    assert {:ok, result} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               exchange_order_id: "JRF-b",
               exchange: AmbiguousExchange
             )

    assert result.exchange_order_id == "JRF-b"
    assert reload!(order.internal_order_id).exchange_order_id == "JRF-b"
  end

  test "none requires absent confirm to cancel" do
    order = create_unknown!("ord-none")

    {:ok, preview} =
      SubmissionRecovery.recover(
        dry_run?: true,
        operator: "alice",
        internal_order_id: order.internal_order_id,
        exchange: EmptyExchange
      )

    assert preview.match == :none

    assert {:error, :not_found_on_exchange, _} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               exchange: EmptyExchange
             )

    assert {:ok, result} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               absent?: true,
               exchange: EmptyExchange
             )

    assert result.action == :absent
    assert result.hold_released? == false
    assert reload!(order.internal_order_id).status == :cancelled
  end

  test "invalid exchange datetime fails closed instead of match=none" do
    order = create_unknown!("ord-bad-date")

    assert {:error, :invalid_exchange_payload, %{kind: :invalid_datetime}} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               exchange: BadDateExchange
             )
  end

  test "full page list is treated as truncated not none" do
    order = create_unknown!("ord-trunc")

    assert {:error, :child_order_list_truncated, %{count: 2, returned: 3}} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               exchange: TruncExchange,
               count: 2
             )
  end

  test "exactly count rows still succeeds via count+1 probe" do
    order = create_unknown!("ord-exact")

    assert {:ok, preview} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               exchange: ExactPageExchange,
               count: 2
             )

    assert preview.match == :unique
    assert hd(preview.candidates).exchange_order_id == "JRF-exact-1"
  end

  test "cancelled without id can be recovered again after false absent" do
    order = create_unknown!("ord-rebind")

    {:ok, preview} =
      SubmissionRecovery.recover(
        dry_run?: true,
        operator: "alice",
        internal_order_id: order.internal_order_id,
        exchange: EmptyExchange
      )

    assert {:ok, _} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: preview.snapshot_hash,
               absent?: true,
               exchange: EmptyExchange
             )

    assert reload!(order.internal_order_id).status == :cancelled

    {:ok, rebound_preview} =
      SubmissionRecovery.recover(
        dry_run?: true,
        operator: "alice",
        internal_order_id: order.internal_order_id,
        exchange: UniqueExchange
      )

    assert rebound_preview.match == :unique

    assert {:ok, result} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: rebound_preview.snapshot_hash,
               exchange: UniqueExchange
             )

    assert result.action == :bound
    assert reload!(order.internal_order_id).exchange_order_id == "JRF-unique-1"
  end

  test "confirm requires matching expected_hash" do
    order = create_unknown!("ord-hash")

    assert {:error, :expected_hash_required} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               exchange: UniqueExchange
             )

    assert {:error, :snapshot_hash_mismatch, _} =
             SubmissionRecovery.recover(
               confirm?: true,
               operator: "alice",
               internal_order_id: order.internal_order_id,
               expected_hash: "deadbeef",
               exchange: UniqueExchange
             )
  end

  test "rejects already resolved and non-live" do
    {:ok, live} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "ord-resolved",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :limit,
        price: @price,
        size: @size,
        trade_mode: :live,
        exchange_order_id: "JRF-done"
      })
      |> Ash.create()

    assert {:error, :already_resolved, _} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: live.internal_order_id,
               exchange: UniqueExchange
             )

    {:ok, paper} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "ord-paper",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :submission_unknown,
        order_type: :limit,
        price: @price,
        size: @size,
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:error, :live_only, _} =
             SubmissionRecovery.recover(
               dry_run?: true,
               operator: "alice",
               internal_order_id: paper.internal_order_id,
               exchange: UniqueExchange
             )
  end

  defp create_unknown!(id) do
    assert {:ok, order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: id,
               product_code: "FX_BTC_JPY",
               side: :buy,
               status: :submission_unknown,
               order_type: :limit,
               price: @price,
               size: @size,
               trade_mode: :live
             })
             |> Ash.create()

    order
  end

  defp reload!(internal_order_id) do
    assert {:ok, order} =
             Order
             |> Ash.Query.filter(internal_order_id == ^internal_order_id)
             |> Ash.read_one()

    order
  end
end
