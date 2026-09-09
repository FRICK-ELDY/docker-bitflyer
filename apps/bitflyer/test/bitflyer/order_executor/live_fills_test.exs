defmodule Bitflyer.OrderExecutor.LiveFillsTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  alias Bitflyer.OrderExecutor.LiveFills
  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position}

  defmodule FillExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      case Process.get({:fill_order, id}) do
        :missing -> {:error, :order_not_found}
        nil -> {:error, :order_not_found}
        info -> {:ok, info}
      end
    end

    @impl true
    def fetch_executions(%{exchange_order_id: id}) do
      case Process.get({:fill_execs, id}) do
        nil -> {:ok, []}
        execs -> {:ok, execs}
      end
    end
  end

  defmodule BrokenExecExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(_), do: {:error, :order_not_found}

    @impl true
    def fetch_executions(_), do: {:error, :timeout}
  end

  setup do
    seed_balances()
    :ok
  end

  test "completed fill updates position but does not rewrite live balances" do
    {:ok, order} = create_live_order("live-fill-1", "JRF-fill-1")

    jpy_before = latest_balance("JPY")
    btc_before = latest_balance("BTC")

    Process.put({:fill_order, "JRF-fill-1"}, %{
      exchange_order_id: "JRF-fill-1",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :filled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.01"))

    {:ok, [%{side: :buy, size: size}]} =
      Position
      |> Ash.Query.filter(trade_mode == :live and product_code == "FX_BTC_JPY")
      |> Ash.read()

    assert Decimal.eq?(size, Decimal.new("0.01"))

    # FX live: getbalance 突合が正本。紙風の JPY↔BTC デルタは載せない
    assert Decimal.eq?(latest_balance("JPY"), jpy_before)
    assert Decimal.eq?(latest_balance("BTC"), btc_before)
  end

  test "canceled with unreflected fill applies position and terminates as cancelled" do
    {:ok, order} = create_live_order("live-fill-cancel-delta", "JRF-cancel-delta")

    Process.put({:fill_order, "JRF-cancel-delta"}, %{
      exchange_order_id: "JRF-cancel-delta",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.004"),
      average_price: Decimal.new("5000000"),
      status: :canceled
    })

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :cancelled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.004"))

    {:ok, [%{size: size}]} =
      Position
      |> Ash.Query.filter(trade_mode == :live and product_code == "FX_BTC_JPY")
      |> Ash.read()

    assert Decimal.eq?(size, Decimal.new("0.004"))
  end

  test "order_not_found with executions recovers fill then cancels remainder" do
    {:ok, order} = create_live_order("live-missing-1", "JRF-missing-1")

    Process.put({:fill_order, "JRF-missing-1"}, :missing)

    Process.put(
      {:fill_execs, "JRF-missing-1"},
      [
        %{
          id: 1,
          exchange_order_id: "JRF-missing-1",
          product_code: "FX_BTC_JPY",
          side: :buy,
          price: Decimal.new("5000000"),
          size: Decimal.new("0.003"),
          executed_at: "2026-01-01T00:00:00"
        }
      ]
    )

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :cancelled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.003"))
  end

  test "order_not_found without executions marks cancelled" do
    {:ok, order} = create_live_order("live-missing-empty", "JRF-missing-empty")
    Process.put({:fill_order, "JRF-missing-empty"}, :missing)
    Process.put({:fill_execs, "JRF-missing-empty"}, [])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :cancelled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0"))
  end

  test "order_not_found with execution fetch failure is fail-closed" do
    {:ok, order} = create_live_order("live-missing-fail", "JRF-missing-fail")

    assert {:error, :exchange_error, meta} =
             LiveFills.sync_open_orders(exchange: BrokenExecExchange)

    assert meta.cause == :order_not_found_recovery_failed

    {:ok, unchanged} = reload_order(order)
    assert unchanged.status == :pending
  end

  defp create_live_order(internal_id, exchange_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{
      internal_order_id: internal_id,
      exchange_order_id: exchange_id,
      product_code: "FX_BTC_JPY",
      side: :buy,
      status: :pending,
      order_type: :market,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      trade_mode: :live
    })
    |> Ash.create()
  end

  defp reload_order(%Order{} = order) do
    Order
    |> Ash.Query.filter(id == ^order.id)
    |> Ash.read_one()
  end

  defp latest_balance(currency) do
    {:ok, rows} =
      BalanceSnapshot
      |> Ash.Query.filter(trade_mode == :live and currency == ^currency)
      |> Ash.Query.sort(captured_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read()

    hd(rows).amount
  end

  defp seed_balances do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {currency, amount} <- [{"JPY", "1000000"}, {"BTC", "0"}] do
      {:ok, _} =
        BalanceSnapshot
        |> Ash.Changeset.for_create(:create, %{
          currency: currency,
          amount: Decimal.new(amount),
          available: Decimal.new(amount),
          captured_at: now,
          trade_mode: :live
        })
        |> Ash.create()
    end
  end
end
