defmodule UiWeb.StatusLiveTest do
  use UiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "status page shows app name, trade mode, and db status in English by default", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#app-name", "docker_bitflyer")
    assert has_element?(view, "#trade-mode")
    assert has_element?(view, "#db-status-label")
    assert has_element?(view, "#status-page", "Operational health check")
    assert has_element?(view, "#status-page", "Trade mode")
    assert has_element?(view, "#locale-switcher")
  end

  test "locale switch to Japanese updates status copy", %{conn: conn} do
    conn = get(conn, ~p"/locale/ja")
    assert redirected_to(conn) == ~p"/"

    {:ok, view, _html} = live(recycle(conn), ~p"/")

    assert has_element?(view, "#status-page", "運用用の生存確認")
    assert has_element?(view, "#status-page", "取引モード")
    assert has_element?(view, "#locale-ja")
  end
end
