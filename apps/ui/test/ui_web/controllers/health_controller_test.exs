defmodule UiWeb.HealthControllerTest do
  use UiWeb.ConnCase, async: false

  import Bitflyer.TestSupport.ReadinessHelper

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

  test "GET /health returns 200 with not_ready while booting", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    body = json_response(conn, 200)
    assert body["status"] == "not_ready"
    assert body["db"] == true
    assert body["trade_mode"] == "dry_run"
    assert body["readiness"] == "not_ready"
    assert body["reason"] == nil
  end

  test "GET /health returns 200 when ready", %{conn: conn} do
    assert Readiness.mark_ready() == :ok

    conn = get(conn, ~p"/health")
    body = json_response(conn, 200)

    assert body["status"] == "ready"
    assert body["readiness"] == "ready"
  end

  test "GET /health returns 503 when readiness is halted", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    conn = get(conn, ~p"/health")
    body = json_response(conn, 503)

    assert body["status"] == "halted"
    assert body["db"] == true
    assert body["reason"] == "reconcile_mismatch"
    refute Map.has_key?(body, "db_error")
  end

  test "GET /health/live returns 200 even while not_ready", %{conn: conn} do
    conn = get(conn, ~p"/health/live")
    body = json_response(conn, 200)

    assert body["status"] == "live"
    assert body["readiness"] == "live"
    assert body["trade_mode"] == "dry_run"
  end

  test "GET /health/live returns 200 even when halted", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    conn = get(conn, ~p"/health/live")
    body = json_response(conn, 200)

    assert body["status"] == "live"
  end

  test "GET /health/ready returns 503 while booting", %{conn: conn} do
    conn = get(conn, ~p"/health/ready")
    body = json_response(conn, 503)

    assert body["status"] == "not_ready"
    assert body["reason"] == "not_ready"
    assert body["feed"]["enabled"] == false
    assert body["market_data"]["enabled"] == false
  end

  test "GET /health/ready returns 200 when ready and market data disabled", %{conn: conn} do
    assert Readiness.mark_ready() == :ok

    conn = get(conn, ~p"/health/ready")
    body = json_response(conn, 200)

    assert body["status"] == "ready"
    assert body["reason"] == nil
    assert body["feed"]["enabled"] == false
  end

  test "GET /health/ready returns 503 when halted", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    conn = get(conn, ~p"/health/ready")
    body = json_response(conn, 503)

    assert body["status"] == "halted"
    assert body["reason"] == "reconcile_mismatch"
  end

  test "GET /health/ready includes market freshness fields when cache is populated", %{conn: conn} do
    assert Readiness.mark_ready() == :ok
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok

    conn = get(conn, ~p"/health/ready")
    body = json_response(conn, 200)

    assert body["status"] == "ready"
    assert is_list(body["market_data"]["entries"])
  end
end
