defmodule Bitflyer.ApplicationShutdownTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.ReadinessHelper
  import Bitflyer.TestSupport.InFlightHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.OrderExecutor.InFlight
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.Order

  @market_key {:ticker, "FX_BTC_JPY"}

  defmodule HealExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_request), do: {:ok, %{exchange_order_id: "ex-drain-race-1"}}

    @impl true
    def cancel_order(_request), do: :ok

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      {:ok,
       %{
         exchange_order_id: id,
         product_code: "FX_BTC_JPY",
         side: :buy,
         size: Decimal.new("0.01"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :active
       }}
    end

    @impl true
    def fetch_executions(_request), do: {:ok, []}

    @impl true
    def list_child_orders(_request), do: {:ok, []}
  end

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_daily_loss()
    reset_inflight()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_drain = Application.get_env(:bitflyer, Bitflyer.OrderExecutor, [])

    Application.put_env(:bitflyer, :trade_mode, :dry_run)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_daily_loss()
      reset_inflight()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, Bitflyer.OrderExecutor, previous_drain)
    end)

    :ok
  end

  test "prep_stop closes order gate and rejects new submit" do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    assert [] = Bitflyer.Application.prep_stop([])
    assert Readiness.get() == :not_ready

    assert {:error, :shutting_down, %{reason: :inflight_closed}} =
             OrderExecutor.submit(valid_command("shutdown-1"),
               positions: [],
               trade_mode: :dry_run
             )

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "shutdown-1")
             |> Ash.read_one()
  end

  test "prep_stop preserves halted state" do
    assert :ok = Readiness.halt(:reconcile_mismatch)
    assert [] = Bitflyer.Application.prep_stop([])
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert {:error, :shutting_down, %{reason: :inflight_closed}} =
             OrderExecutor.submit(valid_command("shutdown-halt-1"),
               positions: [],
               trade_mode: :dry_run
             )
  end

  test "ui prep_stop also closes order gate" do
    assert Readiness.mark_ready() == :ok
    assert [] = Ui.Application.prep_stop([])
    assert Readiness.get() == :not_ready
  end

  test "prep_stop drains in-flight submit before returning" do
    parent = self()

    worker =
      Task.async(fn ->
        assert {:ok, ref} =
                 InFlight.track(%{kind: :submit, internal_order_id: "drain-wait-1"})

        send(parent, :tracked)

        receive do
          :release -> :ok
        end

        assert :ok = InFlight.untrack(ref)
        :released
      end)

    assert_receive :tracked

    stopper =
      Task.async(fn ->
        Bitflyer.Application.prep_stop([])
        :stopped
      end)

    refute match?({:ok, _}, Task.yield(stopper, 50))
    assert Readiness.get() == :not_ready

    send(worker.pid, :release)
    assert Task.await(worker) == :released
    assert Task.await(stopper) == :stopped
  end

  test "prep_stop drain timeout marks pending submit as submission_unknown" do
    Application.put_env(:bitflyer, Bitflyer.OrderExecutor, drain_timeout_ms: 40)

    assert {:ok, order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "drain-timeout-1",
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               status: :pending,
               trade_mode: :live
             })
             |> Ash.create()

    assert is_nil(order.exchange_order_id)

    assert {:ok, ref} =
             InFlight.track(%{kind: :submit, internal_order_id: "drain-timeout-1"})

    assert [] = Bitflyer.Application.prep_stop([])

    assert {:ok, %Order{status: :submission_unknown}} =
             Order
             |> Ash.Query.filter(internal_order_id == "drain-timeout-1")
             |> Ash.read_one()

    assert Readiness.get() == {:halted, :submission_unknown}

    assert :ok = InFlight.untrack(ref)
  end

  test "persist after drain-unknown heals status to pending with exchange_order_id" do
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_mode = Application.get_env(:bitflyer, :trade_mode)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    Application.put_env(:bitflyer, :exchange_client, __MODULE__.HealExchange)
    assert Readiness.mark_ready() == :ok

    on_exit(fn ->
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)
    end)

    assert {:ok, order} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "drain-race-1",
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               status: :pending,
               trade_mode: :live
             })
             |> Ash.create()

    assert {:ok, _} =
             order
             |> Ash.Changeset.for_update(:update, %{status: :submission_unknown})
             |> Ash.update()

    # in-memory は pending のまま（drain timeout と place 成功の競合）
    stale = %{order | status: :pending, exchange_order_id: nil}

    assert {:ok, healed} =
             Bitflyer.OrderExecutor.Live.execute(stale, %{}, [])

    assert healed.status == :pending
    assert healed.exchange_order_id == "ex-drain-race-1"

    assert {:ok, %Order{status: :pending, exchange_order_id: "ex-drain-race-1"}} =
             Order
             |> Ash.Query.filter(internal_order_id == "drain-race-1")
             |> Ash.read_one()
  end

  defp valid_command(id) do
    %{
      internal_order_id: id,
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.01"),
      market_key: @market_key,
      order_type: :market
    }
  end
end
