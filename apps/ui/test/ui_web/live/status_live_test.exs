defmodule UiWeb.StatusLiveTest do
  use UiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "status page shows app name, trade mode, and db status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#app-name", "docker_bitflyer")
    assert has_element?(view, "#trade-mode")
    assert has_element?(view, "#db-status-label")
    assert has_element?(view, "#status-page")
  end
end
