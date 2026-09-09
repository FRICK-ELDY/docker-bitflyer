defmodule UiWeb.StatusLiveTest do
  use UiWeb.ConnCase, async: false

  import Bitflyer.TestSupport.ReadinessHelper
  import Phoenix.LiveViewTest

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Readiness

  @product "FX_BTC_JPY"
  @market_key {:ticker, @product}

  setup do
    reset_readiness()
    assert Cache.clear() == :ok

    on_exit(fn ->
      reset_readiness()
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
    assert has_element?(view, "#orders-gate-label", "停止")
    assert has_element?(view, "#feed-status", "無効")
    assert has_element?(view, "#locale-ja")
  end

  test "readiness halt reason is visible on the status page", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#readiness", "halted:reconcile_mismatch")
    assert has_element?(view, "#halt-reason", "reconcile_mismatch")
    assert has_element?(view, "#orders-gate-label", "STOPPED")
    assert has_element?(view, "#orders-gate-reason", "reconcile_mismatch")
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
    assert has_element?(view, "#market-freshness-FX_BTC_JPY", "fresh")
  end
end
