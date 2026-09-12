defmodule Bitflyer.Risk.EquityTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Risk.{DailyLoss, Equity}
  alias Bitflyer.Startup.Reconciler
  alias Bitflyer.Trading.{Position, RiskState}

  setup do
    reset_readiness()
    reset_daily_loss()
    reset_market_data_cache()

    on_exit(fn ->
      reset_readiness()
      reset_daily_loss()
      reset_market_data_cache()
    end)

    :ok
  end

  test "snapshot marks long position unrealized against LTP" do
    {:ok, position} = create_long("0.02", "5000000")
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("4000000")) == :ok

    assert {:ok, snap} =
             Equity.snapshot(
               trade_mode: :dry_run,
               positions: [position],
               limits: %{max_daily_drawdown: "100000"}
             )

    assert Decimal.eq?(snap.unrealized, Decimal.new("-20000"))
    assert Decimal.eq?(snap.drawdown, Decimal.new("20000"))
  end

  test "snapshot is stale when open position has no fresh mark" do
    {:ok, position} = create_long("0.01", "5000000")

    assert {:error, :stale, %{reason: :mark_price_unavailable}} =
             Equity.snapshot(trade_mode: :dry_run, positions: [position])
  end

  test "enforce opens circuit when drawdown exceeds max" do
    assert Readiness.mark_ready() == :ok
    {:ok, position} = create_long("0.02", "5000000")
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("1000000")) == :ok

    assert {:halted, snap} =
             Equity.enforce(
               trade_mode: :dry_run,
               positions: [position],
               limits: %{max_daily_drawdown: "50000", max_daily_loss: "1000000"}
             )

    assert Decimal.gt?(snap.drawdown, Decimal.new("50000"))
    assert Readiness.get() == {:halted, :daily_drawdown_exceeded}
  end

  test "enforce does not halt when mark is stale" do
    assert Readiness.mark_ready() == :ok
    {:ok, position} = create_long("0.02", "5000000")

    assert {:error, :stale, %{reason: :mark_price_unavailable}} =
             Equity.enforce(trade_mode: :dry_run, positions: [position])

    assert Readiness.get() == :ready
  end

  test "snapshot marks short position unrealized against LTP" do
    {:ok, position} = create_short("0.02", "5000000")
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("6000000")) == :ok

    assert {:ok, snap} =
             Equity.snapshot(
               trade_mode: :dry_run,
               positions: [position],
               limits: %{max_daily_drawdown: "100000"}
             )

    assert Decimal.eq?(snap.unrealized, Decimal.new("-20000"))
    assert Decimal.eq?(snap.drawdown, Decimal.new("20000"))
  end

  test "snapshot drawdown is peak minus equity after realized profit" do
    assert :ok = DailyLoss.seed_net(:dry_run, Decimal.new("100000"))
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("5000000")) == :ok

    assert {:ok, peak_snap} =
             Equity.snapshot(
               trade_mode: :dry_run,
               positions: [],
               limits: %{max_daily_drawdown: "50000"}
             )

    assert Decimal.eq?(peak_snap.peak, Decimal.new("100000"))
    assert Decimal.eq?(peak_snap.drawdown, Decimal.new("0"))

    {:ok, position} = create_long("0.02", "5000000")
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("1000000")) == :ok

    assert {:ok, snap} =
             Equity.snapshot(
               trade_mode: :dry_run,
               positions: [position],
               limits: %{max_daily_drawdown: "50000"}
             )

    assert Decimal.eq?(snap.realized_net, Decimal.new("100000"))
    assert Decimal.eq?(snap.unrealized, Decimal.new("-80000"))
    assert Decimal.eq?(snap.equity_pnl, Decimal.new("20000"))
    assert Decimal.eq?(snap.peak, Decimal.new("100000"))
    assert Decimal.eq?(snap.drawdown, Decimal.new("80000"))
  end

  test "snapshot rejects unknown position side" do
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("5000000")) == :ok

    broken = %{
      product_code: "BTC_JPY",
      side: :hold,
      size: Decimal.new("0.01"),
      average_price: Decimal.new("5000000")
    }

    assert {:error, :unsynced, %{reason: :position_side_invalid, product_code: "BTC_JPY"}} =
             Equity.snapshot(trade_mode: :dry_run, positions: [broken])
  end

  test "reconciler run_now enforces drawdown after successful restore" do
    clear_default_risk_state()
    assert Readiness.mark_ready() == :ok
    {:ok, _position} = create_long("0.05", "5000000")
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("1000000")) == :ok

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == {:halted, :daily_drawdown_exceeded}
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, %RiskState{} = risk} ->
        _ =
          risk
          |> Ash.Changeset.for_update(:update, %{
            halted: false,
            reason: nil,
            halted_at: nil
          })
          |> Ash.update()

        :ok

      {:ok, nil} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp create_long(size, avg), do: create_position(:buy, size, avg)
  defp create_short(size, avg), do: create_position(:sell, size, avg)

  defp create_position(side, size, avg) do
    Position
    |> Ash.Changeset.for_create(:create, %{
      product_code: "BTC_JPY",
      side: side,
      size: Decimal.new(size),
      average_price: Decimal.new(avg),
      trade_mode: :dry_run
    })
    |> Ash.create()
  end
end
