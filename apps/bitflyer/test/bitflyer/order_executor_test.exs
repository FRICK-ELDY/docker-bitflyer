defmodule Bitflyer.OrderExecutorTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position, RiskState}

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

      case Agent.get(__MODULE__.NextResult, & &1) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}

        :success ->
          {:ok, %{exchange_order_id: "ex-" <> request.internal_order_id}}
      end
    end

    def start_agents do
      {:ok, _} = Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
      {:ok, _} = Agent.start_link(fn -> :success end, name: __MODULE__.NextResult)
      :ok
    end

    def stop_agents do
      if Process.whereis(__MODULE__.Counter), do: Agent.stop(__MODULE__.Counter)
      if Process.whereis(__MODULE__.NextResult), do: Agent.stop(__MODULE__.NextResult)
    end

    def place_count do
      Agent.get(__MODULE__.Counter, & &1)
    end

    def set_next_result(result) do
      Agent.update(__MODULE__.NextResult, fn _ -> result end)
    end
  end

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    clear_default_risk_state()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)

    :ok = SpyExchange.start_agents()
    Process.register(self(), SpyExchange)
    Application.put_env(:bitflyer, :exchange_client, SpyExchange)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      clear_default_risk_state()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)

      SpyExchange.stop_agents()

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

    assert {:ok, %Order{status: :filled, trade_mode: :paper, filled_size: filled, price: price}} =
             OrderExecutor.submit(valid_command("paper-1"),
               positions: [],
               trade_mode: :paper
             )

    assert Decimal.equal?(filled, Decimal.new("0.01"))
    assert Decimal.equal?(price, Decimal.new("5000000"))
    assert SpyExchange.place_count() == 0
    refute_received {:place_order, _}

    assert {:ok, %Position{side: :buy, size: size}} =
             Position
             |> Ash.Query.filter(product_code == "FX_BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert Decimal.equal?(size, Decimal.new("0.01"))

    assert {:ok, balances} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.read()

    assert length(balances) == 2
    by_currency = Map.new(balances, &{&1.currency, &1.amount})
    assert Decimal.equal?(by_currency["BTC"], Decimal.new("0.01"))
    assert Decimal.equal?(by_currency["JPY"], Decimal.new("-50000"))
  end

  test "paper limit fills when LTP crosses and grows balance rows" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")

    assert {:ok, %Order{status: :filled}} =
             OrderExecutor.submit(
               valid_command("paper-limit-cross", %{
                 order_type: :limit,
                 price: Decimal.new("5100000"),
                 side: :buy
               }),
               positions: [],
               trade_mode: :paper
             )

    assert {:ok, jpy_rows} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "JPY")
             |> Ash.Query.sort(captured_at: :desc)
             |> Ash.read()

    assert length(jpy_rows) >= 2
    assert Decimal.equal?(hd(jpy_rows).amount, Decimal.new("949000"))
  end

  test "paper limit stays pending when LTP does not cross" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, before} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.read()

    assert {:ok, %Order{status: :pending}} =
             OrderExecutor.submit(
               valid_command("paper-limit-open", %{
                 order_type: :limit,
                 price: Decimal.new("4900000"),
                 side: :buy
               }),
               positions: [],
               trade_mode: :paper
             )

    assert {:ok, nil} =
             Position
             |> Ash.Query.filter(product_code == "FX_BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert {:ok, after_balances} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.read()

    assert length(after_balances) == length(before)
  end

  test "concurrent paper fills serialize balance appends without lost update" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0")

    results =
      1..2
      |> Enum.map(fn i ->
        Task.async(fn ->
          OrderExecutor.submit(valid_command("paper-concurrent-#{i}"),
            positions: [],
            trade_mode: :paper
          )
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.all?(results, &match?({:ok, %Order{status: :filled}}, &1))

    assert {:ok, %BalanceSnapshot{amount: jpy}} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "JPY")
             |> Ash.Query.sort(captured_at: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    assert {:ok, %BalanceSnapshot{amount: btc}} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "BTC")
             |> Ash.Query.sort(captured_at: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    # 1_000_000 - 2 * (0.01 * 5_000_000)
    assert Decimal.equal?(jpy, Decimal.new("900000"))
    assert Decimal.equal?(btc, Decimal.new("0.02"))
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

  test "live timeout marks submission_unknown, halts, and blocks further submits" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    SpyExchange.set_next_result({:error, :timeout})

    assert {:error, :submission_unknown, %{reason: :timeout}} =
             OrderExecutor.submit(valid_command("live-timeout-1"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1

    assert {:ok, %Order{status: :submission_unknown}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-timeout-1")
             |> Ash.read_one()

    assert Readiness.get() == {:halted, :submission_unknown}

    assert {:ok, %RiskState{halted: true, reason: "submission_unknown"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()

    # 別 internal_order_id でも再送しない（ゲート閉鎖）
    SpyExchange.set_next_result(:success)

    assert {:error, :circuit_open, _} =
             OrderExecutor.submit(valid_command("live-timeout-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-timeout-2")
             |> Ash.read_one()
  end

  test "live disconnect marks submission_unknown and does not treat as rejected" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    SpyExchange.set_next_result({:error, :disconnected})

    assert {:error, :submission_unknown, %{reason: :disconnected}} =
             OrderExecutor.submit(valid_command("live-disc-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:ok, %Order{status: :submission_unknown}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-disc-1")
             |> Ash.read_one()

    assert Readiness.get() == {:halted, :submission_unknown}
  end

  test "live definite exchange rejection stays rejected without halt" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    SpyExchange.set_next_result({:error, :rejected_by_exchange})

    assert {:error, :exchange_error, %{reason: :rejected_by_exchange}} =
             OrderExecutor.submit(valid_command("live-rej-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:ok, %Order{status: :rejected}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-rej-1")
             |> Ash.read_one()

    assert Readiness.get() == :ready
    assert SpyExchange.place_count() == 1

    # 確定拒否後は別 intent の再発注が可能（halt していない）
    SpyExchange.set_next_result(:success)

    assert {:ok, %Order{status: :pending}} =
             OrderExecutor.submit(valid_command("live-rej-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 2
  end

  test "live persist failure after place_order halts and blocks further submits" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    persist_fail = fn _order, _exchange_order_id ->
      {:error, :forced_persist_failure}
    end

    assert {:error, :persist_failed,
            %{
              internal_order_id: "live-persist-1",
              exchange_order_id: "ex-live-persist-1"
            }} =
             OrderExecutor.submit(valid_command("live-persist-1"),
               positions: [],
               trade_mode: :live,
               persist_exchange_order_id: persist_fail
             )

    assert SpyExchange.place_count() == 1
    assert Readiness.get() == {:halted, :persist_failed}

    assert {:ok, %RiskState{halted: true, reason: "persist_failed"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()

    # 取引所 ID は失われたまま（pending・exchange_order_id nil）
    assert {:ok, %Order{status: :pending, exchange_order_id: nil}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-persist-1")
             |> Ash.read_one()

    # 同一 ID・別 ID ともゲート閉鎖で拒否（再 REST しない）
    assert {:error, :circuit_open, _} =
             OrderExecutor.submit(valid_command("live-persist-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:error, :circuit_open, _} =
             OrderExecutor.submit(valid_command("live-persist-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-persist-2")
             |> Ash.read_one()
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

  test "public submit cannot skip risk via authorize?: false" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.get() == :not_ready

    # 旧オプションを渡しても risk は常に実行される（迂回不可）
    assert {:error, :unsynced, _} =
             OrderExecutor.submit(valid_command("risk-bypass-1"),
               positions: [],
               trade_mode: :dry_run,
               authorize?: false
             )

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "risk-bypass-1")
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

  defp seed_paper_balance!(currency, amount) do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    amount = Decimal.new(amount)

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: currency,
               amount: amount,
               available: amount,
               captured_at: captured_at,
               trade_mode: :paper
             })
             |> Ash.create()
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} -> :ok
      {:ok, risk} -> Ash.destroy!(risk)
      {:error, _} -> :ok
    end
  end
end
