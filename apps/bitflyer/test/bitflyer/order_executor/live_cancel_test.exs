defmodule Bitflyer.OrderExecutor.Live.CancelTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.OrderExecutor
  alias Bitflyer.Trading.{Order, Position}

  defmodule CancelExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(request) do
      send(Process.whereis(__MODULE__) || self(), {:cancel_order, request})
      Agent.update(__MODULE__.Counter, fn n -> n + 1 end)
      :ok
    end

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      case Process.get({:after_cancel_order, id}) do
        nil ->
          {:ok,
           %{
             exchange_order_id: id,
             product_code: "FX_BTC_JPY",
             side: :buy,
             size: Decimal.new("0.01"),
             filled_size: Decimal.new("0"),
             average_price: nil,
             status: :canceled
           }}

        info ->
          {:ok, info}
      end
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    def cancel_count, do: Agent.get(__MODULE__.Counter, & &1)
  end

  setup do
    reset_readiness()

    start_supervised!(%{
      id: CancelExchange.Counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: CancelExchange.Counter]]}
    })
    Process.register(self(), CancelExchange)

    on_exit(fn ->
      reset_readiness()

      if Process.whereis(CancelExchange) == self() do
        Process.unregister(CancelExchange)
      end
    end)

    :ok
  end

  test "cancel syncs partial fill before marking cancelled" do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "cancel-partial-1",
        exchange_order_id: "JRF-cancel-partial",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :limit,
        price: Decimal.new("5000000"),
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        trade_mode: :live
      })
      |> Ash.create()

    Process.put({:after_cancel_order, "JRF-cancel-partial"}, %{
      exchange_order_id: "JRF-cancel-partial",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.006"),
      average_price: Decimal.new("5000000"),
      status: :canceled
    })

    assert {:ok, updated} = OrderExecutor.cancel(order, exchange: CancelExchange)
    assert updated.status == :cancelled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.006"))
    assert CancelExchange.cancel_count() == 1

    {:ok, [%{size: size}]} =
      Position
      |> Ash.Query.filter(trade_mode == :live and product_code == "FX_BTC_JPY")
      |> Ash.read()

    assert Decimal.eq?(size, Decimal.new("0.006"))
  end

  test "cancel is allowed while readiness is halted" do
    assert Bitflyer.Readiness.halt(:reconcile_mismatch) == :ok

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "cancel-halted-1",
        exchange_order_id: "JRF-cancel-halted",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :market,
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        trade_mode: :live
      })
      |> Ash.create()

    assert {:ok, %{status: :cancelled}} = OrderExecutor.cancel(order, exchange: CancelExchange)
    assert CancelExchange.cancel_count() == 1
  end

  test "cancel ignores opts trade_mode override for live orders" do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "cancel-mode-1",
        exchange_order_id: "JRF-cancel-mode",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :market,
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        trade_mode: :live
      })
      |> Ash.create()

    # dry_run 上書きしても取引所 cancel を呼ぶ
    assert {:ok, _} = OrderExecutor.cancel(order, trade_mode: :dry_run, exchange: CancelExchange)
    assert CancelExchange.cancel_count() == 1
  end

  test "cancel keeps pending when exchange still ACTIVE (late fills remain recoverable)" do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "cancel-race-1",
        exchange_order_id: "JRF-cancel-race",
        product_code: "FX_BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :limit,
        price: Decimal.new("5000000"),
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        trade_mode: :live
      })
      |> Ash.create()

    Process.put({:after_cancel_order, "JRF-cancel-race"}, %{
      exchange_order_id: "JRF-cancel-race",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      average_price: nil,
      status: :active
    })

    assert {:ok, updated} = OrderExecutor.cancel(order, exchange: CancelExchange)
    assert updated.status == :pending
    assert CancelExchange.cancel_count() == 1
  end
end
