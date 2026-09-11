defmodule Bitflyer.Risk.OrderRateTest do
  use Bitflyer.DataCase, async: false

  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.OrderRate
  alias Bitflyer.Trading.Order

  setup do
    reset_order_rate()
    reset_readiness()
    reset_market_data_cache()

    on_exit(fn ->
      reset_order_rate()
      reset_readiness()
      reset_market_data_cache()
    end)

    :ok
  end

  test "duplicate_bag keeps multiple records in the same millisecond" do
    now = OrderRate.monotonic_ms()
    assert :ok = OrderRate.record(:paper, now: now)
    assert :ok = OrderRate.record(:paper, now: now)

    assert {:ok, 2} = OrderRate.count(:paper, now: now, window_ms: 60_000)
  end

  test "warm_from_db restores recent orders into ETS by trade_mode" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ = insert_order!("warm-paper-1", :paper, now)
    _ = insert_order!("warm-paper-2", :paper, now)
    _ = insert_order!("warm-live-1", :live, now)
    _ = insert_order!("warm-old", :paper, DateTime.add(now, -120, :second))

    assert {:ok, 0} = OrderRate.count(:paper)
    assert {:ok, 0} = OrderRate.count(:live)

    assert :ok = OrderRate.warm_from_db(now_dt: now, now: OrderRate.monotonic_ms())

    assert {:ok, 2} = OrderRate.count(:paper, now: OrderRate.monotonic_ms(), window_ms: 60_000)
    assert {:ok, 1} = OrderRate.count(:live, now: OrderRate.monotonic_ms(), window_ms: 60_000)
    assert {:ok, 0} = OrderRate.count(:dry_run)
  end

  test "init warms from DB so restart restores recent counts" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for i <- 1..3 do
      _ = insert_order!("warm-init-#{i}", :paper, now)
    end

    name = :"order_rate_warm_#{System.unique_integer([:positive])}"
    start_supervised!({OrderRate, name: name})

    assert {:ok, 3} = OrderRate.count(:paper, server: name, window_ms: 60_000)
  end

  test "warm_from_db preserves open reservations" do
    assert {:ok, reservation} = OrderRate.reserve(:paper, 10)
    assert {:ok, 1} = OrderRate.count(:paper)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    _ = insert_order!("warm-keep-reserve-1", :paper, now)

    assert :ok = OrderRate.warm_from_db(now_dt: now, now: OrderRate.monotonic_ms())

    # DB の 1 committed + 未 commit 予約 1
    assert {:ok, 2} = OrderRate.count(:paper)
    assert :ok = OrderRate.release(reservation)
    assert {:ok, 1} = OrderRate.count(:paper)
  end

  test "warm_from_db replaces previous ETS entries" do
    assert :ok = OrderRate.record(:paper)
    assert {:ok, 1} = OrderRate.count(:paper)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    _ = insert_order!("warm-replace-1", :paper, now)

    assert :ok = OrderRate.warm_from_db(now_dt: now, now: OrderRate.monotonic_ms())
    assert {:ok, 1} = OrderRate.count(:paper)
  end

  test "warm_from_db failure keeps prior ETS and stays readable" do
    assert :ok = OrderRate.record(:paper)
    assert :ok = OrderRate.record(:paper)
    assert {:ok, 2} = OrderRate.count(:paper)

    assert {:error, :forced_loader_failure} =
             OrderRate.warm_from_db(
               loader: fn _window, _now -> {:error, :forced_loader_failure} end
             )

    assert {:ok, 2} = OrderRate.count(:paper)
  end

  test "unsynced count fails closed through authorize" do
    assert Readiness.mark_ready() == :ok
    assert put_fresh_ticker() == :ok
    assert :ok = OrderRate.mark_unsynced()

    assert {:error, :unsynced, %{reason: :order_rate_unsynced}} =
             Risk.authorize(
               %{
                 product_code: "BTC_JPY",
                 side: :buy,
                 size: Decimal.new("0.01"),
                 market_key: {:ticker, "BTC_JPY"},
                 intent_id: "intent-rate-unsynced"
               },
               positions: []
             )
  end

  test "init warm failure starts unsynced (fail-closed)" do
    name = :"order_rate_fail_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OrderRate, name: name, loader: fn _, _ -> {:error, :forced_init_warm_failure} end}
    )

    assert {:error, :unsynced} = OrderRate.count(:paper, server: name)
  end

  test "reserve is atomic under concurrent callers" do
    name = :"order_rate_reserve_#{System.unique_integer([:positive])}"
    start_supervised!({OrderRate, name: name, loader: fn _, _ -> {:ok, []} end})

    max = 5
    task_count = 40

    results =
      1..task_count
      |> Task.async_stream(
        fn _ -> OrderRate.reserve(:paper, max, server: name) end,
        max_concurrency: task_count,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = Enum.filter(results, &match?({:ok, _}, &1))
    exceeded = Enum.filter(results, &match?({:error, :limit_exceeded, _}, &1))

    assert length(oks) == max
    assert length(exceeded) == task_count - max
    assert {:ok, ^max} = OrderRate.count(:paper, server: name)
  end

  test "release frees a reserved slot for another reserve" do
    assert {:ok, reservation} = OrderRate.reserve(:paper, 1)
    assert {:error, :limit_exceeded, %{count: 1, max: 1}} = OrderRate.reserve(:paper, 1)

    assert :ok = OrderRate.release(reservation)
    assert {:ok, _} = OrderRate.reserve(:paper, 1)
    assert {:ok, 1} = OrderRate.count(:paper)
  end

  defp insert_order!(internal_order_id, trade_mode, inserted_at) do
    assert {:ok, order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: internal_order_id,
               product_code: "FX_BTC_JPY",
               side: :buy,
               status: :pending,
               order_type: :market,
               size: Decimal.new("0.01"),
               trade_mode: trade_mode
             })
             |> Ash.create()

    {:ok, dump_id} = Ecto.UUID.dump(order.id)

    %{num_rows: 1} =
      Bitflyer.Repo.query!(
        "UPDATE orders SET inserted_at = $1, updated_at = $1 WHERE id = $2",
        [inserted_at, dump_id]
      )

    order
  end
end
