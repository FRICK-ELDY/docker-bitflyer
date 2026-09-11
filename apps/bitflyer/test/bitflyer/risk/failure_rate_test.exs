defmodule Bitflyer.Risk.FailureRateTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.FailureRateHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.FailureRate
  alias Bitflyer.Trading.Order

  setup do
    reset_failure_rate()
    reset_readiness()
    reset_market_data_cache()

    on_exit(fn ->
      reset_failure_rate()
      reset_readiness()
      reset_market_data_cache()
    end)

    :ok
  end

  test "auth_failed evaluates to immediate halt without counting" do
    assert FailureRate.evaluate(:auth_failed) == {:halt, :auth_failed}
    assert {:ok, 0} = FailureRate.count(:live)
  end

  test "rejected_by_exchange counts and halts at max_errors" do
    opts = [trade_mode: :live, max_errors: 3, window_ms: 60_000]

    assert :ok = FailureRate.evaluate(:rejected_by_exchange, opts)
    assert {:ok, 1} = FailureRate.count(:live, window_ms: 60_000)

    assert :ok = FailureRate.evaluate(:rejected_by_exchange, opts)

    assert {:halt, :consecutive_exchange_errors} =
             FailureRate.evaluate(:rejected_by_exchange, opts)

    assert {:ok, 3} = FailureRate.count(:live, window_ms: 60_000)
  end

  test "timeout and unknown reasons do not count" do
    assert :ok = FailureRate.evaluate(:timeout)
    assert :ok = FailureRate.evaluate(:disconnected)
    assert :ok = FailureRate.evaluate(:order_not_found)
    assert :ok = FailureRate.evaluate(:something_else)
    assert {:ok, 0} = FailureRate.count(:live)
  end

  test "entries outside the window are pruned from count" do
    now = FailureRate.monotonic_ms()
    assert :ok = FailureRate.record(:live, now: now - 70_000, window_ms: 60_000)
    assert :ok = FailureRate.record(:live, now: now - 10_000, window_ms: 60_000)

    assert {:ok, 1} = FailureRate.count(:live, now: now, window_ms: 60_000)
  end

  test "warm_from_db restores recent rejected orders into ETS by trade_mode" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ = insert_rejected!("fail-warm-paper-1", :paper, now)
    _ = insert_rejected!("fail-warm-paper-2", :paper, now)
    _ = insert_rejected!("fail-warm-live-1", :live, now)
    _ = insert_rejected!("fail-warm-old", :paper, DateTime.add(now, -120, :second))
    _ = insert_pending!("fail-warm-pending", :paper, now)

    assert {:ok, 0} = FailureRate.count(:paper)
    assert {:ok, 0} = FailureRate.count(:live)

    assert :ok = FailureRate.warm_from_db(now_dt: now, now: FailureRate.monotonic_ms())

    assert {:ok, 2} =
             FailureRate.count(:paper, now: FailureRate.monotonic_ms(), window_ms: 60_000)

    assert {:ok, 1} = FailureRate.count(:live, now: FailureRate.monotonic_ms(), window_ms: 60_000)
    assert {:ok, 0} = FailureRate.count(:dry_run)
  end

  test "init warms from DB so restart restores consecutive failure counts" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    max = 3

    for i <- 1..(max - 1) do
      _ = insert_rejected!("fail-init-#{i}", :live, now)
    end

    name = :"failure_rate_warm_#{System.unique_integer([:positive])}"
    start_supervised!({FailureRate, name: name})

    assert {:ok, 2} = FailureRate.count(:live, server: name, window_ms: 60_000)

    # 窓内に max-1 件があるので、再起動後の 1 回で閾値到達
    assert {:halt, :consecutive_exchange_errors} =
             FailureRate.evaluate(:rejected_by_exchange,
               server: name,
               trade_mode: :live,
               max_errors: max,
               window_ms: 60_000
             )
  end

  test "warm_from_db failure keeps prior ETS and stays readable" do
    assert :ok = FailureRate.record(:live)
    assert :ok = FailureRate.record(:live)
    assert {:ok, 2} = FailureRate.count(:live)

    assert {:error, :forced_loader_failure} =
             FailureRate.warm_from_db(
               loader: fn _window, _now -> {:error, :forced_loader_failure} end
             )

    assert {:ok, 2} = FailureRate.count(:live)
  end

  test "init warm failure starts unsynced (fail-closed)" do
    name = :"failure_rate_fail_#{System.unique_integer([:positive])}"

    start_supervised!(
      {FailureRate, name: name, loader: fn _, _ -> {:error, :forced_init_warm_failure} end}
    )

    assert {:error, :unsynced} = FailureRate.count(:live, server: name)

    assert {:halt, :failure_rate_unsynced} =
             FailureRate.evaluate(:rejected_by_exchange, server: name, trade_mode: :live)
  end

  test "unsynced fails closed through authorize" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker() == :ok
    assert :ok = FailureRate.mark_unsynced()

    assert {:error, :unsynced, %{reason: :failure_rate_unsynced}} =
             Risk.authorize(
               %{
                 product_code: "BTC_JPY",
                 side: :buy,
                 size: Decimal.new("0.01"),
                 market_key: {:ticker, "BTC_JPY"},
                 intent_id: "intent-failure-rate-unsynced"
               },
               positions: []
             )
  end

  test "record while unsynced does not write ETS" do
    assert :ok = FailureRate.record(:live)
    assert {:ok, 1} = FailureRate.count(:live)

    assert :ok = FailureRate.mark_unsynced()
    assert :ok = FailureRate.record(:live)

    assert :ok = FailureRate.mark_synced()
    assert {:ok, 1} = FailureRate.count(:live)
  end

  test "warm_from_db replaces cancel-originated ETS with DB rejected only" do
    # cancel 経路相当: DB に rejected が無い状態で ETS だけ進める
    assert :ok = FailureRate.record(:live)
    assert :ok = FailureRate.record(:live)
    assert {:ok, 2} = FailureRate.count(:live)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    _ = insert_rejected!("fail-warm-replace-1", :live, now)

    assert :ok = FailureRate.warm_from_db(now_dt: now, now: FailureRate.monotonic_ms())
    assert {:ok, 1} = FailureRate.count(:live, now: FailureRate.monotonic_ms(), window_ms: 60_000)
  end

  test "warm uses updated_at so late rejection stays inside the window" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    old = DateTime.add(now, -120, :second)

    _ = insert_order!("fail-warm-updated-at", :live, old, :rejected, updated_at: now)

    assert :ok = FailureRate.warm_from_db(now_dt: now, now: FailureRate.monotonic_ms())
    assert {:ok, 1} = FailureRate.count(:live, now: FailureRate.monotonic_ms(), window_ms: 60_000)
  end

  defp insert_rejected!(internal_order_id, trade_mode, at) do
    insert_order!(internal_order_id, trade_mode, at, :rejected)
  end

  defp insert_pending!(internal_order_id, trade_mode, at) do
    insert_order!(internal_order_id, trade_mode, at, :pending)
  end

  defp insert_order!(internal_order_id, trade_mode, inserted_at, status, opts \\ []) do
    updated_at = Keyword.get(opts, :updated_at, inserted_at)

    assert {:ok, order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: internal_order_id,
               product_code: "BTC_JPY",
               side: :buy,
               status: status,
               order_type: :market,
               size: Decimal.new("0.01"),
               trade_mode: trade_mode
             })
             |> Ash.create()

    {:ok, dump_id} = Ecto.UUID.dump(order.id)

    %{num_rows: 1} =
      Bitflyer.Repo.query!(
        "UPDATE orders SET inserted_at = $1, updated_at = $2 WHERE id = $3",
        [inserted_at, updated_at, dump_id]
      )

    order
  end
end
