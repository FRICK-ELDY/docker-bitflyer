defmodule Bitflyer.OrderExecutor.PositionsTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.DailyLossHelper

  alias Bitflyer.OrderExecutor.Positions
  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.{Fill, Order, Position}

  setup do
    reset_daily_loss()

    on_exit(fn ->
      reset_daily_loss()
    end)

    :ok
  end

  test "closing a long at a loss records Fill realized_pnl and DailyLoss.reload sees it" do
    {:ok, open_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-open-1",
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, %{realized_pnl: open_pnl}} =
             Positions.apply_fill(open_order, Decimal.new("5000000"))

    assert Decimal.eq?(open_pnl, Decimal.new(0))
    assert :ok = DailyLoss.reload(trade_mode: :paper)

    {:ok, close_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-close-1",
        product_code: "FX_BTC_JPY",
        side: :sell,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("4000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    # 0.01 * (4000000 - 5000000) = -10000
    assert {:ok, _, %{realized_pnl: realized}} =
             Positions.apply_fill(close_order, Decimal.new("4000000"))

    assert Decimal.eq?(realized, Decimal.new("-10000"))
    assert :ok = DailyLoss.reload(trade_mode: :paper)

    assert {:ok, loss} = DailyLoss.get(:paper)
    assert Decimal.eq?(loss, Decimal.new("10000"))

    assert {:ok, fills} =
             Fill
             |> Ash.Query.filter(internal_order_id == "pos-close-1")
             |> Ash.read()

    assert length(fills) == 1
    assert Decimal.eq?(hd(fills).realized_pnl, Decimal.new("-10000"))

    assert {:ok, nil} =
             Position
             |> Ash.Query.filter(product_code == "FX_BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()
  end

  test "scale-in fee is realized_pnl and DailyLoss.reload sees the same net" do
    {:ok, open_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-fee-open-1",
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, %{realized_pnl: open_pnl}} =
             Positions.apply_fill(open_order, Decimal.new("5000000"), fee: Decimal.new("10"))

    assert Decimal.eq?(open_pnl, Decimal.new("-10"))

    {:ok, add_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-fee-add-1",
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, %{realized_pnl: add_pnl}} =
             Positions.apply_fill(add_order, Decimal.new("5000000"), fee: Decimal.new("20"))

    assert Decimal.eq?(add_pnl, Decimal.new("-20"))
    assert :ok = DailyLoss.reload(trade_mode: :paper)
    assert {:ok, loss} = DailyLoss.get(:paper)
    assert Decimal.eq?(loss, Decimal.new("30"))

    {:ok, [open_fill]} =
      Fill
      |> Ash.Query.filter(internal_order_id == "pos-fee-open-1")
      |> Ash.read()

    {:ok, [add_fill]} =
      Fill
      |> Ash.Query.filter(internal_order_id == "pos-fee-add-1")
      |> Ash.read()

    assert Decimal.eq?(open_fill.fee, Decimal.new("10"))
    assert Decimal.eq?(open_fill.realized_pnl, Decimal.new("-10"))
    assert Decimal.eq?(add_fill.fee, Decimal.new("20"))
    assert Decimal.eq?(add_fill.realized_pnl, Decimal.new("-20"))
  end

  test "close subtracts fee from gross realized_pnl" do
    {:ok, open_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-fee-close-open",
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, _} = Positions.apply_fill(open_order, Decimal.new("5000000"))

    {:ok, close_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-fee-close-1",
        product_code: "FX_BTC_JPY",
        side: :sell,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("4000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    # gross -10000, fee 50 → net -10050
    assert {:ok, _, %{realized_pnl: realized}} =
             Positions.apply_fill(close_order, Decimal.new("4000000"), fee: Decimal.new("50"))

    assert Decimal.eq?(realized, Decimal.new("-10050"))
    assert :ok = DailyLoss.reload(trade_mode: :paper)
    assert {:ok, loss} = DailyLoss.get(:paper)
    assert Decimal.eq?(loss, Decimal.new("10050"))

    {:ok, [fill]} =
      Fill
      |> Ash.Query.filter(internal_order_id == "pos-fee-close-1")
      |> Ash.read()

    assert Decimal.eq?(fill.fee, Decimal.new("50"))
    assert fill.fee_currency == "JPY"
    assert Decimal.eq?(fill.realized_pnl, Decimal.new("-10050"))
  end

  test "BTC_JPY base fee reduces position size and marks realized in JPY" do
    {:ok, open_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-fee-open",
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, %{realized_pnl: open_pnl}} =
             Positions.apply_fill(open_order, Decimal.new("5000000"), fee: Decimal.new("0.00001"))

    # fee 0.00001 BTC × 5_000_000 = 50 JPY
    assert Decimal.eq?(open_pnl, Decimal.new("-50"))

    assert {:ok, %Position{size: pos_size, average_price: avg}} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert Decimal.eq?(pos_size, Decimal.new("0.00999"))
    assert Decimal.eq?(avg, Decimal.new("5000000"))

    {:ok, [fill]} =
      Fill
      |> Ash.Query.filter(internal_order_id == "pos-btc-fee-open")
      |> Ash.read()

    assert Decimal.eq?(fill.fee, Decimal.new("0.00001"))
    assert fill.fee_currency == "BTC"
    assert Decimal.eq?(fill.size, Decimal.new("0.01"))
    assert Decimal.eq?(fill.realized_pnl, Decimal.new("-50"))
  end

  test "base fee buy covering equal short leaves residual short of fee" do
    {:ok, short_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-short-open",
        product_code: "BTC_JPY",
        side: :sell,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, _} = Positions.apply_fill(short_order, Decimal.new("5000000"))

    {:ok, cover} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-short-cover",
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    # held = 0.01 − 0.00001。exec_size で潰すとフラットになり腐敗する。
    assert {:ok, _, %{realized_pnl: realized}} =
             Positions.apply_fill(cover, Decimal.new("5000000"), fee: Decimal.new("0.00001"))

    assert Decimal.eq?(realized, Decimal.new("-50"))

    assert {:ok, %Position{side: :sell, size: residual}} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert Decimal.eq?(residual, Decimal.new("0.00001"))
  end

  test "base fee buy partially covering short reduces by held not exec_size" do
    {:ok, short_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-short-partial-open",
        product_code: "BTC_JPY",
        side: :sell,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, _} = Positions.apply_fill(short_order, Decimal.new("5000000"))

    {:ok, cover} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-short-partial-cover",
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.005"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.005"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, _} =
             Positions.apply_fill(cover, Decimal.new("5000000"), fee: Decimal.new("0.000005"))

    assert {:ok, %Position{side: :sell, size: residual}} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    # 0.01 − (0.005 − 0.000005) = 0.005005
    assert Decimal.eq?(residual, Decimal.new("0.005005"))
  end

  test "base fee buy flipping short opens long remainder of held minus short" do
    {:ok, short_order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-flip-short",
        product_code: "BTC_JPY",
        side: :sell,
        size: Decimal.new("0.005"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.005"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, _} = Positions.apply_fill(short_order, Decimal.new("5000000"))

    {:ok, flip} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "pos-btc-flip-buy",
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        order_type: :market,
        price: Decimal.new("5000000"),
        status: :filled,
        filled_size: Decimal.new("0.01"),
        trade_mode: :paper
      })
      |> Ash.create()

    assert {:ok, _, %{realized_pnl: realized}} =
             Positions.apply_fill(flip, Decimal.new("5000000"), fee: Decimal.new("0.00001"))

    assert Decimal.eq?(realized, Decimal.new("-50"))

    assert {:ok, %Position{side: :buy, size: remainder}} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    # held 0.00999 − short 0.005 = 0.00499
    assert Decimal.eq?(remainder, Decimal.new("0.00499"))
  end
end
