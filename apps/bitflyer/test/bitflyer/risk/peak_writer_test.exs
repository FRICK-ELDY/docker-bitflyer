defmodule Bitflyer.Risk.PeakWriterTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.DailyLossHelper
  import ExUnit.CaptureLog

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

  test "traps exits so supervisor shutdown can flush pending peaks" do
    assert Process.info(Process.whereis(PeakWriter), :trap_exit) == {:trap_exit, true}
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

    assert {:error, :unsynced} = PeakWriter.enqueue(:live, day, Decimal.new("100000"))
    assert PeakWriter.pending_count() == 1
    assert {:error, :unsynced} = DailyLoss.snapshot(:live)
  end

  test "failed upsert stays queued until a later attempt writes it" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    {:ok, agent} = Agent.start_link(fn -> :fail end)

    assert :ok =
             PeakWriter.set_upsert(fn mode, trading_day, peak ->
               case Agent.get(agent, & &1) do
                 :fail -> {:error, :boom}
                 :ok -> DailyEquityPeak.upsert(mode, trading_day, peak)
               end
             end)

    assert {:error, :unsynced} = PeakWriter.enqueue(:paper, day, Decimal.new("130000"))
    assert PeakWriter.pending_count() == 1
    assert {:error, :unsynced} = DailyLoss.snapshot(:paper)

    Agent.update(agent, fn _ -> :ok end)
    assert :ok = PeakWriter.drain()

    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert paper
    assert Decimal.eq?(paper.peak, Decimal.new("130000"))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:paper)
    assert Decimal.eq?(restored, Decimal.new("130000"))
    Agent.stop(agent)
  end

  test "repeated db failures back off and do not repeat the same error" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    name = :"peak_writer_backoff_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({PeakWriter, name: name})

    assert :ok =
             PeakWriter.set_upsert(fn _mode, _day, _peak -> {:error, :db_down} end, server: name)

    first =
      capture_log(fn ->
        assert {:error, :unsynced} =
                 PeakWriter.enqueue(:live, day, Decimal.new("100000"), server: name)
      end)

    assert first =~ "daily equity peak persist failed"
    key = {:live, day}
    assert %{last_retry_ms: 50, retry_ms: %{^key => 100}} = :sys.get_state(pid)
    left = PeakWriter.retry_timer_left(server: name, key: key)
    assert is_integer(left) and left >= 0 and left <= 50

    later =
      capture_log(fn ->
        Enum.each(1..8, fn _ ->
          send(pid, :flush)
          _ = :sys.get_state(pid)
        end)
      end)

    refute later =~ "daily equity peak persist failed"
    assert %{last_retry_ms: 5_000, retry_ms: %{^key => 5_000}} = :sys.get_state(pid)
    assert PeakWriter.retry_timer_left(server: name, key: key) > 4_000
    assert {:error, :unsynced} = DailyLoss.snapshot(:live)
  end

  test "a failed lower enqueue keeps the higher pending peak" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    name = :"peak_writer_keep_high_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({PeakWriter, name: name})

    assert :ok =
             PeakWriter.set_upsert(fn _mode, _day, _peak -> {:error, :db_down} end, server: name)

    assert {:error, :unsynced} =
             PeakWriter.enqueue(:live, day, Decimal.new("200000"), server: name)

    assert {:error, :unsynced} =
             PeakWriter.enqueue(:live, day, Decimal.new("100000"), server: name)

    assert Decimal.eq?(
             :sys.get_state(pid).pending[{:live, day}].peak,
             Decimal.new("200000")
           )

    assert :ok = PeakWriter.set_upsert(&DailyEquityPeak.upsert/3, server: name)
    assert :ok = PeakWriter.drain(server: name)

    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    live = Enum.find(rows, &(&1.trade_mode == :live))
    assert live
    assert Decimal.eq?(live.peak, Decimal.new("200000"))
  end

  test "a successful paper write does not shorten the live retry wait" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    name = :"peak_writer_per_key_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({PeakWriter, name: name})

    assert :ok =
             PeakWriter.set_upsert(
               fn mode, _day, _peak ->
                 if mode == :live, do: {:error, :db_down}, else: :ok
               end,
               server: name
             )

    assert {:error, :unsynced} =
             PeakWriter.enqueue(:live, day, Decimal.new("100000"), server: name)

    send(pid, :flush)
    _ = :sys.get_state(pid)
    assert %{retry_ms: %{{:live, ^day} => 200}} = :sys.get_state(pid)
    before = PeakWriter.retry_timer_left(server: name, key: {:live, day})
    assert is_integer(before) and before > 0

    assert :ok = PeakWriter.enqueue(:paper, day, Decimal.new("90000"), server: name)

    assert %{retry_ms: retries} = :sys.get_state(pid)
    assert retries[{:live, day}] == 200
    refute Map.has_key?(retries, {:paper, day})
    later = PeakWriter.retry_timer_left(server: name, key: {:live, day})
    assert is_integer(later) and later > 0
  end

  test "upsert failure while DailyLoss is down keeps the peak queued" do
    day = DailyLoss.trading_day(DateTime.utc_now())
    name = :"peak_writer_retry_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({PeakWriter, name: name})

    assert :ok =
             PeakWriter.set_upsert(fn _mode, _day, _peak -> {:error, :db_down} end, server: name)

    assert {:error, :unsynced} =
             PeakWriter.enqueue(:live, day, Decimal.new("80000"),
               server: name,
               daily_loss: :no_such_daily_loss
             )

    assert PeakWriter.pending_count(server: name) == 1
    assert {:ok, _} = DailyLoss.snapshot(:live)
  end

  test "peak writer restart reloads an unpersisted ETS peak" do
    assert :ok = PeakWriter.suspend()

    assert {:ok, _} =
             DailyLoss.record_peak(:paper, Decimal.new("90000"),
               persist: false,
               write_behind: true
             )

    assert PeakWriter.pending_count() == 1
    pid = Process.whereis(PeakWriter)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert is_pid(await_peak_writer(pid))
    assert :ok = PeakWriter.drain()

    day = DailyLoss.trading_day(DateTime.utc_now())
    assert {:ok, rows} = DailyEquityPeak.fetch_day(day)
    paper = Enum.find(rows, &(&1.trade_mode == :paper))
    assert paper
    assert Decimal.eq?(paper.peak, Decimal.new("90000"))
  end

  test "write-behind success leaves the DB peak after both processes are discarded" do
    assert {:ok, peak} =
             DailyLoss.record_peak(:paper, Decimal.new("160000"),
               persist: false,
               write_behind: true
             )

    assert Decimal.eq?(peak, Decimal.new("160000"))
    assert PeakWriter.pending_count() == 0

    pid = Process.whereis(PeakWriter)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert is_pid(await_peak_writer(pid))

    assert :ok = DailyLoss.reinit()
    assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:paper)
    assert Decimal.eq?(restored, Decimal.new("160000"))
  end

  defp await_peak_writer(old_pid, tries \\ 50) do
    case Process.whereis(PeakWriter) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when tries > 0 ->
        receive do
        after
          1 -> await_peak_writer(old_pid, tries - 1)
        end

      _ ->
        nil
    end
  end
end
