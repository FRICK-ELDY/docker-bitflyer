defmodule Bitflyer.Observe.ExposureTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Observe.Exposure
  alias Bitflyer.Readiness
  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.System
  alias Bitflyer.Trading.{Order, Position}

  setup do
    reset_readiness()
    reset_daily_loss()
    reset_market_data_cache()
    reset_balance_cache()

    on_exit(fn ->
      reset_readiness()
      reset_daily_loss()
      reset_market_data_cache()
      reset_balance_cache()
    end)

    :ok
  end

  test "empty book has no positions or open orders and zero pnl" do
    snap = Exposure.snapshot(trade_mode: :dry_run)

    assert snap.positions == []
    assert snap.positions_error == nil
    assert snap.open_orders == []
    assert snap.open_order_count == 0
    assert snap.oldest_open_age_ms == nil
    assert snap.halt_reason == nil
    assert snap.halt_steps == []
    assert snap.pnl.status == :ok
    assert Decimal.eq?(snap.pnl.realized_net, Decimal.new(0))
    assert Decimal.eq?(snap.pnl.unrealized, Decimal.new(0))
    assert Decimal.eq?(snap.pnl.equity_pnl, Decimal.new(0))
    assert System.exposure(trade_mode: :dry_run).positions == []
  end

  test "lists current-mode positions and working open orders" do
    {:ok, _} = create_position(:buy, "0.02", "5000000", :dry_run)
    {:ok, _} = create_position(:sell, "0.01", "5100000", :paper)

    {:ok, _} = create_order("exp-pending-1", :pending, :dry_run)
    {:ok, _} = create_order("exp-partial-1", :partially_filled, :dry_run)
    {:ok, _} = create_order("exp-unknown-1", :submission_unknown, :dry_run)
    {:ok, _} = create_order("exp-filled-1", :filled, :dry_run)
    {:ok, _} = create_order("exp-paper-1", :pending, :paper)

    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("4900000")) == :ok
    seed_balance_cache!(:dry_run, %{"JPY" => "1000000", "BTC" => "0.25"})

    snap = Exposure.snapshot(trade_mode: :dry_run)

    assert [position] = snap.positions
    assert position.product_code == "BTC_JPY"
    assert position.side == :buy
    assert Decimal.eq?(position.size, Decimal.new("0.02"))
    assert Decimal.eq?(position.mark, Decimal.new("4900000"))
    assert Decimal.eq?(position.unrealized, Decimal.new("-2000"))

    ids = Enum.map(snap.open_orders, & &1.internal_order_id)
    assert ids == ["exp-pending-1", "exp-partial-1", "exp-unknown-1"]
    assert snap.open_order_count == 3
    assert is_integer(snap.oldest_open_age_ms)

    partial = Enum.find(snap.open_orders, &(&1.internal_order_id == "exp-partial-1"))
    assert partial.status == :partially_filled
    assert partial.side == :buy
    assert partial.exchange_order_id == "JRF-exp-partial-1"
    assert Decimal.eq?(partial.price, Decimal.new("5000000"))
    assert Decimal.eq?(partial.remaining_size, Decimal.new("0.006"))

    unknown = Enum.find(snap.open_orders, &(&1.internal_order_id == "exp-unknown-1"))
    assert unknown.status == :submission_unknown
    assert Decimal.eq?(unknown.remaining_size, Decimal.new("0.01"))

    jpy = Enum.find(snap.balances, &(&1.currency == "JPY"))
    btc = Enum.find(snap.balances, &(&1.currency == "BTC"))
    assert Decimal.eq?(jpy.amount, Decimal.new("1000000"))
    assert Decimal.eq?(btc.amount, Decimal.new("0.25"))

    assert snap.pnl.status == :ok
    assert Decimal.eq?(snap.pnl.unrealized, Decimal.new("-2000"))
  end

  test "limits open order rows and counts the rest" do
    for n <- 1..21 do
      {:ok, _} = create_order("exp-limit-#{n}", :pending, :dry_run)
    end

    snap = Exposure.snapshot(trade_mode: :dry_run)

    assert snap.open_order_count == 21
    assert length(snap.open_orders) == 20
    assert hd(snap.open_orders).internal_order_id == "exp-limit-1"
  end

  test "stale mark keeps positions and marks pnl stale" do
    {:ok, _} = create_position(:buy, "0.01", "5000000", :dry_run)

    snap = Exposure.snapshot(trade_mode: :dry_run)

    assert [%{product_code: "BTC_JPY"}] = snap.positions
    assert snap.pnl.status == :stale
    assert snap.pnl.unrealized == nil
    assert Decimal.eq?(snap.pnl.realized_net, Decimal.new(0))
  end

  test "includes halt recovery steps when halted" do
    assert Readiness.halt(:submission_unknown) == :ok

    snap = Exposure.snapshot(trade_mode: :dry_run)

    assert snap.halt_reason == :submission_unknown
    assert :recover_submission in snap.halt_steps
  end

  test "observe does not record peak or halt on drawdown" do
    assert Readiness.mark_ready() == :ok
    {:ok, _} = create_position(:buy, "0.1", "5000000", :dry_run)
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("1000000")) == :ok

    snap =
      Exposure.snapshot(
        trade_mode: :dry_run,
        limits: %{max_daily_loss: "100000", max_daily_drawdown: "100000"}
      )

    assert snap.pnl.status == :ok
    assert Decimal.gt?(snap.pnl.drawdown, Decimal.new("100000"))
    assert Readiness.get() == :ready
    assert {:ok, %{peak: peak}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(peak, Decimal.new(0))
  end

  test "reports daily loss headroom from DailyLoss" do
    assert :ok = DailyLoss.seed_loss(:dry_run, Decimal.new("25000"))
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("5000000")) == :ok

    snap =
      Exposure.snapshot(
        trade_mode: :dry_run,
        limits: %{max_daily_loss: "100000", max_daily_drawdown: "80000"}
      )

    assert Decimal.eq?(snap.pnl.realized_loss, Decimal.new("25000"))
    assert Decimal.eq?(snap.pnl.loss_headroom, Decimal.new("75000"))
    assert Decimal.eq?(snap.pnl.max_daily_loss, Decimal.new("100000"))
  end

  defp create_position(side, size, avg, trade_mode) do
    Position
    |> Ash.Changeset.for_create(:create, %{
      product_code: "BTC_JPY",
      side: side,
      size: Decimal.new(size),
      average_price: Decimal.new(avg),
      trade_mode: trade_mode
    })
    |> Ash.create()
  end

  defp create_order(internal_order_id, status, trade_mode) do
    attrs = %{
      internal_order_id: internal_order_id,
      exchange_order_id: "JRF-#{internal_order_id}",
      product_code: "BTC_JPY",
      side: :buy,
      status: status,
      order_type: :limit,
      price: Decimal.new("5000000"),
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      trade_mode: trade_mode
    }

    attrs =
      cond do
        status == :filled ->
          Map.merge(attrs, %{
            filled_size: Decimal.new("0.01"),
            filled_notional: Decimal.new("50000")
          })

        status == :partially_filled ->
          Map.merge(attrs, %{
            filled_size: Decimal.new("0.004"),
            filled_notional: Decimal.new("20000")
          })

        true ->
          attrs
      end

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create()
  end
end
