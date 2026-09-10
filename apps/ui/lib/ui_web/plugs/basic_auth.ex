defmodule UiWeb.Plugs.BasicAuth do
  @moduledoc """
  UI（`:browser`）向け Basic 認証。

  `/health*` は `:api` 側のため対象外。設定は `Application.get_env(:ui, :basic_auth)`。
  `enabled: false` のときは通過する（開発・テスト既定）。

  成功時（または無効時）に session `:ui_basic_ok` と `:ui_basic_username` を立て、
  LiveView Socket（`/live`）が router プラグを通らない場合でも `UiWeb.Hooks.BasicAuth`
  で弾けるようにする。username は StatusLive 操作ログ用。
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.get_env(:ui, :basic_auth, [])

    if Keyword.get(config, :enabled, false) do
      username = Keyword.fetch!(config, :username)
      password = Keyword.fetch!(config, :password)

      conn = Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      if conn.halted do
        conn
      else
        put_ops_session(conn, username)
      end
    else
      put_ops_session(conn, Keyword.get(config, :username) || "dev")
    end
  end

  defp put_ops_session(conn, username) do
    conn
    |> put_session(:ui_basic_ok, true)
    |> put_session(:ui_basic_username, username)
  end
end
