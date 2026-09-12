defmodule Bitflyer.Regression.LiveBalanceAdvanceTest do
  @moduledoc """
  P0 #2 / P1 #4 縦貫通回帰。

  Fill を Ash で直接作らず、`Exchange.Client` ハーネスだけで
  発注 → 部分約定 2 回 → 残高変動 → 定期突合 → Ready → 再起動 → Ready
  を固定する。tip が前進しないと再突合で基準が古いまま残る。
  非 0 `commission` は取引所残高から引き、Fill / DailyLoss / Equity と同じ net になる。
  """

  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.FailureRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.OrderExecutor.LiveFills
  alias Bitflyer.Readiness
  alias Bitflyer.Risk.{DailyLoss, Equity}
  alias Bitflyer.Startup.Reconciler
  alias Bitflyer.System
  alias Bitflyer.TestSupport.LiveExchangeHarness
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Order, Position, RiskState}

  @product "BTC_JPY"
  @market_key {:ticker, @product}
  @jpy Decimal.new("1000000")
  @btc Decimal.new("0.5")
  @price Decimal.new("5000000")
  @size Decimal.new("0.01")
  @partial Decimal.new("0.005")
  @after_first_jpy Decimal.new("975000")
  @after_first_btc Decimal.new("0.505")
  @after_buy_jpy Decimal.new("950000")
  @after_buy_btc Decimal.new("0.51")
  @fee_partial Decimal.new("40")
  @fee_total Decimal.new("80")
  @after_first_buy_fee_jpy Decimal.new("974960")
  @after_buy_fee_jpy Decimal.new("949920")
  @after_roundtrip_fee_jpy Decimal.new("999840")

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_failure_rate()
    reset_daily_loss()
    reset_balance_cache()
    clear_default_risk_state()
    LiveFills.clear_open_orders_sync_clock()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)
    previous_fills_cfg = Application.get_env(:bitflyer, LiveFills, [])
    previous_reconcile = Application.get_env(:bitflyer, Bitflyer.Startup.Reconcile, [])

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    Application.put_env(:bitflyer, :exchange_client, LiveExchangeHarness)

    Application.put_env(
      :bitflyer,
      LiveFills,
      Keyword.put(previous_fills_cfg, :min_sync_interval_ms, 0)
    )

    # 記録済み fee は 20bps に頼らない。未記録 Fill が混ざるとこのファイルは halt する。
    Application.put_env(
      :bitflyer,
      Bitflyer.Startup.Reconcile,
      Keyword.put(previous_reconcile, :balance_fee_tolerance_bps, "0")
    )

    start_supervised!(LiveExchangeHarness)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_failure_rate()
      reset_daily_loss()
      reset_balance_cache()
      clear_default_risk_state()
      LiveFills.clear_open_orders_sync_clock()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)
      Application.put_env(:bitflyer, LiveFills, previous_fills_cfg)
      Application.put_env(:bitflyer, Bitflyer.Startup.Reconcile, previous_reconcile)
    end)

    :ok
  end

  test "place then two partial fills keep ready after periodic reconcile and restart" do
    seed_live_balance_baseline!()
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key, @price)
    seed_balance_cache!(:live, %{"JPY" => @jpy, "BTC" => @btc})

    order = submit_live!("p0-2-partials")
    assert order.exchange_order_id == "ex-p0-2-partials"

    apply_partial!(order, "exec-p0-2-1")

    assert {:ok, %Order{status: :partially_filled} = partial} =
             LiveFills.sync_order(order, exchange: LiveExchangeHarness)

    assert Decimal.eq?(partial.filled_size, @partial)
    assert_fills!("p0-2-partials", ["exec-p0-2-1"], @partial)
    assert_spot_position!(@partial)

    # 1 本目直後の突合でも tip が進み、未約定残と open order が揃う
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_tips!(@after_first_jpy, @after_first_btc)

    apply_partial!(order, "exec-p0-2-2")
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready

    assert {:ok, %Order{status: :filled} = filled} = reload_order(order)
    assert Decimal.eq?(filled.filled_size, @size)
    assert_fills!("p0-2-partials", ["exec-p0-2-1", "exec-p0-2-2"], @size)
    assert_spot_position!(@size)
    assert_tips!(@after_buy_jpy, @after_buy_btc)
    assert_exchange_balances!(@after_buy_jpy, @after_buy_btc)

    # 再起動相当: Readiness だけでなく BalanceCache / DailyLoss の ETS も捨てる
    simulate_process_restart!()
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_tips!(@after_buy_jpy, @after_buy_btc)

    # 売りは DB 建玉を認可が読む（positions 注入なし）
    sell = submit_live!("p0-2-sell", %{side: :sell})
    apply_partial!(sell, "exec-p0-2-s1")

    assert {:ok, %Order{status: :partially_filled}} =
             LiveFills.sync_order(sell, exchange: LiveExchangeHarness)

    assert_fills!("p0-2-sell", ["exec-p0-2-s1"], @partial)
    assert_spot_position!(@partial)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_tips!(@after_first_jpy, @after_first_btc)

    apply_partial!(sell, "exec-p0-2-s2")
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_fills!("p0-2-sell", ["exec-p0-2-s1", "exec-p0-2-s2"], @size)
    assert_no_spot_position!()
    assert_tips!(@jpy, @btc)
  end

  test "unexplained deposit on the harness after fills halts" do
    seed_live_balance_baseline!()
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key, @price)
    seed_balance_cache!(:live, %{"JPY" => @jpy, "BTC" => @btc})

    order = submit_live!("p0-2-deposit")
    apply_partial!(order, "exec-p0-2-d1")
    assert {:ok, _} = LiveFills.sync_order(order, exchange: LiveExchangeHarness)
    apply_partial!(order, "exec-p0-2-d2")

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready

    LiveExchangeHarness.credit("JPY", Decimal.new("1"))

    assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"}} =
             Bitflyer.Startup.Reconcile.run(trade_mode: :live, exchange: LiveExchangeHarness)

    assert {:error, :reconcile_mismatch} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :reconcile_mismatch}
  end

  test "completed buy on the harness keeps another buy hold" do
    {:ok, %{exchange_order_id: first}} = place_on_harness("hold-a")
    {:ok, %{exchange_order_id: second}} = place_on_harness("hold-b")

    assert :ok =
             LiveExchangeHarness.apply_fill(first, %{
               id: "exec-hold-a",
               size: @size,
               price: @price
             })

    jpy = Enum.find(LiveExchangeHarness.balances(), &(&1.currency == "JPY"))
    assert Decimal.eq?(jpy.amount, @after_buy_jpy)
    assert Decimal.eq?(jpy.available, Decimal.new("900000"))

    {:ok, snapshot} = LiveExchangeHarness.fetch_reconcile_snapshot()
    assert Enum.map(snapshot.open_orders, & &1.exchange_order_id) == [second]
  end

  test "apply_fill deducts commission from quote amount and available" do
    {:ok, %{exchange_order_id: id}} = place_on_harness("fee-quote")

    assert :ok =
             LiveExchangeHarness.apply_fill(id, %{
               id: "exec-fee-quote",
               size: @size,
               price: @price,
               commission: @fee_total
             })

    jpy = Enum.find(LiveExchangeHarness.balances(), &(&1.currency == "JPY"))
    assert Decimal.eq?(jpy.amount, @after_buy_fee_jpy)
    assert Decimal.eq?(jpy.available, @after_buy_fee_jpy)
  end

  test "non-zero commission keeps ready and DailyLoss / Equity net after restart" do
    seed_live_balance_baseline!()
    assert Readiness.mark_ready() == :ok
    put_fresh_ticker(@market_key, @price)
    seed_balance_cache!(:live, %{"JPY" => @jpy, "BTC" => @btc})

    buy = submit_live!("p1-4-fee-buy")
    apply_partial!(buy, "exec-p1-4-b1", @fee_partial)

    assert {:ok, %Order{status: :partially_filled}} =
             LiveFills.sync_order(buy, exchange: LiveExchangeHarness)

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_tips!(@after_first_buy_fee_jpy, @after_first_btc)
    assert_net!(Decimal.new("-40"), Decimal.new("40"))

    apply_partial!(buy, "exec-p1-4-b2", @fee_partial)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_fills!("p1-4-fee-buy", ["exec-p1-4-b1", "exec-p1-4-b2"], @size)
    assert_fill_fees!("p1-4-fee-buy", @fee_total)
    assert_spot_position!(@size)
    assert_tips!(@after_buy_fee_jpy, @after_buy_btc)
    assert_exchange_balances!(@after_buy_fee_jpy, @after_buy_btc)
    assert_net!(Decimal.negate(@fee_total), @fee_total)

    simulate_process_restart!()
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_tips!(@after_buy_fee_jpy, @after_buy_btc)
    assert_net!(Decimal.negate(@fee_total), @fee_total)

    sell = submit_live!("p1-4-fee-sell", %{side: :sell})
    apply_partial!(sell, "exec-p1-4-s1", @fee_partial)

    assert {:ok, %Order{status: :partially_filled}} =
             LiveFills.sync_order(sell, exchange: LiveExchangeHarness)

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready

    apply_partial!(sell, "exec-p1-4-s2", @fee_partial)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
    assert_fills!("p1-4-fee-sell", ["exec-p1-4-s1", "exec-p1-4-s2"], @size)
    assert_fill_fees!("p1-4-fee-sell", @fee_total)
    assert_no_spot_position!()
    assert_tips!(@after_roundtrip_fee_jpy, @btc)
    assert_exchange_balances!(@after_roundtrip_fee_jpy, @btc)
    assert_net!(Decimal.new("-160"), Decimal.new("160"))
  end

  defp submit_live!(internal_order_id, overrides \\ %{}) do
    assert {:ok, %Order{status: :pending} = order} =
             System.submit_order(command(internal_order_id, overrides), trade_mode: :live)

    order
  end

  defp apply_partial!(%Order{exchange_order_id: ex_id}, exec_id, commission \\ Decimal.new(0)) do
    assert :ok =
             LiveExchangeHarness.apply_fill(ex_id, %{
               id: exec_id,
               size: @partial,
               price: @price,
               commission: commission
             })
  end

  defp place_on_harness(internal_order_id) do
    LiveExchangeHarness.place_order(%{
      product_code: @product,
      side: :buy,
      size: @size,
      order_type: :limit,
      price: @price,
      internal_order_id: internal_order_id
    })
  end

  defp command(internal_order_id, overrides) do
    Map.merge(
      %{
        internal_order_id: internal_order_id,
        product_code: @product,
        side: :buy,
        size: @size,
        price: @price,
        market_key: @market_key,
        order_type: :limit
      },
      overrides
    )
  end

  defp simulate_process_restart! do
    reset_balance_cache()
    reset_daily_loss()
    reset_order_rate()
    reset_failure_rate()
    reset_market_data_cache()
    LiveFills.clear_open_orders_sync_clock()
    put_fresh_ticker(@market_key, @price)
    assert Readiness.mark_not_ready() == :ok
  end

  defp seed_live_balance_baseline! do
    captured_at =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:microsecond)

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

    :ok
  end

  defp assert_tips!(jpy, btc) do
    assert {:ok, tips} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "JPY")).amount, jpy)
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "BTC")).amount, btc)
  end

  defp assert_exchange_balances!(jpy, btc) do
    balances = LiveExchangeHarness.balances()
    assert Decimal.eq?(Enum.find(balances, &(&1.currency == "JPY")).amount, jpy)
    assert Decimal.eq?(Enum.find(balances, &(&1.currency == "BTC")).amount, btc)
  end

  defp assert_net!(realized_net, loss) do
    assert {:ok, actual_loss} = DailyLoss.get(:live)
    assert Decimal.eq?(actual_loss, loss)

    assert {:ok, eq} = Equity.snapshot(trade_mode: :live)
    assert Decimal.eq?(eq.realized_net, realized_net)
    assert Decimal.eq?(eq.unrealized, Decimal.new(0))
    assert Decimal.eq?(eq.equity_pnl, realized_net)
  end

  defp assert_fill_fees!(internal_order_id, total_fee) do
    assert {:ok, fills} = fills_for(internal_order_id)

    summed =
      Enum.reduce(fills, Decimal.new(0), fn fill, acc ->
        Decimal.add(acc, fill.fee || Decimal.new(0))
      end)

    assert Decimal.eq?(summed, total_fee)

    Enum.each(fills, fn fill ->
      assert Decimal.eq?(fill.realized_pnl, Decimal.negate(fill.fee))
    end)
  end

  defp assert_fills!(internal_order_id, exec_ids, total_size) do
    assert {:ok, fills} = fills_for(internal_order_id)
    assert length(fills) == length(exec_ids)
    assert Enum.sort(Enum.map(fills, & &1.exchange_execution_id)) == Enum.sort(exec_ids)

    summed =
      Enum.reduce(fills, Decimal.new(0), fn fill, acc -> Decimal.add(acc, fill.size) end)

    assert Decimal.eq?(summed, total_size)
  end

  defp assert_spot_position!(size) do
    assert {:ok, [%Position{side: :buy, size: actual}]} =
             Position
             |> Ash.Query.filter(trade_mode == :live and product_code == ^@product)
             |> Ash.read()

    assert Decimal.eq?(actual, size)
  end

  defp assert_no_spot_position! do
    assert {:ok, []} =
             Position
             |> Ash.Query.filter(trade_mode == :live and product_code == ^@product)
             |> Ash.read()
  end

  defp fills_for(internal_order_id) do
    Fill
    |> Ash.Query.filter(internal_order_id == ^internal_order_id)
    |> Ash.read()
  end

  defp reload_order(%Order{id: id}) do
    Ash.get(Order, id)
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} -> :ok
      {:ok, risk} -> Ash.destroy!(risk)
      {:error, _} -> :ok
    end
  end
end
