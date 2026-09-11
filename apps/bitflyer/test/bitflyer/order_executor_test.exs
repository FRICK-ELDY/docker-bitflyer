defmodule Bitflyer.OrderExecutorTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.FailureRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.System
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Order, Position, RiskState}

  @market_key {:ticker, "BTC_JPY"}

  defmodule SpyExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

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

    @impl true
    def cancel_order(request) do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> send(pid, {:cancel_order, request})
      end

      case Agent.get(__MODULE__.CancelNextResult, & &1) do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    end

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      Agent.update(__MODULE__.FetchCounter, fn count -> count + 1 end)

      {:ok,
       %{
         exchange_order_id: id,
         product_code: "BTC_JPY",
         side: :buy,
         size: Decimal.new("1"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :active
       }}
    end

    @impl true
    def fetch_executions(_request), do: {:ok, []}

    @impl true
    def list_child_orders(_request), do: {:ok, []}

    def place_count do
      Agent.get(__MODULE__.Counter, & &1)
    end

    def fetch_count do
      Agent.get(__MODULE__.FetchCounter, & &1)
    end

    def set_next_result(result) do
      Agent.update(__MODULE__.NextResult, fn _ -> result end)
    end

    def set_next_cancel_result(result) do
      Agent.update(__MODULE__.CancelNextResult, fn _ -> result end)
    end
  end

  defmodule BrokenPostPlaceFillExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(_), do: {:error, :timeout}

    @impl true
    def fetch_executions(_), do: {:error, :timeout}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_failure_rate()
    reset_daily_loss()
    reset_balance_cache()
    clear_default_risk_state()
    OrderExecutor.LiveFills.clear_open_orders_sync_clock()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)
    previous_fills_cfg = Application.get_env(:bitflyer, OrderExecutor.LiveFills, [])

    Application.put_env(
      :bitflyer,
      OrderExecutor.LiveFills,
      Keyword.put(previous_fills_cfg, :min_sync_interval_ms, 0)
    )

    start_supervised!(%{
      id: SpyExchange.Counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: SpyExchange.Counter]]}
    })

    start_supervised!(%{
      id: SpyExchange.FetchCounter,
      start: {Agent, :start_link, [fn -> 0 end, [name: SpyExchange.FetchCounter]]}
    })

    start_supervised!(%{
      id: SpyExchange.NextResult,
      start: {Agent, :start_link, [fn -> :success end, [name: SpyExchange.NextResult]]}
    })

    start_supervised!(%{
      id: SpyExchange.CancelNextResult,
      start: {Agent, :start_link, [fn -> :ok end, [name: SpyExchange.CancelNextResult]]}
    })

    Process.register(self(), SpyExchange)
    Application.put_env(:bitflyer, :exchange_client, SpyExchange)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_failure_rate()
      reset_daily_loss()
      reset_balance_cache()
      clear_default_risk_state()
      OrderExecutor.LiveFills.clear_open_orders_sync_clock()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)
      Application.put_env(:bitflyer, OrderExecutor.LiveFills, previous_fills_cfg)

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
             System.submit_order(valid_command("dry-1"),
               positions: [],
               trade_mode: :dry_run
             )

    assert SpyExchange.place_count() == 0
    refute_received {:place_order, _}

    assert {:ok, []} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :dry_run)
             |> Ash.read()

    assert order.internal_order_id == "dry-1"
  end

  test "paper fills and updates position without calling place_order" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0")

    assert {:ok, %Order{status: :filled, trade_mode: :paper, filled_size: filled, price: price}} =
             System.submit_order(valid_command("paper-1"),
               positions: [],
               trade_mode: :paper
             )

    assert Decimal.equal?(filled, Decimal.new("0.01"))
    assert Decimal.equal?(price, Decimal.new("5000000"))
    assert SpyExchange.place_count() == 0
    refute_received {:place_order, _}

    assert {:ok, %Position{side: :buy, size: size}} =
             Position
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
             |> Ash.read_one()

    assert Decimal.equal?(size, Decimal.new("0.01"))

    assert {:ok, balances} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.Query.sort(captured_at: :desc)
             |> Ash.read()

    by_currency =
      balances
      |> Enum.reduce(%{}, fn row, acc -> Map.put_new(acc, row.currency, row.amount) end)

    assert Decimal.equal?(by_currency["BTC"], Decimal.new("0.01"))
    assert Decimal.equal?(by_currency["JPY"], Decimal.new("950000"))
  end

  test "paper market fill applies fee and slippage adversely" do
    previous = Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper)

    Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper,
      slippage_bps: "0",
      fee_bps: "10"
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper, previous) end)

    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0")

    assert {:ok, %Order{status: :filled, price: price}} =
             System.submit_order(valid_command("paper-fee-1"),
               positions: [],
               trade_mode: :paper
             )

    # LTP 5_000_000 * (1 + 10bps) = 5_005_000
    assert Decimal.equal?(price, Decimal.new("5005000"))

    assert {:ok, balances} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.Query.sort(captured_at: :desc)
             |> Ash.read()

    by_currency =
      balances
      |> Enum.reduce(%{}, fn row, acc -> Map.put_new(acc, row.currency, row.amount) end)

    assert Decimal.equal?(by_currency["JPY"], Decimal.new("949950"))
  end

  test "paper buy reserve uses adverse price so fill cannot overspend" do
    previous = Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper)

    Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper,
      slippage_bps: "0",
      fee_bps: "10"
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper, previous) end)

    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    # LTP 5_000_000 * 0.01 = 50_000、fee 10bps 後は 50_050 必要
    seed_paper_balance!("JPY", "50000")
    seed_paper_balance!("BTC", "0")

    assert {:error, :limit_exceeded, %{limit: :insufficient_balance}} =
             System.submit_order(valid_command("paper-reserve-1"),
               positions: [],
               trade_mode: :paper
             )
  end

  test "paper limit Order.price matches adverse fill price" do
    previous = Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper)

    Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper,
      slippage_bps: "50",
      fee_bps: "10"
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper, previous) end)

    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")

    assert {:ok, %Order{status: :filled, price: price}} =
             System.submit_order(
               valid_command("paper-limit-fee", %{
                 order_type: :limit,
                 price: Decimal.new("5100000"),
                 side: :buy
               }),
               positions: [],
               trade_mode: :paper
             )

    # 指値は fee のみ（slippage 無視）: 5_100_000 * 1.001
    assert Decimal.equal?(price, Decimal.new("5105100"))
  end

  test "paper round-trip at same LTP realizes fee loss" do
    previous = Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper)

    Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper,
      slippage_bps: "0",
      fee_bps: "10"
    )

    on_exit(fn -> Application.put_env(:bitflyer, Bitflyer.OrderExecutor.Paper, previous) end)

    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0")

    assert {:ok, %Order{status: :filled}} =
             System.submit_order(valid_command("paper-rt-buy", %{side: :buy}),
               positions: [],
               trade_mode: :paper
             )

    assert {:ok, %Order{status: :filled}} =
             System.submit_order(valid_command("paper-rt-sell", %{side: :sell}),
               positions: [],
               trade_mode: :paper
             )

    assert {:ok, fills} =
             Fill
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.read()

    realized =
      fills
      |> Enum.map(& &1.realized_pnl)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    # open 5_005_000 / close 4_995_000 → (4_995_000 - 5_005_000) * 0.01 = -100
    assert Decimal.lt?(realized, Decimal.new(0))
    assert Decimal.equal?(realized, Decimal.new("-100"))
  end

  test "paper limit fills when LTP crosses and grows balance rows" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")

    assert {:ok, %Order{status: :filled}} =
             System.submit_order(
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
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0")

    assert {:ok, before} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper)
             |> Ash.read()

    assert {:ok, %Order{status: :pending}} =
             System.submit_order(
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
             |> Ash.Query.filter(product_code == "BTC_JPY" and trade_mode == :paper)
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
          System.submit_order(valid_command("paper-concurrent-#{i}"),
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
             |> Ash.Query.sort(captured_at: :desc, id: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    assert {:ok, %BalanceSnapshot{amount: btc}} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "BTC")
             |> Ash.Query.sort(captured_at: :desc, id: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    # 1_000_000 - 2 * (0.01 * 5_000_000)
    assert Decimal.equal?(jpy, Decimal.new("900000"))
    assert Decimal.equal?(btc, Decimal.new("0.02"))
  end

  test "concurrent buy and sell paper fills avoid balance lock deadlock" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_paper_balance!("JPY", "1000000")
    seed_paper_balance!("BTC", "0.01")

    results =
      [
        Task.async(fn ->
          System.submit_order(
            valid_command("paper-deadlock-buy", %{side: :buy}),
            positions: [],
            trade_mode: :paper
          )
        end),
        Task.async(fn ->
          System.submit_order(
            valid_command("paper-deadlock-sell", %{side: :sell}),
            positions: [],
            trade_mode: :paper
          )
        end)
      ]
      |> Task.await_many(15_000)

    assert Enum.all?(results, &match?({:ok, %Order{status: :filled}}, &1))

    assert {:ok, %BalanceSnapshot{amount: jpy}} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "JPY")
             |> Ash.Query.sort(captured_at: :desc, id: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    assert {:ok, %BalanceSnapshot{amount: btc}} =
             BalanceSnapshot
             |> Ash.Query.filter(trade_mode == :paper and currency == "BTC")
             |> Ash.Query.sort(captured_at: :desc, id: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one()

    # buy と sell が同サイズ・同価格ならネットは初期残高に戻る
    assert Decimal.equal?(jpy, Decimal.new("1000000"))
    assert Decimal.equal?(btc, Decimal.new("0.01"))
  end

  test "idempotent submit does not call place_order again" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, %Order{}} =
             System.submit_order(valid_command("idem-1"), positions: [], trade_mode: :dry_run)

    assert {:ok, %Order{internal_order_id: "idem-1"}, :idempotent} =
             System.submit_order(valid_command("idem-1"), positions: [], trade_mode: :dry_run)

    assert SpyExchange.place_count() == 0
  end

  test "live without confirm rejects and does not call place_order" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, false)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    assert {:error, :exchange_halted, %{reason: :live_confirm_missing}} =
             System.submit_order(valid_command("live-halt-1"),
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
    seed_balance_cache!(:live)

    assert {:ok, %Order{status: :pending, exchange_order_id: "ex-live-ok-1"}} =
             System.submit_order(valid_command("live-ok-1"),
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
    seed_balance_cache!(:live)

    SpyExchange.set_next_result({:error, :timeout})

    assert {:error, :submission_unknown, %{reason: :timeout}} =
             System.submit_order(valid_command("live-timeout-1"),
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
             System.submit_order(valid_command("live-timeout-2"),
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
    seed_balance_cache!(:live)

    SpyExchange.set_next_result({:error, :disconnected})

    assert {:error, :submission_unknown, %{reason: :disconnected}} =
             System.submit_order(valid_command("live-disc-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:ok, %Order{status: :submission_unknown}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-disc-1")
             |> Ash.read_one()

    assert Readiness.get() == {:halted, :submission_unknown}
  end

  test "live single definite exchange rejection stays rejected without halt" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    SpyExchange.set_next_result({:error, :rejected_by_exchange})

    assert {:error, :exchange_error, %{reason: :rejected_by_exchange}} =
             System.submit_order(valid_command("live-rej-1"),
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
             System.submit_order(valid_command("live-rej-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 2
  end

  test "live auth_failed rejects order and opens circuit immediately" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    SpyExchange.set_next_result({:error, :auth_failed})

    assert {:error, :exchange_error, %{reason: :auth_failed}} =
             System.submit_order(valid_command("live-auth-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:ok, %Order{status: :rejected}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-auth-1")
             |> Ash.read_one()

    assert Readiness.get() == {:halted, :auth_failed}

    SpyExchange.set_next_result(:success)

    assert {:error, :circuit_open, _} =
             System.submit_order(valid_command("live-auth-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1
  end

  test "live consecutive exchange rejections open circuit at window max" do
    previous_risk = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.merge(previous_risk,
        max_exchange_errors_per_window: 3,
        exchange_error_window_ms: 60_000
      )
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.Risk, previous_risk)
    end)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    for i <- 1..2 do
      SpyExchange.set_next_result({:error, :rejected_by_exchange})

      assert {:error, :exchange_error, %{reason: :rejected_by_exchange}} =
               System.submit_order(valid_command("live-consec-#{i}"),
                 positions: [],
                 trade_mode: :live
               )

      assert Readiness.get() == :ready
    end

    SpyExchange.set_next_result({:error, :rejected_by_exchange})

    assert {:error, :exchange_error, %{reason: :rejected_by_exchange}} =
             System.submit_order(valid_command("live-consec-3"),
               positions: [],
               trade_mode: :live
             )

    assert Readiness.get() == {:halted, :consecutive_exchange_errors}

    SpyExchange.set_next_result(:success)

    assert {:error, :circuit_open, _} =
             System.submit_order(valid_command("live-consec-4"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 3
  end

  test "live persist failure after place_order halts and blocks further submits" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    persist_fail = fn _order, _exchange_order_id ->
      {:error, :forced_persist_failure}
    end

    assert {:error, :persist_failed,
            %{
              internal_order_id: "live-persist-1",
              exchange_order_id: "ex-live-persist-1"
            }} =
             System.submit_order(valid_command("live-persist-1"),
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
             System.submit_order(valid_command("live-persist-1"),
               positions: [],
               trade_mode: :live
             )

    assert {:error, :circuit_open, _} =
             System.submit_order(valid_command("live-persist-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-persist-2")
             |> Ash.read_one()
  end

  test "live fill sync failure after place_order halts and blocks further submits" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    assert {:error, :fill_sync_failed,
            %{
              order_accepted: true,
              internal_order_id: "live-fill-sync-1",
              exchange_order_id: "ex-live-fill-sync-1"
            }} =
             System.submit_order(valid_command("live-fill-sync-1"),
               positions: [],
               trade_mode: :live,
               exchange: BrokenPostPlaceFillExchange
             )

    assert SpyExchange.place_count() == 1
    assert Readiness.get() == {:halted, :fill_sync_failed}

    assert {:ok, %RiskState{halted: true, reason: "fill_sync_failed"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()

    assert {:ok, %Order{status: :pending, exchange_order_id: "ex-live-fill-sync-1"}} =
             Order
             |> Ash.Query.filter(internal_order_id == "live-fill-sync-1")
             |> Ash.read_one()

    assert {:error, :circuit_open, _} =
             System.submit_order(valid_command("live-fill-sync-2"),
               positions: [],
               trade_mode: :live
             )

    assert SpyExchange.place_count() == 1
  end

  test "live submit syncs open orders once before authorize, not again in do_submit" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    {:ok, _} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "live-open-pre",
        exchange_order_id: "ex-live-open-pre",
        product_code: "BTC_JPY",
        side: :buy,
        status: :pending,
        order_type: :market,
        size: Decimal.new("1"),
        filled_size: Decimal.new("0"),
        filled_notional: Decimal.new("0"),
        trade_mode: :live
      })
      |> Ash.create()

    assert {:ok, %Order{exchange_order_id: "ex-live-dual-1"}} =
             System.submit_order(valid_command("live-dual-1"),
               positions: [],
               trade_mode: :live
             )

    # 認可前に open 1 件 + 発注後に新規 1 件。do_submit 内の二重 sync があると open がもう 1 回増える
    assert SpyExchange.fetch_count() == 2
    assert SpyExchange.place_count() == 1
  end

  test "risk rejection prevents order persistence" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.get() == :not_ready

    assert {:error, :unsynced, _} =
             System.submit_order(valid_command("risk-1"), positions: [], trade_mode: :dry_run)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "risk-1")
             |> Ash.read_one()

    assert SpyExchange.place_count() == 0
  end

  test "raw command map is rejected by OrderExecutor.submit" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.get() == :not_ready

    assert_raise FunctionClauseError, fn ->
      OrderExecutor.submit(valid_command("risk-bypass-1"),
        positions: [],
        trade_mode: :dry_run
      )
    end

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "risk-bypass-1")
             |> Ash.read_one()

    assert SpyExchange.place_count() == 0
  end

  test "forged AuthorizedOrder cannot bypass risk authorize" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.get() == :not_ready

    forged = %Bitflyer.Risk.AuthorizedOrder{
      token: make_ref(),
      command: valid_command("risk-forge-1"),
      authorized_at_ms: Elixir.System.monotonic_time(:millisecond)
    }

    assert {:error, :unauthorized, %{reason: :authorization_missing}} =
             OrderExecutor.submit(forged, positions: [], trade_mode: :dry_run)

    assert {:ok, nil} =
             Order
             |> Ash.Query.filter(internal_order_id == "risk-forge-1")
             |> Ash.read_one()

    assert SpyExchange.place_count() == 0
  end

  test "dry_run cancel marks cancelled without place_order" do
    Application.put_env(:bitflyer, :trade_mode, :dry_run)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert {:ok, order} =
             System.submit_order(valid_command("cancel-dry-1"),
               positions: [],
               trade_mode: :dry_run
             )

    assert order.status == :pending

    assert {:ok, cancelled} = OrderExecutor.cancel(order)
    assert cancelled.status == :cancelled
    assert SpyExchange.place_count() == 0
  end

  test "live cancel calls exchange cancel_order when gated" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    assert {:ok, order} =
             System.submit_order(valid_command("cancel-live-1"),
               positions: [],
               trade_mode: :live
             )

    assert order.exchange_order_id == "ex-cancel-live-1"

    assert {:ok, updated} = OrderExecutor.cancel(order)
    assert updated.status == :pending
    assert_received {:cancel_order, %{exchange_order_id: "ex-cancel-live-1"}}
  end

  test "live cancel auth_failed opens circuit immediately" do
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    assert {:ok, order} =
             System.submit_order(valid_command("cancel-auth-1"),
               positions: [],
               trade_mode: :live
             )

    SpyExchange.set_next_cancel_result({:error, :auth_failed})

    assert {:error, :exchange_error, %{reason: :auth_failed}} = OrderExecutor.cancel(order)
    assert Readiness.get() == {:halted, :auth_failed}

    assert {:error, :circuit_open, _} =
             System.submit_order(valid_command("cancel-auth-2"),
               positions: [],
               trade_mode: :live
             )
  end

  test "live cancel consecutive rejections open circuit at window max" do
    previous_risk = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.merge(previous_risk,
        max_exchange_errors_per_window: 3,
        exchange_error_window_ms: 60_000
      )
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.Risk, previous_risk)
    end)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    for i <- 1..3 do
      assert {:ok, order} =
               System.submit_order(valid_command("cancel-consec-#{i}"),
                 positions: [],
                 trade_mode: :live
               )

      SpyExchange.set_next_cancel_result({:error, :rejected_by_exchange})

      assert {:error, :exchange_error, %{reason: :rejected_by_exchange}} =
               OrderExecutor.cancel(order)

      if i < 3 do
        assert Readiness.get() == :ready
      end
    end

    assert Readiness.get() == {:halted, :consecutive_exchange_errors}
  end

  test "live cancel order_not_found does not open consecutive circuit" do
    previous_risk = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    Application.put_env(
      :bitflyer,
      Bitflyer.Risk,
      Keyword.merge(previous_risk,
        max_exchange_errors_per_window: 2,
        exchange_error_window_ms: 60_000
      )
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.Risk, previous_risk)
    end)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)
    assert Readiness.mark_ready() == :ok
    put_fresh_market()
    seed_balance_cache!(:live)

    for i <- 1..3 do
      assert {:ok, order} =
               System.submit_order(valid_command("cancel-notfound-#{i}"),
                 positions: [],
                 trade_mode: :live
               )

      SpyExchange.set_next_cancel_result({:error, :order_not_found})

      assert {:error, :exchange_error, %{reason: :order_not_found}} =
               OrderExecutor.cancel(order)

      assert Readiness.get() == :ready
    end
  end

  defp valid_command(internal_order_id, overrides \\ %{}) do
    Map.merge(
      %{
        internal_order_id: internal_order_id,
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: @market_key,
        order_type: :market
      },
      overrides
    )
  end

  defp put_fresh_market do
    assert put_fresh_ticker(@market_key) == :ok
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

    assert :ok = Bitflyer.Risk.BalanceCache.refresh(:paper)
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
