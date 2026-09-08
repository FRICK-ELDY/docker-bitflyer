defmodule Bitflyer.OrderExecutorTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.{Order, Position}

  @market_key {:ticker, "FX_BTC_JPY"}

  defmodule SpyExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(request) do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> send(pid, {:place_order, request})
      end

      Agent.update(__MODULE__.Counter, fn count -> count + 1 end)
      {:ok, %{exchange_order_id: "ex-" <> request.internal_order_id}}
    end

    def start_counter do
      Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
    end

    def place_count do
      Agent.get(__MODULE__.Counter, & &1)
    end
  end

  setup do
    reset_readiness()
    reset_market_data_cache()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)

    {:ok, _} = SpyExchange.start_counter()
    Process.register(self(), SpyExchange)
    Application.put_env(:bitflyer, :exchange_client, SpyExchange)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)

      if Process.whereis(SpyExchange.Counter), do: Agent.stop(SpyExchange.Counter)

      if Process.whereis(SpyExchange) == self() do
        Process.unregister(SpyExchange)
      end
    end)

    :ok
  end

  test "dry_run records order without calling place_order or moving positions" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %Order{status: :pending, trade_mode: :dry_run} = order} =
             OrderExecutor.submit(valid_command("dry-1"),
               positions: [],
               trade_mode: :dry_run
             )

    assert SpyExchange.place_count() == 0
    refute_received {:place_order, _}

    assert {:ok, []} =
             Position
             |> Ash.Query.filter(product_code == "FX_BTC_JPY" and trade_mode == :dry_run)
             |> Ash.read()

    assert order.internal_order_id == "dry-1"
  end

  test "paper fills and updates position without calling place_order" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %Order{status: :filled, trade_mode: :paper, filled_size: filled}} =
             OrderExecutor.submit(valid_command("paper-1"),
               positions: [],
               trade_mode: :paper
             )

    assert Decimal.equal?(filled, Decimal.new("0.01"))
    assert SpyExchange.place_count() == 0
    refute_received {:place_order, _}

    assert {:ok, %Position{side: :buy, size: size}} =
             Position
             |> Ash.Query.filter(product_code == "FX_BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert Decimal.equal?(size, Decimal.new("0.01"))
  end

  test "idempotent submit does not call place_order again" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %Order{}} =
             OrderExecutor.submit(valid_command("idem-1"), positions: [], trade_mode: :dry_run)

    assert {:ok, %Order{internal_order_id: "idem-1"}, :idempotent} =
             OrderExecutor.submit(valid_command("idem-1"), positions: [], trade_mode: :dry_run)

    assert SpyExchange.place_count() == 0
  end

  test "live without confirm rejects and does not call place_order" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, false)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:error, :exchange_halted, %{reason: :live_confirm_missing}} =
             OrderExecutor.submit(valid_command("live-halt-1"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 0

    assert {:ok, %Order{status: :rejected}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-halt-1")
             |> Ash.read_one()
  end

  test "live with confirm places order via exchange client" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %Order{status: :pending, exchange_order_id: "ex-live-ok-1"}} =
             OrderExecutor.submit(valid_command("live-ok-1"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1
    assert_received {:place_order, %{internal_order_id: "live-ok-1"}}
  end

  test "risk rejection prevents order persistence" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.get() == :not_ready

    assert {:error, :unsynced, _} =
             OrderExecutor.submit(valid_command("risk-1"), positions: [], trade_mode: :dry_run)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "risk-1")
             |> Ash.read_one()

    assert SpyExchange.place_count() == 0
  end

  defp valid_command(internal_order_id, overrides \\ %{}) do
    Map.merge(
      %{
        internal_order_id: internal_order_id,
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: @market_key,
        order_type: :market
      },
      overrides
    )
  end

  defp put_fresh_market do
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
  end
end
