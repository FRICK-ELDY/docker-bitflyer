defmodule UiWeb.StatusLiveTest do
  use UiWeb.ConnCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.BalanceCacheHelper
  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper
  import Phoenix.LiveViewTest

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Readiness
  alias Bitflyer.Trading.{Order, Position, RiskState}

  @product "BTC_JPY"
  @market_key {:ticker, @product}

  setup do
    reset_readiness()
    reset_daily_loss()
    reset_market_data_cache()
    reset_balance_cache()
    clear_default_risk_state()
    assert Cache.clear() == :ok

    on_exit(fn ->
      reset_readiness()
      reset_daily_loss()
      reset_market_data_cache()
      reset_balance_cache()
      clear_default_risk_state()
      _ = Cache.clear()
    end)

    :ok
  end

  test "status page shows app name, trade mode, and db status in English by default", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#app-name", "docker_bitflyer")
    assert has_element?(view, "#trade-mode", "dry_run")
    assert has_element?(view, "#readiness", "not_ready")
    assert has_element?(view, "#orders-gate-label", "STOPPED")
    assert has_element?(view, "#orders-gate-reason", "not_ready")
    assert has_element?(view, "#feed-status", "disabled")
    assert has_element?(view, "#market-freshness", "stale")
    assert has_element?(view, "#db-status-label")
    assert has_element?(view, "#status-page", "Operational health check")
    assert has_element?(view, "#status-page", "Trade mode")
    assert has_element?(view, "#status-page", "Readiness")
    assert has_element?(view, "#status-page", "Orders")
    assert has_element?(view, "#status-page", "Feed")
    assert has_element?(view, "#status-page", "Market data")
    assert has_element?(view, "#ops-controls")
    assert has_element?(view, "#ops-kill-switch")
    assert has_element?(view, "#exposure")
    assert has_element?(view, "#exposure-positions-empty")
    assert has_element?(view, "#exposure-open-orders-empty")
    assert has_element?(view, "#exposure-open-orders-count", "0 open")
    assert has_element?(view, "#daily-pnl")
    assert has_element?(view, "#daily-pnl-status", "available")
    assert has_element?(view, "#exposure-balances")
    assert has_element?(view, "#exposure-balance-JPY")
    assert has_element?(view, "#exposure-balance-BTC")
    refute has_element?(view, "#halt-recovery")
    assert has_element?(view, "#app-header", "docker_bitflyer")
    refute has_element?(view, "a", "Get Started")
    refute has_element?(view, "a", "Website")
    refute has_element?(view, "#ops-resume")
    refute has_element?(view, "#ops-reconcile-now")
    assert has_element?(view, "#locale-switcher")
  end

  test "locale switch to Japanese updates status copy", %{conn: conn} do
    conn = get(conn, ~p"/locale/ja")
    assert redirected_to(conn) == ~p"/"

    {:ok, view, _html} = live(recycle(conn), ~p"/")

    assert has_element?(view, "#status-page", "運用用の生存確認")
    assert has_element?(view, "#status-page", "取引モード")
    assert has_element?(view, "#status-page", "Ready 状態")
    assert has_element?(view, "#status-page", "発注")
    assert has_element?(view, "#status-page", "Feed")
    assert has_element?(view, "#status-page", "市場データ")
    assert has_element?(view, "#ops-controls", "運用操作")
    assert has_element?(view, "#orders-gate-label", "停止")
    assert has_element?(view, "#feed-status", "無効")
    assert has_element?(view, "#exposure-positions", "建玉")
    assert has_element?(view, "#exposure-open-orders", "未約定")
    assert has_element?(view, "#daily-pnl", "当日損益")
    assert has_element?(view, "#daily-pnl-status", "取得可")
    assert has_element?(view, "#exposure-balances", "残高")
    assert has_element?(view, "#locale-ja")
  end

  test "readiness halt reason is visible on the status page", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#readiness", "halted:reconcile_mismatch")
    assert has_element?(view, "#halt-reason", "reconcile_mismatch")
    assert has_element?(view, "#orders-gate-label", "STOPPED")
    assert has_element?(view, "#orders-gate-reason", "reconcile_mismatch")
    assert has_element?(view, "#ops-resume")
    assert has_element?(view, "#ops-reconcile-now")
    assert has_element?(view, "#halt-recovery")
    assert has_element?(view, "#halt-recovery-reason", "reconcile_mismatch")
    assert has_element?(view, "#halt-recovery-step-1")
    assert has_element?(view, "#halt-recovery-steps", "Reconcile now")
  end

  test "status page shows positions, open orders, and daily pnl", %{conn: conn} do
    {:ok, _} =
      Position
      |> Ash.Changeset.for_create(:create, %{
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.02"),
        average_price: Decimal.new("5000000"),
        trade_mode: :dry_run
      })
      |> Ash.create()

    {:ok, _} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "status-open-1",
        exchange_order_id: "JRF-status-open-1",
        product_code: @product,
        side: :buy,
        status: :pending,
        order_type: :limit,
        price: Decimal.new("4990000"),
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0"),
        trade_mode: :dry_run
      })
      |> Ash.create()

    {:ok, _} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        internal_order_id: "status-partial-1",
        exchange_order_id: "JRF-status-partial-1",
        product_code: @product,
        side: :sell,
        status: :partially_filled,
        order_type: :limit,
        price: Decimal.new("5100000"),
        size: Decimal.new("0.01"),
        filled_size: Decimal.new("0.004"),
        filled_notional: Decimal.new("20400"),
        trade_mode: :dry_run
      })
      |> Ash.create()

    assert put_fresh_ticker(@market_key, Decimal.new("4900000")) == :ok
    seed_balance_cache!(:dry_run, %{"JPY" => "2500000", "BTC" => "0.4"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exposure-position-BTC_JPY", "0.02")
    assert has_element?(view, "#exposure-position-BTC_JPY", "4900000")
    assert has_element?(view, "#exposure-position-BTC_JPY", "-2000")
    refute has_element?(view, "#exposure-positions-empty")
    assert has_element?(view, "#exposure-open-order-status-open-1", "pending")
    assert has_element?(view, "#exposure-open-order-status-open-1", "JRF-status-open-1")
    assert has_element?(view, "#exposure-open-order-status-open-1", "4990000")
    assert has_element?(view, "#exposure-open-order-status-partial-1", "partially_filled")
    assert has_element?(view, "#exposure-open-order-status-partial-1", "sell")
    assert has_element?(view, "#exposure-open-order-status-partial-1", "0.006")
    refute has_element?(view, "#exposure-open-orders-empty")
    assert has_element?(view, "#exposure-open-orders-count", "2 open")
    assert has_element?(view, "#exposure-balance-JPY", "2500000")
    assert has_element?(view, "#exposure-balance-BTC", "0.4")
    assert has_element?(view, "#daily-pnl-unrealized", "-2000")
    assert has_element?(view, "#daily-pnl-status", "available")
  end

  test "opening status does not halt or raise daily peak", %{conn: conn} do
    assert Readiness.mark_ready() == :ok

    {:ok, _} =
      Position
      |> Ash.Changeset.for_create(:create, %{
        product_code: @product,
        side: :buy,
        size: Decimal.new("0.1"),
        average_price: Decimal.new("5000000"),
        trade_mode: :dry_run
      })
      |> Ash.create()

    assert put_fresh_ticker(@market_key, Decimal.new("1000000")) == :ok

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exposure-position-BTC_JPY")
    assert has_element?(view, "#daily-pnl-unrealized", "-400000")
    assert Readiness.get() == :ready
    assert {:ok, %{peak: peak}} = Bitflyer.Risk.DailyLoss.snapshot(:dry_run)
    assert Decimal.eq?(peak, Decimal.new(0))
  end

  test "orders gate shows ALLOWED when ready and market data is fresh", %{conn: conn} do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#orders-gate-label", "ALLOWED")
    refute has_element?(view, "#orders-gate-reason")
    assert has_element?(view, "#readiness", "ready")
    assert has_element?(view, "#feed-status", "disabled")
    assert has_element?(view, "#market-freshness", "fresh")
    assert has_element?(view, "#market-freshness-BTC_JPY", "fresh")
    refute has_element?(view, "#ops-resume")
  end

  test "orders gate shows STOPPED when feed is disconnected while market still fresh", %{
    conn: conn
  } do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    previous = Application.get_env(:bitflyer, :operational_status_snapshot_opts, [])

    Application.put_env(:bitflyer, :operational_status_snapshot_opts,
      market_data: %{
        enabled?: true,
        max_age_ms: 5_000,
        all_fresh?: true,
        entries: [
          %{product_code: @product, key: @market_key, fresh?: true, age_ms: 10}
        ]
      },
      feed: %{
        enabled?: true,
        available?: true,
        connected?: false,
        subscribe_count: 1,
        reconnect_attempt: 2
      }
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, :operational_status_snapshot_opts, previous)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#orders-gate-label", "STOPPED")
    assert has_element?(view, "#orders-gate-reason", "feed_disconnected")
    assert has_element?(view, "#feed-status", "disconnected")
    assert has_element?(view, "#market-freshness", "fresh")
  end

  test "kill switch opens circuit and shows resume controls", %{conn: conn} do
    assert Readiness.mark_ready() == :ok

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#ops-resume")

    view |> element("#ops-kill-switch") |> render_click()
    # halt_trading の RiskState 永続化が既定 100ms を超えることがある
    _ = render_async(view, 1_000)

    assert has_element?(view, "#readiness", "halted:manual_halt")
    assert has_element?(view, "#halt-reason", "manual_halt")
    assert has_element?(view, "#orders-gate-label", "STOPPED")
    assert has_element?(view, "#ops-resume")
    assert has_element?(view, "#ops-reconcile-now")
    assert Readiness.get() == {:halted, :manual_halt}
  end

  test "kill switch does not overwrite existing halt reason", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#halt-reason", "reconcile_mismatch")

    view |> element("#ops-kill-switch") |> render_click()
    _ = render_async(view, 1_000)

    assert has_element?(view, "#halt-reason", "reconcile_mismatch")
    assert Readiness.get() == {:halted, :reconcile_mismatch}
  end

  test "resume from status page clears halt after successful reconcile", %{conn: conn} do
    assert :ok = Bitflyer.System.halt_trading(operator: "test")
    assert Readiness.get() == {:halted, :manual_halt}

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#ops-resume")

    view |> element("#ops-resume") |> render_click()
    # resume 再突合が既定 100ms を超えることがある
    _ = render_async(view, 1_000)

    assert has_element?(view, "#readiness", "ready")
    refute has_element?(view, "#ops-resume")
    assert Readiness.ready?()
  end

  test "reconcile now from status page while halted keeps halt", %{conn: conn} do
    assert :ok = Bitflyer.System.halt_trading(operator: "test")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#ops-reconcile-now")

    view |> element("#ops-reconcile-now") |> render_click()
    _ = render_async(view, 1_000)

    assert match?({:halted, _}, Readiness.get())
    assert has_element?(view, "#ops-resume")
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, %RiskState{} = risk} ->
        _ =
          risk
          |> Ash.Changeset.for_update(:update, %{
            halted: false,
            reason: nil,
            halted_at: nil
          })
          |> Ash.update()

        :ok

      {:ok, nil} ->
        :ok

      {:error, _} ->
        :ok
    end
  end
end
