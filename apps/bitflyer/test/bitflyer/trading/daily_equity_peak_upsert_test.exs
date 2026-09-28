defmodule Bitflyer.Trading.DailyEquityPeakUpsertTest do
  use Bitflyer.DataCase, async: true

  alias Bitflyer.Trading.DailyEquityPeak

  # 共有 Sandbox では Task が同一接続に載り、insert は直列になる。
  # このモジュールは async なので所有者以外は接続を共有しない。
  @day ~D[1900-01-02]
  @mode :paper

  setup do
    on_exit(fn -> delete_peak() end)
    :ok
  end

  test "first upserts on separate connections keep the higher peak" do
    peaks = [Decimal.new("120000"), Decimal.new("150000"), Decimal.new("90000")]
    results = race_upserts(peaks)

    assert Enum.all?(results, fn {result, _backend_pid} -> result == :ok end)

    backend_pids = Enum.map(results, fn {_result, backend_pid} -> backend_pid end)
    assert length(Enum.uniq(backend_pids)) == length(peaks)

    assert {:ok, rows} = DailyEquityPeak.fetch_day(@day)
    assert [row] = Enum.filter(rows, &(&1.trade_mode == @mode))
    assert Decimal.eq?(row.peak, Decimal.new("150000"))
    assert row.inserted_at
    assert row.updated_at
  end

  defp race_upserts(peaks) do
    parent = self()

    tasks =
      Enum.map(peaks, fn peak ->
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bitflyer.Repo, sandbox: false)

          try do
            {:ok, %{rows: [[backend_pid]]}} = Bitflyer.Repo.query("SELECT pg_backend_pid()")
            send(parent, {:ready, self()})

            receive do
              :go -> {DailyEquityPeak.upsert(@mode, @day, peak), backend_pid}
            after
              5_000 -> {{:error, :barrier_timeout}, backend_pid}
            end
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Bitflyer.Repo)
          end
        end)
      end)

    pids =
      for _ <- peaks do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp delete_peak do
    task =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bitflyer.Repo, sandbox: false)

        try do
          Bitflyer.Repo.query!(
            "DELETE FROM daily_equity_peaks WHERE trade_mode = $1 AND trading_day = $2",
            [Atom.to_string(@mode), @day]
          )
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Bitflyer.Repo)
        end
      end)

    _ = Task.await(task, 5_000)
    :ok
  end
end
