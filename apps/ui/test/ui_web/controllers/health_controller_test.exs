defmodule UiWeb.HealthControllerTest do
  use UiWeb.ConnCase, async: false

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness

  setup do
    reset_readiness()

    on_exit(fn ->
      reset_readiness()
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
  end
end
