defmodule Bitflyer.OrderExecutor.LiveFillsTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.DailyLossHelper

  alias Bitflyer.OrderExecutor.LiveFills
  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Order, Position}

  defmodule FillExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

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

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule BrokenExecExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

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

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule CountingFillExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      Agent.update(__MODULE__.Counter, &(&1 + 1))

      case Process.get({:fill_order, id}) do
        :missing -> {:error, :order_not_found}
        nil -> {:error, :order_not_found}
        info -> {:ok, info}
      end
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    @impl true
    def list_child_orders(_), do: {:ok, []}

    def counter_child_spec do
      %{
        id: __MODULE__.Counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.Counter]]}
      }
    end

    def fetch_count, do: Agent.get(__MODULE__.Counter, & &1)
  end

  setup do
    reset_daily_loss()
    seed_balances()
    LiveFills.clear_open_orders_sync_clock()

    previous_fills_cfg = Application.get_env(:bitflyer, LiveFills, [])
    # 既存テストは連続 sync を前提にするため既定で間引きを無効化
    Application.put_env(
      :bitflyer,
      LiveFills,
      Keyword.put(previous_fills_cfg, :min_sync_interval_ms, 0)
    )

    on_exit(fn ->
      reset_daily_loss()
      LiveFills.clear_open_orders_sync_clock()
      Application.put_env(:bitflyer, LiveFills, previous_fills_cfg)
    end)

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

    put_fill_execs("JRF-fill-1", [
      exec("JRF-fill-1", "1001", "0.01", "5000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :filled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.01"))

    {:ok, [fill]} = fills_for(order.internal_order_id)
    assert fill.exchange_execution_id == "1001"
    assert fill.order_id == order.id
    assert match?(%DateTime{}, fill.filled_at)
    assert Decimal.eq?(fill.fee, Decimal.new(0))
    assert Decimal.eq?(fill.realized_pnl, Decimal.new(0))

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

    put_fill_execs("JRF-cancel-delta", [
      exec("JRF-cancel-delta", "1002", "0.004", "5000000")
    ])

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

    put_fill_execs("JRF-missing-1", [
      exec("JRF-missing-1", "1", "0.003", "5000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, updated} = reload_order(order)
    assert updated.status == :cancelled
    assert Decimal.eq?(updated.filled_size, Decimal.new("0.003"))

    {:ok, [fill]} = fills_for(order.internal_order_id)
    assert fill.exchange_execution_id == "1"
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

  test "successive partial fills use incremental prices for position VWAP" do
    # execution 単位の価格で内部 VWAP が取引所と一致すること。
    {:ok, order} =
      create_live_order("live-partial-vwap", "JRF-partial-vwap", size: Decimal.new("0.02"))

    Process.put({:fill_order, "JRF-partial-vwap"}, %{
      exchange_order_id: "JRF-partial-vwap",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("1000000"),
      status: :active
    })

    put_fill_execs("JRF-partial-vwap", [
      exec("JRF-partial-vwap", "2001", "0.01", "1000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, after_first} = reload_order(order)
    assert after_first.status == :partially_filled
    assert Decimal.eq?(after_first.filled_size, Decimal.new("0.01"))
    assert Decimal.eq?(after_first.filled_notional, Decimal.new("10000"))

    {:ok, [pos1]} = live_positions()
    assert Decimal.eq?(pos1.size, Decimal.new("0.01"))
    assert Decimal.eq?(pos1.average_price, Decimal.new("1000000"))

    {:ok, [fill1]} = fills_for(order.internal_order_id)
    assert fill1.exchange_execution_id == "2001"
    assert Decimal.eq?(fill1.price, Decimal.new("1000000"))
    assert Decimal.eq?(fill1.size, Decimal.new("0.01"))

    Process.put({:fill_order, "JRF-partial-vwap"}, %{
      exchange_order_id: "JRF-partial-vwap",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    put_fill_execs("JRF-partial-vwap", [
      exec("JRF-partial-vwap", "2001", "0.01", "1000000"),
      exec("JRF-partial-vwap", "2002", "0.01", "2000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, after_second} = reload_order(order)
    assert after_second.status == :filled
    assert Decimal.eq?(after_second.filled_size, Decimal.new("0.02"))
    assert Decimal.eq?(after_second.filled_notional, Decimal.new("30000"))

    {:ok, [pos2]} = live_positions()
    assert Decimal.eq?(pos2.size, Decimal.new("0.02"))
    assert Decimal.eq?(pos2.average_price, Decimal.new("1500000"))

    {:ok, fills} = fills_for(order.internal_order_id)
    assert length(fills) == 2
    assert Enum.map(fills, & &1.exchange_execution_id) |> Enum.sort() == ["2001", "2002"]

    prices =
      fills
      |> Enum.map(& &1.price)
      |> Enum.sort(&(Decimal.compare(&1, &2) != :gt))

    assert Decimal.eq?(Enum.at(prices, 0), Decimal.new("1000000"))
    assert Decimal.eq?(Enum.at(prices, 1), Decimal.new("2000000"))
  end

  test "duplicate exchange_execution_id is rejected by DB unique" do
    {:ok, order} = create_live_order("live-dup-exec", "JRF-dup-exec")

    attrs = %{
      internal_order_id: order.internal_order_id,
      order_id: order.id,
      exchange_execution_id: "dup-1",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      price: Decimal.new("5000000"),
      realized_pnl: Decimal.new("0"),
      trade_mode: :live,
      filled_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    assert {:ok, _} = Fill |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()

    assert {:error, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{attrs | size: Decimal.new("0.02")})
             |> Ash.create()
  end

  test "resync with same executions is idempotent" do
    {:ok, order} = create_live_order("live-idempotent", "JRF-idempotent")

    Process.put({:fill_order, "JRF-idempotent"}, %{
      exchange_order_id: "JRF-idempotent",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-idempotent", [
      exec("JRF-idempotent", "3001", "0.01", "5000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)
    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, fills} = fills_for(order.internal_order_id)
    assert length(fills) == 1
    {:ok, [pos]} = live_positions()
    assert Decimal.eq?(pos.size, Decimal.new("0.01"))
  end

  test "legacy nil exchange_execution_id refuses additional fill delta" do
    {:ok, order} =
      create_live_order("live-legacy-nil", "JRF-legacy-nil", size: Decimal.new("0.02"))

    {:ok, order} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("50000")
      })
      |> Ash.update()

    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: order.internal_order_id,
               order_id: order.id,
               exchange_execution_id: nil,
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               price: Decimal.new("5000000"),
               realized_pnl: Decimal.new("0"),
               trade_mode: :live,
               filled_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })
             |> Ash.create()

    Process.put({:fill_order, "JRF-legacy-nil"}, %{
      exchange_order_id: "JRF-legacy-nil",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-legacy-nil", [
      exec("JRF-legacy-nil", "legacy-1", "0.01", "5000000"),
      exec("JRF-legacy-nil", "legacy-2", "0.01", "5000000")
    ])

    assert {:error, :fill_price_unavailable, %{reason: :legacy_nil_execution_id}} =
             LiveFills.sync_order(order, exchange: FillExchange)

    {:ok, reloaded} = reload_order(order)
    assert Decimal.eq?(reloaded.filled_size, Decimal.new("0.01"))
    assert reloaded.status == :partially_filled
  end

  test "legacy nil exchange_execution_id allows terminal when delta is zero" do
    {:ok, order} = create_live_order("live-legacy-term", "JRF-legacy-term")

    {:ok, order} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("50000")
      })
      |> Ash.update()

    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: order.internal_order_id,
               order_id: order.id,
               exchange_execution_id: nil,
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               price: Decimal.new("5000000"),
               realized_pnl: Decimal.new("0"),
               trade_mode: :live,
               filled_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })
             |> Ash.create()

    Process.put({:fill_order, "JRF-legacy-term"}, %{
      exchange_order_id: "JRF-legacy-term",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :canceled
    })

    put_fill_execs("JRF-legacy-term", [
      exec("JRF-legacy-term", "legacy-term-1", "0.01", "5000000")
    ])

    assert {:ok, %Order{status: :cancelled}} =
             LiveFills.sync_order(order, exchange: FillExchange)
  end

  test "duplicate execution ids in API response are collapsed before coverage" do
    {:ok, order} = create_live_order("live-dup-exec", "JRF-dup-exec")

    Process.put({:fill_order, "JRF-dup-exec"}, %{
      exchange_order_id: "JRF-dup-exec",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-dup-exec", [
      exec("JRF-dup-exec", "dup-1", "0.01", "5000000"),
      exec("JRF-dup-exec", "dup-1", "0.01", "5000000")
    ])

    assert {:ok, %Order{status: :filled}} =
             LiveFills.sync_order(order, exchange: FillExchange)

    {:ok, fills} = fills_for(order.internal_order_id)
    assert length(fills) == 1
  end

  test "filled_at prefers exchange executed_at" do
    {:ok, order} = create_live_order("live-filled-at", "JRF-filled-at")
    at = ~U[2026-01-15 01:02:03.456789Z]

    Process.put({:fill_order, "JRF-filled-at"}, %{
      exchange_order_id: "JRF-filled-at",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-filled-at", [
      exec("JRF-filled-at", "7001", "0.01", "5000000", executed_at: at)
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, [fill]} = fills_for(order.internal_order_id)
    assert DateTime.compare(fill.filled_at, at) == :eq
  end

  test "execution commission is stored as Fill.fee and subtracted from realized_pnl" do
    {:ok, order} = create_live_order("live-fee-1", "JRF-fee-1")

    Process.put({:fill_order, "JRF-fee-1"}, %{
      exchange_order_id: "JRF-fee-1",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-fee-1", [
      exec("JRF-fee-1", "8001", "0.01", "5000000", commission: Decimal.new("80"))
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, [fill]} = fills_for(order.internal_order_id)
    assert Decimal.eq?(fill.fee, Decimal.new("80"))
    assert Decimal.eq?(fill.realized_pnl, Decimal.new("-80"))

    assert :ok = DailyLoss.reload(trade_mode: :live)
    assert {:ok, loss} = DailyLoss.get(:live)
    assert Decimal.eq?(loss, Decimal.new("80"))
  end

  test "missing execution commission is fail-closed" do
    {:ok, order} = create_live_order("live-fee-missing", "JRF-fee-missing")

    Process.put({:fill_order, "JRF-fee-missing"}, %{
      exchange_order_id: "JRF-fee-missing",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-fee-missing", [
      Map.delete(exec("JRF-fee-missing", "8002", "0.01", "5000000"), :commission)
    ])

    assert {:error, :invalid_exchange_payload, %{reason: :missing_commission}} =
             LiveFills.sync_order(order, exchange: FillExchange)

    assert {:ok, []} = fills_for(order.internal_order_id)
  end

  test "negative execution commission is fail-closed" do
    {:ok, order} = create_live_order("live-fee-neg", "JRF-fee-neg")

    Process.put({:fill_order, "JRF-fee-neg"}, %{
      exchange_order_id: "JRF-fee-neg",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000"),
      status: :completed
    })

    put_fill_execs("JRF-fee-neg", [
      exec("JRF-fee-neg", "8003", "0.01", "5000000", commission: Decimal.new("-1"))
    ])

    assert {:error, :invalid_exchange_payload, %{reason: :negative_commission}} =
             LiveFills.sync_order(order, exchange: FillExchange)

    assert {:ok, []} = fills_for(order.internal_order_id)
  end

  test "partial open then partial close keeps realized_pnl and DailyLoss consistent" do
    {:ok, _buy} =
      create_live_order("live-open-partial", "JRF-open-partial", size: Decimal.new("0.02"))

    Process.put({:fill_order, "JRF-open-partial"}, %{
      exchange_order_id: "JRF-open-partial",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("1000000"),
      status: :active
    })

    put_fill_execs("JRF-open-partial", [
      exec("JRF-open-partial", "4001", "0.01", "1000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    Process.put({:fill_order, "JRF-open-partial"}, %{
      exchange_order_id: "JRF-open-partial",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    put_fill_execs("JRF-open-partial", [
      exec("JRF-open-partial", "4001", "0.01", "1000000"),
      exec("JRF-open-partial", "4002", "0.01", "2000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, [pos]} = live_positions()
    assert Decimal.eq?(pos.average_price, Decimal.new("1500000"))
    assert Decimal.eq?(pos.size, Decimal.new("0.02"))

    {:ok, sell} =
      create_live_order("live-close-partial", "JRF-close-partial",
        side: :sell,
        size: Decimal.new("0.02")
      )

    # 途中決済: 0.01 @ 1_000_000 → 実現損 = (1.5M - 1M) * 0.01 = 5000
    Process.put({:fill_order, "JRF-close-partial"}, %{
      exchange_order_id: "JRF-close-partial",
      product_code: "FX_BTC_JPY",
      side: :sell,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("1000000"),
      status: :active
    })

    put_fill_execs("JRF-close-partial", [
      exec("JRF-close-partial", "4101", "0.01", "1000000", side: :sell)
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, sell_after} = reload_order(sell)
    assert sell_after.status == :partially_filled
    assert Decimal.eq?(sell_after.filled_size, Decimal.new("0.01"))
    assert Decimal.eq?(sell_after.filled_notional, Decimal.new("10000"))

    {:ok, [pos_after]} = live_positions()
    assert Decimal.eq?(pos_after.size, Decimal.new("0.01"))
    assert Decimal.eq?(pos_after.average_price, Decimal.new("1500000"))

    {:ok, close_fills} =
      Fill
      |> Ash.Query.filter(internal_order_id == ^sell.internal_order_id)
      |> Ash.read()

    assert length(close_fills) == 1
    assert Decimal.eq?(hd(close_fills).price, Decimal.new("1000000"))
    assert Decimal.eq?(hd(close_fills).realized_pnl, Decimal.new("-5000"))

    assert {:ok, loss} = DailyLoss.get(:live)
    assert Decimal.eq?(loss, Decimal.new("5000"))

    Process.put({:fill_order, "JRF-close-partial"}, %{
      exchange_order_id: "JRF-close-partial",
      product_code: "FX_BTC_JPY",
      side: :sell,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1200000"),
      status: :completed
    })

    put_fill_execs("JRF-close-partial", [
      exec("JRF-close-partial", "4101", "0.01", "1000000", side: :sell),
      exec("JRF-close-partial", "4102", "0.01", "1400000", side: :sell)
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, sell_done} = reload_order(sell)
    assert sell_done.status == :filled
    assert Decimal.eq?(sell_done.filled_notional, Decimal.new("24000"))

    assert {:ok, []} = live_positions()

    {:ok, all_close} =
      Fill
      |> Ash.Query.filter(internal_order_id == ^sell.internal_order_id)
      |> Ash.Query.sort(filled_at: :asc)
      |> Ash.read()

    assert length(all_close) == 2
    assert Decimal.eq?(Enum.at(all_close, 1).price, Decimal.new("1400000"))
    assert Decimal.eq?(Enum.at(all_close, 1).realized_pnl, Decimal.new("-1000"))

    assert {:ok, loss_total} = DailyLoss.get(:live)
    assert Decimal.eq?(loss_total, Decimal.new("6000"))
  end

  test "filled_notional survives DB reload between successive partial fills" do
    {:ok, order} =
      create_live_order("live-restart-vwap", "JRF-restart-vwap", size: Decimal.new("0.02"))

    Process.put({:fill_order, "JRF-restart-vwap"}, %{
      exchange_order_id: "JRF-restart-vwap",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("1000000"),
      status: :active
    })

    put_fill_execs("JRF-restart-vwap", [
      exec("JRF-restart-vwap", "5001", "0.01", "1000000")
    ])

    assert :ok = LiveFills.sync_open_orders(exchange: FillExchange)

    {:ok, reloaded} = reload_order(order)
    assert Decimal.eq?(reloaded.filled_notional, Decimal.new("10000"))

    Process.put({:fill_order, "JRF-restart-vwap"}, %{
      exchange_order_id: "JRF-restart-vwap",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    put_fill_execs("JRF-restart-vwap", [
      exec("JRF-restart-vwap", "5001", "0.01", "1000000"),
      exec("JRF-restart-vwap", "5002", "0.01", "2000000")
    ])

    assert {:ok, _} = LiveFills.sync_order(reloaded, exchange: FillExchange)

    {:ok, [pos]} = live_positions()
    assert Decimal.eq?(pos.average_price, Decimal.new("1500000"))

    {:ok, done} = reload_order(order)
    assert Decimal.eq?(done.filled_notional, Decimal.new("30000"))
  end

  test "filled_size without filled_notional is fail-closed and does not book fill" do
    {:ok, order} =
      create_live_order("live-bad-baseline", "JRF-bad-baseline", size: Decimal.new("0.02"))

    # アップグレード後に notional が 0 のまま残った部分約定を模擬
    {:ok, broken, _} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("0")
      })
      |> Ash.update(return_notifications?: true)

    Process.put({:fill_order, "JRF-bad-baseline"}, %{
      exchange_order_id: "JRF-bad-baseline",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_order(broken, exchange: FillExchange)

    assert meta.reason == :inconsistent_filled_notional

    {:ok, unchanged} = reload_order(order)
    assert unchanged.status == :partially_filled
    assert Decimal.eq?(unchanged.filled_size, Decimal.new("0.01"))
    assert Decimal.eq?(unchanged.filled_notional, Decimal.new("0"))

    assert {:ok, []} = live_positions()
    assert {:ok, []} = fills_for(order.internal_order_id)
  end

  test "inconsistent baseline fails even when exchange has no new fill" do
    {:ok, order} =
      create_live_order("live-baseline-idle", "JRF-baseline-idle", size: Decimal.new("0.02"))

    {:ok, broken, _} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("0")
      })
      |> Ash.update(return_notifications?: true)

    # 新規約定なし（delta=0）。旧実装は :ok で認可前 sync を通していた
    Process.put({:fill_order, "JRF-baseline-idle"}, %{
      exchange_order_id: "JRF-baseline-idle",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.01"),
      average_price: Decimal.new("1000000"),
      status: :active
    })

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_open_orders(exchange: FillExchange)

    assert meta.reason == :inconsistent_filled_notional

    {:ok, unchanged} = reload_order(broken)
    assert unchanged.status == :partially_filled
    assert Decimal.eq?(unchanged.filled_notional, Decimal.new("0"))
  end

  test "inconsistent baseline refuses terminal cancel without booking fill" do
    {:ok, order} = create_live_order("live-baseline-cancel", "JRF-baseline-cancel")

    {:ok, broken, _} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.004"),
        filled_notional: Decimal.new("0")
      })
      |> Ash.update(return_notifications?: true)

    Process.put({:fill_order, "JRF-baseline-cancel"}, %{
      exchange_order_id: "JRF-baseline-cancel",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.004"),
      average_price: Decimal.new("5000000"),
      status: :canceled
    })

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_order(broken, exchange: FillExchange)

    assert meta.reason == :inconsistent_filled_notional

    {:ok, unchanged} = reload_order(order)
    assert unchanged.status == :partially_filled
    refute unchanged.status == :cancelled
  end

  test "execution list size mismatch is fail-closed" do
    {:ok, order} =
      create_live_order("live-exec-mismatch", "JRF-exec-mismatch", size: Decimal.new("0.02"))

    Process.put({:fill_order, "JRF-exec-mismatch"}, %{
      exchange_order_id: "JRF-exec-mismatch",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    # remote_filled=0.02 なのに execution 合計 0.01
    put_fill_execs("JRF-exec-mismatch", [
      exec("JRF-exec-mismatch", "6001", "0.01", "1500000")
    ])

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_order(order, exchange: FillExchange)

    assert meta.reason == :execution_size_mismatch
    assert {:ok, []} = live_positions()
  end

  test "missing executions when remote filled advances is fail-closed" do
    {:ok, order} =
      create_live_order("live-exec-empty", "JRF-exec-empty", size: Decimal.new("0.02"))

    {:ok, primed, _} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("10000")
      })
      |> Ash.update(return_notifications?: true)

    Process.put({:fill_order, "JRF-exec-empty"}, %{
      exchange_order_id: "JRF-exec-empty",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      filled_size: Decimal.new("0.02"),
      average_price: Decimal.new("1500000"),
      status: :completed
    })

    put_fill_execs("JRF-exec-empty", [])

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_order(primed, exchange: FillExchange)

    assert meta.reason == :execution_size_mismatch
  end

  test "terminal path refuses filled_size change without matching local fill" do
    {:ok, order} = create_live_order("live-term-mismatch", "JRF-term-mismatch")

    # ローカルが取引所より先に進んでいる（size 不一致）終端化は notional 対を壊すので拒否
    {:ok, ahead, _} =
      order
      |> Ash.Changeset.for_update(:update, %{
        status: :partially_filled,
        filled_size: Decimal.new("0.01"),
        filled_notional: Decimal.new("50000")
      })
      |> Ash.update(return_notifications?: true)

    Process.put({:fill_order, "JRF-term-mismatch"}, %{
      exchange_order_id: "JRF-term-mismatch",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0.004"),
      average_price: Decimal.new("5000000"),
      status: :canceled
    })

    assert {:error, :fill_price_unavailable, meta} =
             LiveFills.sync_order(ahead, exchange: FillExchange)

    assert meta.reason == :terminal_filled_size_mismatch
  end

  test "sync_open_orders skips within min interval unless force" do
    previous = Application.get_env(:bitflyer, LiveFills, [])
    Application.put_env(:bitflyer, LiveFills, Keyword.put(previous, :min_sync_interval_ms, 1_000))
    LiveFills.clear_open_orders_sync_clock()
    start_supervised!(CountingFillExchange.counter_child_spec())

    {:ok, _} = create_live_order("live-min-interval", "JRF-min-interval")

    Process.put({:fill_order, "JRF-min-interval"}, %{
      exchange_order_id: "JRF-min-interval",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      average_price: nil,
      status: :active
    })

    assert :ok =
             LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 0)

    assert CountingFillExchange.fetch_count() == 1

    assert :ok =
             LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 500)

    assert CountingFillExchange.fetch_count() == 1

    assert :ok =
             LiveFills.sync_open_orders(
               exchange: CountingFillExchange,
               now: 500,
               force: true
             )

    assert CountingFillExchange.fetch_count() == 2

    assert :ok =
             LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 1_500)

    assert CountingFillExchange.fetch_count() == 3
  end

  test "sync_open_orders advances clock on failure to avoid REST hammering" do
    previous = Application.get_env(:bitflyer, LiveFills, [])
    Application.put_env(:bitflyer, LiveFills, Keyword.put(previous, :min_sync_interval_ms, 1_000))
    LiveFills.clear_open_orders_sync_clock()
    start_supervised!(CountingFillExchange.counter_child_spec())

    {:ok, _} = create_live_order("live-fail-clock", "JRF-fail-clock")

    # BrokenExecExchange は fetch_order not_found → executions timeout で fail-closed
    assert {:error, :exchange_error, _} =
             LiveFills.sync_open_orders(exchange: BrokenExecExchange, now: 0)

    # 失敗後も時計が進むため、間隔内の再試行は REST しない
    assert :ok =
             LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 100)

    assert CountingFillExchange.fetch_count() == 0

    assert :ok =
             LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 1_000)

    assert CountingFillExchange.fetch_count() == 1
  end

  test "concurrent sync_open_orders does not double-fetch under lock" do
    previous = Application.get_env(:bitflyer, LiveFills, [])
    Application.put_env(:bitflyer, LiveFills, Keyword.put(previous, :min_sync_interval_ms, 1_000))
    LiveFills.clear_open_orders_sync_clock()
    start_supervised!(CountingFillExchange.counter_child_spec())

    {:ok, _} = create_live_order("live-concurrent-sync", "JRF-concurrent-sync")

    order_info = %{
      exchange_order_id: "JRF-concurrent-sync",
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      average_price: nil,
      status: :active
    }

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Process.put({:fill_order, "JRF-concurrent-sync"}, order_info)
          LiveFills.sync_open_orders(exchange: CountingFillExchange, now: 0)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, &(&1 == :ok))
    # Gate 直列化により実 fetch は 1 回（他は間引き :ok）
    assert CountingFillExchange.fetch_count() == 1
  end

  defp create_live_order(internal_id, exchange_id, opts \\ []) do
    Order
    |> Ash.Changeset.for_create(:create, %{
      internal_order_id: internal_id,
      exchange_order_id: exchange_id,
      product_code: "FX_BTC_JPY",
      side: Keyword.get(opts, :side, :buy),
      status: :pending,
      order_type: :market,
      size: Keyword.get(opts, :size, Decimal.new("0.01")),
      filled_size: Decimal.new("0"),
      filled_notional: Decimal.new("0"),
      trade_mode: :live
    })
    |> Ash.create()
  end

  defp put_fill_execs(exchange_order_id, execs) when is_list(execs) do
    Process.put({:fill_execs, exchange_order_id}, execs)
  end

  defp exec(exchange_order_id, id, size, price, opts \\ []) do
    %{
      id: id,
      exchange_order_id: exchange_order_id,
      product_code: "FX_BTC_JPY",
      side: Keyword.get(opts, :side, :buy),
      price: Decimal.new(price),
      size: Decimal.new(size),
      commission: Keyword.get(opts, :commission, Decimal.new(0)),
      # DailyLoss 窓に入るよう壁時計「今」を既定にする（取引所時刻優先の回帰は別テスト）
      executed_at:
        Keyword.get_lazy(opts, :executed_at, fn ->
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        end)
    }
  end

  defp reload_order(%Order{} = order) do
    Order
    |> Ash.Query.filter(id == ^order.id)
    |> Ash.read_one()
  end

  defp live_positions do
    Position
    |> Ash.Query.filter(trade_mode == :live and product_code == "FX_BTC_JPY")
    |> Ash.read()
  end

  defp fills_for(internal_order_id) do
    Fill
    |> Ash.Query.filter(internal_order_id == ^internal_order_id)
    |> Ash.Query.sort(filled_at: :asc)
    |> Ash.read()
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
