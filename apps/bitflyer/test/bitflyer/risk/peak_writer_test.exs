defmodule Bitflyer.Risk.PeakWriterTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.DailyLossHelper

  alias Bitflyer.Risk.{DailyLoss, PeakWriter}
  alias Bitflyer.Trading.DailyEquityPeak

  setup do
    assert :ok = PeakWriter.reset_upsert()
    assert :ok = PeakWriter.resume()
    reset_daily_loss()

    on_exit(fn ->
      PeakWriter.reset_upsert()
      PeakWriter.resume()
      reset_daily_loss()
    end)

    :ok
  end

  test "coalesces to the higher peak and reinit keeps it" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    assert :ok = PeakWriter.suspend()
    assert :ok = PeakWriter.enqueue(:paper, day, Decimal.new("120000"))
    assert :ok = PeakWriter.enqueue(:paper, day, Decimal.new("150000"))

    assert {:ok, rows_before} = DailyEquityPeak.fetch_day(day)
    refute Enum.any?(rows_before, &(&1.trade_mode == :paper))

    assert :ok = PeakWriter.resume()
    assert :ok = PeakWriter.drain()

    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert paper
    assert Decimal.eq?(paper.peak, Decimal.new("150000"))

    assert :ok = PeakWriter.enqueue(:paper, day, Decimal.new("100000"))
    assert :ok = PeakWriter.drain()

    assert {:ok, rows_after} = DailyEquityPeak.fetch_day(day)
    paper_after = Enum.find(rows_after, &(&1.trade_mode == :paper))
    assert Decimal.eq?(paper_after.peak, Decimal.new("150000"))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:paper)
    assert Decimal.eq?(restored, Decimal.new("150000"))
  end

  test "upsert failure marks the mode unsynced" do
    day = DailyLoss.trading_day(DateTime.utc_now())

    assert :ok =
             PeakWriter.set_upsert(fn _mode, _day, _peak -> {:error, :boom} end)

    assert :ok = PeakWriter.enqueue(:live, day, Decimal.new("100000"))
    assert :ok = PeakWriter.drain()
    assert {:error, :unsynced} = DailyLoss.snapshot(:live)
  end
end
