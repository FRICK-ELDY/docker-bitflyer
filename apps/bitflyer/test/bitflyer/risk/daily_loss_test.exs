defmodule Bitflyer.Risk.DailyLossTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.DailyLossHelper

  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.{DailyEquityPeak, Fill}

  setup do
    reset_daily_loss()
    on_exit(fn -> reset_daily_loss() end)
    :ok
  end

  test "safe reload cannot sync while invalidate barrier is held" do
    assert {:ok, gen} = DailyLoss.invalidate(:live)

    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :live)
    assert {:error, :unsynced} = DailyLoss.get(:live)

    assert :ok =
             DailyLoss.reload(
               trade_mode: :live,
               generation: gen,
               release_barrier: true
             )

    assert {:ok, %Decimal{}} = DailyLoss.get(:live)
  end

  test "force reload also cannot sync over an open invalidate barrier" do
    assert {:ok, gen} = DailyLoss.invalidate(:paper)

    # resume / 旧 API の force でも barrier を踏み潰さない
    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :paper, force: true)
    assert {:error, :unsynced} = DailyLoss.get(:paper)

    assert :ok =
             DailyLoss.reload(
               trade_mode: :paper,
               generation: gen,
               release_barrier: true
             )

    assert {:ok, %Decimal{}} = DailyLoss.get(:paper)
  end

  test "stale generation snapshot cannot overwrite after fill completes" do
    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "dl-race-1",
               product_code: "FX_BTC_JPY",
               side: :sell,
               size: Decimal.new("0.1"),
               price: Decimal.new("3999000"),
               realized_pnl: Decimal.new("-100100"),
               trade_mode: :live,
               filled_at: DateTime.utc_now()
             })
             |> Ash.create()

    stale_gen = 0

    assert {:ok, fill_gen} = DailyLoss.invalidate(:live)
    assert fill_gen == 1

    assert :ok =
             DailyLoss.reload(
               trade_mode: :live,
               generation: fill_gen,
               release_barrier: true
             )

    assert {:ok, loss} = DailyLoss.get(:live)
    assert Decimal.eq?(loss, Decimal.new("100100"))

    assert {:ok, :deferred} =
             DailyLoss.reload(trade_mode: :live, generation: stale_gen)

    assert {:ok, loss_after} = DailyLoss.get(:live)
    assert Decimal.eq?(loss_after, Decimal.new("100100"))
  end

  test "stuck barrier after crash-like invalidate is cleared by reset not force" do
    assert {:ok, _gen} = DailyLoss.invalidate(:paper)
    assert {:error, :unsynced} = DailyLoss.get(:paper)
    assert {:ok, :deferred} = DailyLoss.reload(trade_mode: :paper, force: true)
    assert {:error, :unsynced} = DailyLoss.get(:paper)

    # 本番では DailyLoss 再起動（init）。テストは reset で同等に barrier を落とす。
    assert :ok = DailyLoss.reset()
    assert {:ok, loss} = DailyLoss.get(:paper)
    assert Decimal.eq?(loss, Decimal.new(0))
  end

  test "record_peak persists and reinit restores it" do
    assert {:ok, peak} = DailyLoss.record_peak(:live, Decimal.new("100000"))
    assert Decimal.eq?(peak, Decimal.new("100000"))

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, [row]} = DailyEquityPeak.fetch_day(day)
    assert row.trade_mode == :live
    assert Decimal.eq?(row.peak, Decimal.new("100000"))

    assert :ok = DailyLoss.reset()
    assert {:ok, %{peak: zero}} = DailyLoss.snapshot(:live)
    assert Decimal.eq?(zero, Decimal.new(0))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:live)
    assert Decimal.eq?(restored, Decimal.new("100000"))
  end

  test "record_peak persist failure marks unsynced" do
    assert {:error, :unsynced} =
             DailyLoss.record_peak(:dry_run, Decimal.new("100000"),
               persist: fn _mode, _day, _peak -> {:error, :forced} end
             )

    assert {:error, :unsynced} = DailyLoss.get(:dry_run)
  end

  test "reload restores persisted HWM after ETS reset" do
    assert {:ok, _} = DailyLoss.record_peak(:live, Decimal.new("100000"))

    assert :ok = DailyLoss.reset()
    assert {:ok, %{peak: zero}} = DailyLoss.snapshot(:live)
    assert Decimal.eq?(zero, Decimal.new(0))

    assert :ok = DailyLoss.reload(trade_mode: :live)
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:live)
    assert Decimal.eq?(restored, Decimal.new("100000"))
  end

  test "reload after failed-init style unsynced still restores HWM" do
    assert {:ok, _} = DailyLoss.record_peak(:paper, Decimal.new("100000"))
    assert :ok = DailyLoss.reset()
    assert :ok = DailyLoss.mark_unsynced()

    assert :ok = DailyLoss.reload(trade_mode: :paper)
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:paper)
    assert Decimal.eq?(restored, Decimal.new("100000"))
  end

  test "same-day reload keeps the higher of ETS and DB peak" do
    assert {:ok, _} = DailyLoss.record_peak(:dry_run, Decimal.new("100000"))

    assert {:ok, ets_peak} =
             DailyLoss.record_peak(:dry_run, Decimal.new("150000"),
               persist: fn _mode, _day, _peak -> :ok end
             )

    assert Decimal.eq?(ets_peak, Decimal.new("150000"))

    assert :ok = DailyLoss.reload(trade_mode: :dry_run)
    assert {:ok, %{peak: kept}} = DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(kept, Decimal.new("150000"))
  end

  test "reload on a new trading day does not carry yesterday peak" do
    today = ~U[2026-09-12 10:00:00Z]
    tomorrow = ~U[2026-09-13 10:00:00Z]

    assert :ok = DailyLoss.reset(now_dt: today)
    assert {:ok, _} = DailyLoss.record_peak(:live, Decimal.new("100000"), now_dt: today)

    assert :ok = DailyLoss.reload(trade_mode: :live, now_dt: tomorrow)
    assert {:ok, %{peak: fresh}} = DailyLoss.snapshot(:live, now_dt: tomorrow)
    assert Decimal.eq?(fresh, Decimal.new(0))
  end

  test "stale-day record_peak reloads then updates ETS and DB" do
    today = ~U[2026-09-12 10:00:00Z]
    tomorrow = ~U[2026-09-13 10:00:00Z]

    assert :ok = DailyLoss.reset(now_dt: today)
    assert {:ok, peak} = DailyLoss.record_peak(:paper, Decimal.new("80000"), now_dt: tomorrow)
    assert Decimal.eq?(peak, Decimal.new("80000"))

    assert {:ok, %{peak: ets}} = DailyLoss.snapshot(:paper, now_dt: tomorrow)
    assert Decimal.eq?(ets, Decimal.new("80000"))

    day = DailyLoss.trading_day(tomorrow)
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert Decimal.eq?(paper.peak, Decimal.new("80000"))
  end

  test "persist false updates ETS only" do
    assert {:ok, peak} = DailyLoss.record_peak(:live, Decimal.new("100000"), persist: false)
    assert Decimal.eq?(peak, Decimal.new("100000"))
    assert {:ok, %{peak: ets}} = DailyLoss.snapshot(:live)
    assert Decimal.eq?(ets, Decimal.new("100000"))

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    refute Enum.any?(rows, &(&1.trade_mode == :live))
  end

  test "concurrent first persist retries unique collision instead of unsynced" do
    day = DailyLoss.trading_day(DateTime.utc_now())

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> DailyEquityPeak.upsert(:paper, day, Decimal.new("100000")) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &(&1 == :ok))
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert Decimal.eq?(paper.peak, Decimal.new("100000"))
  end

  test "concurrent upserts keep the higher peak" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    assert :ok = DailyEquityPeak.upsert(:dry_run, day, Decimal.new("100000"))

    results =
      [Decimal.new("150000"), Decimal.new("120000")]
      |> Enum.map(fn peak ->
        Task.async(fn -> DailyEquityPeak.upsert(:dry_run, day, peak) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &(&1 == :ok))
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    dry_run = Enum.find(rows, &(&1.trade_mode == :dry_run))
    assert Decimal.eq?(dry_run.peak, Decimal.new("150000"))
  end

  test "same-day lower peak does not persist" do
    assert {:ok, _} = DailyLoss.record_peak(:paper, Decimal.new("50000"))
    assert {:ok, peak} = DailyLoss.record_peak(:paper, Decimal.new("10000"))
    assert Decimal.eq?(peak, Decimal.new("50000"))

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert Decimal.eq?(paper.peak, Decimal.new("50000"))
  end
end
