defmodule UiWeb.Plugs.BasicAuthTest do
  use UiWeb.ConnCase, async: false

  @username "status-user"
  @password "status-secret"

  setup do
    previous = Application.get_env(:ui, :basic_auth)

    on_exit(fn ->
      if previous do
        Application.put_env(:ui, :basic_auth, previous)
      else
        Application.delete_env(:ui, :basic_auth)
      end
    end)

    :ok
  end

  test "GET / returns 401 without credentials when BasicAuth is enabled", %{conn: conn} do
    enable_basic_auth!()

    conn = get(conn, ~p"/")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Application\""]
  end

  test "GET / succeeds with valid BasicAuth credentials", %{conn: conn} do
    enable_basic_auth!()

    conn =
      conn
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth(@username, @password))
      |> get(~p"/")

    assert conn.status == 200
    assert html_response(conn, 200) =~ "docker_bitflyer"
    assert get_session(conn, :ui_basic_ok) == true
  end

  test "GET /health/live stays open without BasicAuth", %{conn: conn} do
    enable_basic_auth!()

    conn = get(conn, ~p"/health/live")
    body = json_response(conn, 200)

    assert body["status"] == "live"
  end

  test "GET / is open when BasicAuth is disabled", %{conn: conn} do
    Application.put_env(:ui, :basic_auth,
      enabled: false,
      username: "",
      password: ""
    )

    conn = get(conn, ~p"/")
    assert conn.status == 200
    assert get_session(conn, :ui_basic_ok) == true
  end

  defp enable_basic_auth! do
    Application.put_env(:ui, :basic_auth,
      enabled: true,
      username: @username,
      password: @password
    )
  end
end
