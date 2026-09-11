defmodule Bitflyer.Regression.CapitalPreservationTest do
  @moduledoc """
  P2 #17 資金保全の回帰。

  部品テストは各モジュールに任せ、ここでは縦貫通の安全ネットだけを固定する。
  - 重複 intent（冪等）
  - trade_mode 分離
  - boot reconcile halt → 発注不可
  - risk 拒否が executor 経由でも永続化・REST を起こさない
  - live submission 不明（timeout）→ halt・再送禁止
  - live exchange_order_id 永続化失敗 → halt・再送禁止
  - live 空 BalanceSnapshot → baseline missing で halt
  - raw map / 偽造 AuthorizedOrder は OrderExecutor に通せない
  - System.submit_order は常に Risk を通す
  - risk limits（価格逸脱・頻度・日次損失・残高）拒否で永続化・REST しない
  - paper/live の Fill→DailyLoss→halt 縦貫通（注入なし）
  """

  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.OrderRateHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.AuthorizedOrder
  alias Bitflyer.Startup.{Reconcile, Reconciler}
  alias Bitflyer.System
  alias Bitflyer.Trading.{Order, Position, RiskState}

  @product "BTC_JPY"
  @market_key {:ticker, @product}

  defmodule SpyExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(request) do
      Agent.update(__MODULE__.Counter, fn n -> n + 1 end)
      {:ok, %{exchange_order_id: "ex-" <> request.internal_order_id}}
    end

    def start_counter, do: Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
    def place_count, do: Agent.get(__MODULE__.Counter, & &1)
  end

  defmodule CancelOkExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_request), do: :ok

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      case Process.get({:fill_order, id}) do
        %{} = info ->
          {:ok, Map.put(info, :status, :canceled)}

        _ ->
          {:ok,
           %{
             exchange_order_id: id,
             product_code: "BTC_JPY",
             side: :buy,
             size: Decimal.new("0.01"),
             filled_size: Decimal.new("0"),
             average_price: nil,
             status: :canceled
           }}
      end
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule CancelKeepOpenExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_request), do: :ok

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      {:ok,
       %{
         exchange_order_id: id,
         product_code: "BTC_JPY",
         side: :buy,
         size: Decimal.new("0.01"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :active
       }}
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule PartialFillExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      case Process.get({:fill_order, id}) do
        nil -> {:error, :order_not_found}
        info -> {:ok, info}
      end
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule LossFillExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_), do: {:error, :not_used}

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      case Process.get({:fill_order, id}) do
        nil -> {:error, :order_not_found}
        info -> {:ok, info}
      end
    end

    @impl true
    def fetch_executions(_), do: {:ok, []}

    @impl true
    def list_child_orders(_), do: {:ok, []}
  end

  defmodule MismatchExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [
           %{
             product_code: "BTC_JPY",
             side: :buy,
             size: Decimal.new("0.01"),
             average_price: Decimal.new("5000000")
           }
         ],
         balances: [],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :must_not_place}
  end

  defmodule TimeoutExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(_request) do
      Agent.update(__MODULE__.Counter, fn n -> n + 1 end)
      {:error, :timeout}
    end

    def start_counter, do: Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
    def place_count, do: Agent.get(__MODULE__.Counter, & &1)

    def stop_counter do
      case Process.whereis(__MODULE__.Counter) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end
  end

  setup do
    reset_readiness()
    reset_market_data_cache()
    reset_order_rate()
    reset_daily_loss()
    reset_balance_cache()
    clear_default_risk_state()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)

    {:ok, _} = SpyExchange.start_counter()
    Application.put_env(:bitflyer, :exchange_client, SpyExchange)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
      reset_order_rate()
      reset_daily_loss()
      reset_balance_cache()
      clear_default_risk_state()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
      Application.put_env(:bitflyer, :exchange_client, previous_client)
      Application.put_env(:bitflyer, :live_confirmed, previous_confirm)

      if Process.whereis(SpyExchange.Counter), do: Agent.stop(SpyExchange.Counter)
    end)

    :ok
  end

  describe "duplicate intent" do
    test "duplicate submit is idempotent and does not double-apply position or REST" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_paper_balances!()

      assert {:ok, %Order{status: :filled}} =
               System.submit_order(command("dup-1"), trade_mode: :paper)

      assert {:ok, %Order{internal_order_id: "dup-1"}, :idempotent} =
               System.submit_order(command("dup-1"), trade_mode: :paper)

      assert SpyExchange.place_count() == 0

      assert {:ok, %Position{size: size}} =
               Position
               |> Ash.Query.filter(product_code == ^@product and trade_mode == :paper)
               |> Ash.read_one()

      assert Decimal.equal?(size, Decimal.new("0.01"))

      assert {:ok, %Order{}} =
               Order
               |> Ash.Query.filter(internal_order_id == "dup-1")
               |> Ash.read_one()
    end
  end

  describe "trade_mode isolation" do
    test "paper fill does not mutate live position" do
      assert {:ok, live_pos} =
               Position
               |> Ash.Changeset.for_create(:create, %{
                 product_code: @product,
                 side: :buy,
                 size: Decimal.new("0.50"),
                 average_price: Decimal.new("4000000"),
                 trade_mode: :live
               })
               |> Ash.create()

      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_paper_balances!()

      assert {:ok, %Order{status: :filled, trade_mode: :paper}} =
               System.submit_order(command("iso-paper-1"), trade_mode: :paper)

      assert SpyExchange.place_count() == 0

      assert {:ok, %Position{size: live_size, side: :buy}} =
               Position
               |> Ash.Query.filter(id == ^live_pos.id)
               |> Ash.read_one()

      assert Decimal.equal?(live_size, Decimal.new("0.50"))

      assert {:ok, %Position{size: paper_size}} =
               Position
               |> Ash.Query.filter(product_code == ^@product and trade_mode == :paper)
               |> Ash.read_one()

      assert Decimal.equal?(paper_size, Decimal.new("0.01"))
    end

    test "risk position limits load only current trade_mode rows" do
      assert {:ok, _} =
               Position
               |> Ash.Changeset.for_create(:create, %{
                 product_code: @product,
                 side: :buy,
                 size: Decimal.new("4.5"),
                 average_price: Decimal.new("4000000"),
                 trade_mode: :live
               })
               |> Ash.create()

      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_paper_balances!()

      limits = %{
        max_order_size: Decimal.new("1"),
        max_position_size: Decimal.new("0.05"),
        market_data_max_age_ms: 5_000
      }

      # live 建玉を見ると超えるが、paper は空なので通る
      assert {:ok, %AuthorizedOrder{}} =
               Risk.authorize(command("iso-risk-1"),
                 trade_mode: :paper,
                 limits: limits
               )

      assert {:ok, %Order{}} =
               System.submit_order(command("iso-risk-1"),
                 trade_mode: :paper,
                 limits: limits
               )
    end
  end

  describe "boot reconcile halt" do
    test "reconcile mismatch keeps halted and blocks submit without REST" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :exchange_client, MismatchExchange)

      assert {:error, :reconcile_mismatch} = Reconciler.run_now()
      assert Readiness.get() == {:halted, :reconcile_mismatch}

      put_fresh_market()

      assert {:error, :circuit_open, %{readiness: :reconcile_mismatch}} =
               System.submit_order(command("halt-1"), trade_mode: :live)

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "halt-1")
               |> Ash.read_one()
    end

    test "empty balance baseline on live halts and blocks submit without REST" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :exchange_client, SpyExchange)

      assert {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing}} =
               Reconcile.run(trade_mode: :live, exchange: SpyExchange)

      assert {:error, :reconcile_mismatch} = Reconciler.run_now()
      assert Readiness.get() == {:halted, :reconcile_mismatch}

      put_fresh_market()

      assert {:error, :circuit_open, _} =
               System.submit_order(command("baseline-1"), trade_mode: :live)

      assert SpyExchange.place_count() == 0
    end

    test "persisted risk halt blocks ready and submit" do
      halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: true,
                 reason: "reconcile_mismatch",
                 halted_at: halted_at
               })
               |> Ash.create()

      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert {:error, :reconcile_mismatch} = Reconciler.run_now()
      assert Readiness.get() == {:halted, :reconcile_mismatch}

      put_fresh_market()

      assert {:error, :circuit_open, _} =
               System.submit_order(command("halt-persist-1"), trade_mode: :dry_run)

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "halt-persist-1")
               |> Ash.read_one()
    end
  end

  describe "risk rejection through executor" do
    test "stale market data rejects submit without persistence or REST" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok

      now = Cache.monotonic_ms()
      assert Cache.put(@market_key, %{ltp: Decimal.new("1")}, received_at: now - 60_000) == :ok

      assert {:error, :stale, _} =
               System.submit_order(command("stale-1"), trade_mode: :dry_run, now: now)

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "stale-1")
               |> Ash.read_one()
    end

    test "order size over limit rejects submit without persistence" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      limits = %{
        max_order_size: Decimal.new("0.001"),
        max_position_size: Decimal.new("5"),
        market_data_max_age_ms: 5_000
      }

      assert {:error, :limit_exceeded, %{limit: :max_order_size}} =
               System.submit_order(command("limit-1"),
                 trade_mode: :dry_run,
                 limits: limits,
                 positions: []
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "limit-1")
               |> Ash.read_one()
    end

    test "open circuit rejects submit without REST" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      assert :ok = Risk.open_circuit(:limit_exceeded)

      assert {:error, :circuit_open, _} =
               System.submit_order(command("circuit-1"),
                 trade_mode: :dry_run,
                 positions: []
               )

      assert SpyExchange.place_count() == 0
      assert Readiness.get() == {:halted, :limit_exceeded}
    end

    test "raw command map cannot call OrderExecutor.submit" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.get() == :not_ready

      assert_raise FunctionClauseError, fn ->
        OrderExecutor.submit(command("bypass-1"), trade_mode: :dry_run, positions: [])
      end

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bypass-1")
               |> Ash.read_one()
    end

    test "forged AuthorizedOrder cannot bypass risk" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.get() == :not_ready

      forged = %AuthorizedOrder{
        token: make_ref(),
        command: command("bypass-forge-1"),
        authorized_at_ms: Elixir.System.monotonic_time(:millisecond)
      }

      assert {:error, :unauthorized, %{reason: :authorization_missing}} =
               OrderExecutor.submit(forged, trade_mode: :dry_run, positions: [])

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bypass-forge-1")
               |> Ash.read_one()
    end

    test "System.submit_order always runs risk authorize" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.get() == :not_ready

      assert {:error, :unsynced, _} =
               System.submit_order(command("bypass-sys-1"),
                 trade_mode: :dry_run,
                 positions: []
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bypass-sys-1")
               |> Ash.read_one()
    end

    test "price deviation rejects submit without persistence" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      assert {:error, :limit_exceeded, %{limit: :max_price_deviation_pct}} =
               System.submit_order(
                 command("dev-1", %{
                   order_type: :limit,
                   price: Decimal.new("5200000")
                 }),
                 trade_mode: :dry_run,
                 positions: [],
                 limits: %{max_price_deviation_pct: Decimal.new("1")}
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "dev-1")
               |> Ash.read_one()
    end

    test "order rate rejects submit without persistence" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      assert {:error, :limit_exceeded, %{limit: :max_orders_per_minute}} =
               System.submit_order(command("rate-1"),
                 trade_mode: :dry_run,
                 positions: [],
                 recent_order_count: 5,
                 limits: %{max_orders_per_minute: 3}
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "rate-1")
               |> Ash.read_one()
    end

    test "daily loss rejects submit, opens circuit, and blocks further submit" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
               System.submit_order(command("loss-1"),
                 trade_mode: :dry_run,
                 positions: [],
                 daily_loss: Decimal.new("200000"),
                 limits: %{max_daily_loss: Decimal.new("100000")}
               )

      assert SpyExchange.place_count() == 0
      assert Readiness.get() == {:halted, :daily_loss_exceeded}

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "loss-1")
               |> Ash.read_one()

      assert {:error, :circuit_open, _} =
               System.submit_order(command("loss-2"), trade_mode: :dry_run, positions: [])

      assert SpyExchange.place_count() == 0
    end

    test "paper fill→DailyLoss→halt without daily_loss injection" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))
      seed_paper_balances!()

      # 建玉 0.1 @ 5M。決済 0.1 @ 3.999M → 実現損 100_100 > 100_000
      assert {:ok, %Order{status: :filled}} =
               System.submit_order(
                 command("paper-loss-open", %{size: Decimal.new("0.1")}),
                 trade_mode: :paper,
                 limits: %{
                   max_daily_loss: Decimal.new("100000"),
                   max_order_size: Decimal.new("1")
                 }
               )

      put_fresh_market(Decimal.new("3999000"))

      assert {:ok, %Order{status: :filled}} =
               System.submit_order(
                 command("paper-loss-close", %{side: :sell, size: Decimal.new("0.1")}),
                 trade_mode: :paper,
                 limits: %{
                   max_daily_loss: Decimal.new("100000"),
                   max_order_size: Decimal.new("1")
                 }
               )

      assert {:ok, loss} = Bitflyer.Risk.DailyLoss.get(:paper)
      assert Decimal.gt?(loss, Decimal.new("100000"))

      put_fresh_market(Decimal.new("5000000"))

      assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
               System.submit_order(command("paper-loss-next"),
                 trade_mode: :paper,
                 limits: %{max_daily_loss: Decimal.new("100000")}
               )

      assert SpyExchange.place_count() == 0
      assert Readiness.get() == {:halted, :daily_loss_exceeded}
    end

    test "live fill→DailyLoss→halt without daily_loss injection" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()

      {:ok, open_order} =
        Order
        |> Ash.Changeset.for_create(:create, %{
          internal_order_id: "live-loss-open",
          exchange_order_id: "JRF-loss-open",
          product_code: @product,
          side: :buy,
          status: :pending,
          order_type: :market,
          size: Decimal.new("0.1"),
          filled_size: Decimal.new("0"),
          trade_mode: :live
        })
        |> Ash.create()

      Process.put({:fill_order, "JRF-loss-open"}, %{
        exchange_order_id: "JRF-loss-open",
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.1"),
        filled_size: Decimal.new("0.1"),
        average_price: Decimal.new("5000000"),
        status: :completed
      })

      assert {:ok, _} =
               Bitflyer.OrderExecutor.LiveFills.sync_order(open_order, exchange: LossFillExchange)

      {:ok, close_order} =
        Order
        |> Ash.Changeset.for_create(:create, %{
          internal_order_id: "live-loss-close",
          exchange_order_id: "JRF-loss-close",
          product_code: @product,
          side: :sell,
          status: :pending,
          order_type: :market,
          size: Decimal.new("0.1"),
          filled_size: Decimal.new("0"),
          trade_mode: :live
        })
        |> Ash.create()

      Process.put({:fill_order, "JRF-loss-close"}, %{
        exchange_order_id: "JRF-loss-close",
        product_code: @product,
        side: :sell,
        size: Decimal.new("0.1"),
        filled_size: Decimal.new("0.1"),
        average_price: Decimal.new("3999000"),
        status: :completed
      })

      assert {:ok, _} =
               Bitflyer.OrderExecutor.LiveFills.sync_order(close_order,
                 exchange: LossFillExchange
               )

      assert {:ok, loss} = Bitflyer.Risk.DailyLoss.get(:live)
      assert Decimal.gt?(loss, Decimal.new("100000"))

      assert {:error, :limit_exceeded, %{limit: :max_daily_loss}} =
               System.submit_order(command("live-loss-next"),
                 trade_mode: :live,
                 positions: [],
                 exchange: LossFillExchange,
                 limits: %{max_daily_loss: Decimal.new("100000")}
               )

      assert SpyExchange.place_count() == 0
      assert Readiness.get() == {:halted, :daily_loss_exceeded}
    end

    test "insufficient balance rejects submit without persistence" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_balance_cache!(:paper, %{"JPY" => Decimal.new("1"), "BTC" => Decimal.new("0")})

      assert {:error, :limit_exceeded, %{limit: :insufficient_balance}} =
               System.submit_order(
                 command("bal-1", %{
                   order_type: :limit,
                   price: Decimal.new("5000000")
                 }),
                 trade_mode: :paper,
                 positions: []
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bal-1")
               |> Ash.read_one()
    end

    test "paper BalanceCache unsynced rejects submit without injection" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      assert :ok = Bitflyer.Risk.BalanceCache.mark_unsynced(:paper)

      assert {:error, :unsynced, %{reason: :balance_unsynced}} =
               System.submit_order(command("bal-unsynced-1"),
                 trade_mode: :paper,
                 positions: []
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bal-unsynced-1")
               |> Ash.read_one()
    end

    test "paper fill reduces BalanceCache and blocks next overspend without injection" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_paper_balances!(%{
        "JPY" => Decimal.new("60000"),
        "BTC" => Decimal.new("0")
      })

      assert {:ok, %Order{status: :filled}} =
               System.submit_order(
                 command("paper-bal-1", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :paper,
                 positions: []
               )

      assert {:ok, balances} = Bitflyer.Risk.BalanceCache.get(:paper)
      assert Decimal.equal?(balances["JPY"], Decimal.new("10000"))

      assert {:error, :limit_exceeded, %{limit: :insufficient_balance}} =
               System.submit_order(
                 command("paper-bal-2", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :paper,
                 positions: []
               )

      assert SpyExchange.place_count() == 0
    end

    test "paper pending hold survives another order fill reload without inflate" do
      Application.put_env(:bitflyer, :trade_mode, :paper)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_paper_balances!(%{
        "JPY" => Decimal.new("200000"),
        "BTC" => Decimal.new("0")
      })

      # LTP 未交差の指値 → pending + hold 49_000
      assert {:ok, %Order{status: :pending} = pending} =
               System.submit_order(
                 command("paper-pend-a", %{
                   order_type: :limit,
                   price: Decimal.new("4900000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :paper,
                 positions: []
               )

      assert {:ok, after_pend} = Bitflyer.Risk.BalanceCache.get(:paper)
      assert Decimal.equal?(after_pend["JPY"], Decimal.new("151000"))

      # 別注文が fill → Snapshot reload。pending hold は再適用される
      assert {:ok, %Order{status: :filled}} =
               System.submit_order(
                 command("paper-fill-b", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :paper,
                 positions: []
               )

      assert {:ok, after_fill} = Bitflyer.Risk.BalanceCache.get(:paper)
      # tip: 200000 - 50000(fill B) = 150000、再適用 hold A 49_000 → 101000
      assert Decimal.equal?(after_fill["JPY"], Decimal.new("101000"))

      assert {:ok, _} = OrderExecutor.cancel(pending)

      assert {:ok, after_cancel} = Bitflyer.Risk.BalanceCache.get(:paper)
      assert Decimal.equal?(after_cancel["JPY"], Decimal.new("150000"))
    end

    test "live reserve blocks second submit before reconcile without overstating" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_balance_cache!(:live, %{
        "JPY" => Decimal.new("60000"),
        "BTC" => Decimal.new("0")
      })

      assert {:ok, %Order{status: :pending}} =
               System.submit_order(
                 command("live-reserve-1", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :live,
                 positions: []
               )

      assert SpyExchange.place_count() == 1

      assert {:ok, balances} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(balances["JPY"], Decimal.new("10000"))

      assert {:error, :limit_exceeded, %{limit: :insufficient_balance}} =
               System.submit_order(
                 command("live-reserve-2", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :live,
                 positions: []
               )

      assert SpyExchange.place_count() == 1
    end

    test "live market cancel releases reserved LTP1 not a higher LTP2" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_balance_cache!(:live, %{
        "JPY" => Decimal.new("100000"),
        "BTC" => Decimal.new("0")
      })

      assert {:ok, order} =
               System.submit_order(
                 command("live-mkt-cancel-1", %{
                   order_type: :market,
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :live,
                 positions: []
               )

      assert {:ok, after_reserve} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(after_reserve["JPY"], Decimal.new("50000"))

      # cancel 時に LTP が上がっても、拘束は submit 時の 50_000 だけ戻る
      put_fresh_market(Decimal.new("8000000"))

      assert {:ok, _} = OrderExecutor.cancel(order, exchange: CancelOkExchange)

      assert {:ok, after_cancel} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(after_cancel["JPY"], Decimal.new("100000"))
    end

    test "live partial fill then cancel releases only remaining hold" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_balance_cache!(:live, %{
        "JPY" => Decimal.new("100000"),
        "BTC" => Decimal.new("0")
      })

      assert {:ok, order} =
               System.submit_order(
                 command("live-partial-1", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.02")
                 }),
                 trade_mode: :live,
                 positions: []
               )

      assert {:ok, after_reserve} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(after_reserve["JPY"], Decimal.new("0"))

      Process.put({:fill_order, order.exchange_order_id}, %{
        exchange_order_id: order.exchange_order_id,
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.02"),
        filled_size: Decimal.new("0.01"),
        average_price: Decimal.new("5000000"),
        status: :active
      })

      assert {:ok, %Order{status: :partially_filled} = partial} =
               Bitflyer.OrderExecutor.LiveFills.sync_order(order, exchange: PartialFillExchange)

      assert {:ok, _} = OrderExecutor.cancel(partial, exchange: CancelOkExchange)

      assert {:ok, after_cancel} = Bitflyer.Risk.BalanceCache.get(:live)
      # 半分消費・半分返却 → 50_000（フル返却の 100_000 にならない）
      assert Decimal.equal?(after_cancel["JPY"], Decimal.new("50000"))
    end

    test "live cancel that stays open keeps hold until delayed fill settles" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market(Decimal.new("5000000"))

      seed_balance_cache!(:live, %{
        "JPY" => Decimal.new("50000"),
        "BTC" => Decimal.new("0")
      })

      assert {:ok, order} =
               System.submit_order(
                 command("live-open-cancel-1", %{
                   order_type: :limit,
                   price: Decimal.new("5000000"),
                   size: Decimal.new("0.01")
                 }),
                 trade_mode: :live,
                 positions: []
               )

      assert {:ok, reserved} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(reserved["JPY"], Decimal.new("0"))

      assert {:ok, %Order{status: status} = open} =
               OrderExecutor.cancel(order, exchange: CancelKeepOpenExchange)

      assert status in [:pending, :partially_filled]

      # 未終端なので hold は残る（残高を戻さない）
      assert {:ok, still_held} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(still_held["JPY"], Decimal.new("0"))

      Process.put({:fill_order, open.exchange_order_id}, %{
        exchange_order_id: open.exchange_order_id,
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0.01"),
        average_price: Decimal.new("5000000"),
        status: :completed
      })

      assert {:ok, %Order{status: :filled}} =
               Bitflyer.OrderExecutor.LiveFills.sync_order(open, exchange: PartialFillExchange)

      assert {:ok, after_fill} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(after_fill["JPY"], Decimal.new("0"))
    end

    test "align_hold_to_filled prevents full release after missed consume" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      assert Readiness.mark_ready() == :ok

      seed_balance_cache!(:live, %{
        "JPY" => Decimal.new("100000"),
        "BTC" => Decimal.new("0")
      })

      assert :ok =
               Bitflyer.Risk.BalanceCache.reserve(:live, "JPY", Decimal.new("100000"),
                 hold_id: "missed-consume-1"
               )

      # consume 欠落を模擬: filled 半分なのに hold は当初のまま
      assert :ok =
               Bitflyer.Risk.BalanceCache.align_hold_to_filled(
                 :live,
                 "missed-consume-1",
                 Decimal.new("0.01"),
                 Decimal.new("0.02")
               )

      assert :ok = Bitflyer.Risk.BalanceCache.release_hold(:live, "missed-consume-1")
      assert {:ok, balances} = Bitflyer.Risk.BalanceCache.get(:live)
      assert Decimal.equal?(balances["JPY"], Decimal.new("50000"))
    end
  end

  describe "submission unknown" do
    test "live timeout halts and blocks resubmit without treating as rejected" do
      {:ok, _} = TimeoutExchange.start_counter()

      on_exit(fn ->
        TimeoutExchange.stop_counter()
      end)

      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      Application.put_env(:bitflyer, :exchange_client, TimeoutExchange)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_balance_cache!(:live)

      assert {:error, :submission_unknown, %{reason: :timeout}} =
               System.submit_order(command("unknown-1"),
                 trade_mode: :live,
                 positions: []
               )

      assert TimeoutExchange.place_count() == 1

      assert {:ok, %Order{status: :submission_unknown}} =
               Order
               |> Ash.Query.filter(internal_order_id == "unknown-1")
               |> Ash.read_one()

      assert Readiness.get() == {:halted, :submission_unknown}

      assert {:error, :circuit_open, _} =
               System.submit_order(command("unknown-2"),
                 trade_mode: :live,
                 positions: []
               )

      assert TimeoutExchange.place_count() == 1

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "unknown-2")
               |> Ash.read_one()
    end
  end

  describe "persist failed" do
    test "live exchange_order_id persist failure halts and blocks further REST" do
      Application.put_env(:bitflyer, :trade_mode, :live)
      Application.put_env(:bitflyer, :live_confirmed, true)
      assert Readiness.mark_ready() == :ok
      put_fresh_market()
      seed_balance_cache!(:live)

      persist_fail = fn _order, _id -> {:error, :forced_persist_failure} end

      assert {:error, :persist_failed, %{exchange_order_id: "ex-persist-halt-1"}} =
               System.submit_order(command("persist-halt-1"),
                 trade_mode: :live,
                 positions: [],
                 persist_exchange_order_id: persist_fail
               )

      assert SpyExchange.place_count() == 1
      assert Readiness.get() == {:halted, :persist_failed}

      assert {:error, :circuit_open, _} =
               System.submit_order(command("persist-halt-2"),
                 trade_mode: :live,
                 positions: []
               )

      assert SpyExchange.place_count() == 1
    end
  end

  defp command(internal_order_id, overrides \\ %{}) do
    Map.merge(
      %{
        internal_order_id: internal_order_id,
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: @market_key,
        order_type: :market
      },
      overrides
    )
  end

  defp put_fresh_market(ltp \\ Decimal.new("5000000")) do
    assert put_fresh_ticker(@market_key, ltp) == :ok
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
