defmodule UiWeb.StatusLiveTest do
  use UiWeb.ConnCase, async: false

  import Bitflyer.TestSupport.ReadinessHelper
  import Phoenix.LiveViewTest

  alias Bitflyer.Readiness

  setup do
    reset_readiness()

    on_exit(fn ->
      reset_readiness()
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
    assert has_element?(view, "#db-status-label")
    assert has_element?(view, "#status-page", "Operational health check")
    assert has_element?(view, "#status-page", "Trade mode")
    assert has_element?(view, "#status-page", "Readiness")
    assert has_element?(view, "#locale-switcher")
  end

  test "locale switch to Japanese updates status copy", %{conn: conn} do
    conn = get(conn, ~p"/locale/ja")
    assert redirected_to(conn) == ~p"/"

    {:ok, view, _html} = live(recycle(conn), ~p"/")

    assert has_element?(view, "#status-page", "運用用の生存確認")
    assert has_element?(view, "#status-page", "取引モード")
    assert has_element?(view, "#status-page", "Ready 状態")
    assert has_element?(view, "#locale-ja")
  end

  test "readiness halt reason is visible on the status page", %{conn: conn} do
    assert Readiness.halt(:reconcile_mismatch) == :ok

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#readiness", "halted:reconcile_mismatch")
  end
end
