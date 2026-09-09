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
  - 公開 submit は authorize?: false でも risk を迂回できない
  """

  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Startup.{Reconcile, Reconciler}
  alias Bitflyer.Trading.{Order, Position, RiskState}

  @product "FX_BTC_JPY"
  @market_key {:ticker, @product}

  defmodule SpyExchange do
    @behaviour Bitflyer.Exchange.Client

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

  defmodule MismatchExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [
           %{
             product_code: "FX_BTC_JPY",
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

    def stop_counter,
      do: if(Process.whereis(__MODULE__.Counter), do: Agent.stop(__MODULE__.Counter))
  end

  setup do
    reset_readiness()
    reset_market_data_cache()
    clear_default_risk_state()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    previous_client = Application.get_env(:bitflyer, :exchange_client)
    previous_confirm = Application.get_env(:bitflyer, :live_confirmed)

    {:ok, _} = SpyExchange.start_counter()
    Application.put_env(:bitflyer, :exchange_client, SpyExchange)

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
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

      assert {:ok, %Order{status: :filled}} =
               OrderExecutor.submit(command("dup-1"), trade_mode: :paper)

      assert {:ok, %Order{internal_order_id: "dup-1"}, :idempotent} =
               OrderExecutor.submit(command("dup-1"), trade_mode: :paper)

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

      assert {:ok, %Order{status: :filled, trade_mode: :paper}} =
               OrderExecutor.submit(command("iso-paper-1"), trade_mode: :paper)

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

      limits = %{
        max_order_size: Decimal.new("1"),
        max_position_size: Decimal.new("0.05"),
        market_data_max_age_ms: 5_000
      }

      # live 建玉を見ると超えるが、paper は空なので通る
      assert :ok =
               Risk.authorize(command("iso-risk-1"),
                 trade_mode: :paper,
                 limits: limits
               )

      assert {:ok, %Order{}} =
               OrderExecutor.submit(command("iso-risk-1"),
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
               OrderExecutor.submit(command("halt-1"), trade_mode: :live)

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
               OrderExecutor.submit(command("baseline-1"), trade_mode: :live)

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
               OrderExecutor.submit(command("halt-persist-1"), trade_mode: :dry_run)

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
               OrderExecutor.submit(command("stale-1"), trade_mode: :dry_run, now: now)

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
               OrderExecutor.submit(command("limit-1"),
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
               OrderExecutor.submit(command("circuit-1"),
                 trade_mode: :dry_run,
                 positions: []
               )

      assert SpyExchange.place_count() == 0
      assert Readiness.get() == {:halted, :limit_exceeded}
    end

    test "authorize?: false cannot bypass risk on public submit" do
      Application.put_env(:bitflyer, :trade_mode, :dry_run)
      assert Readiness.get() == :not_ready

      assert {:error, :unsynced, _} =
               OrderExecutor.submit(command("bypass-1"),
                 trade_mode: :dry_run,
                 positions: [],
                 authorize?: false
               )

      assert SpyExchange.place_count() == 0

      assert {:ok, nil} =
               Order
               |> Ash.Query.filter(internal_order_id == "bypass-1")
               |> Ash.read_one()
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

      assert {:error, :submission_unknown, %{reason: :timeout}} =
               OrderExecutor.submit(command("unknown-1"),
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
               OrderExecutor.submit(command("unknown-2"),
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

      persist_fail = fn _order, _id -> {:error, :forced_persist_failure} end

      assert {:error, :persist_failed, %{exchange_order_id: "ex-persist-halt-1"}} =
               OrderExecutor.submit(command("persist-halt-1"),
                 trade_mode: :live,
                 positions: [],
                 persist_exchange_order_id: persist_fail
               )

      assert SpyExchange.place_count() == 1
      assert Readiness.get() == {:halted, :persist_failed}

      assert {:error, :circuit_open, _} =
               OrderExecutor.submit(command("persist-halt-2"),
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

  defp put_fresh_market do
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
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
