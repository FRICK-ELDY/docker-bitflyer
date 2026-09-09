defmodule UiWeb.Plugs.BasicAuth do
  @moduledoc """
  UI（`:browser`）向け Basic 認証。

  `/health*` は `:api` 側のため対象外。設定は `Application.get_env(:ui, :basic_auth)`。
  `enabled: false` のときは通過する（開発・テスト既定）。

  成功時（または無効時）に session `:ui_basic_ok` を立て、LiveView Socket（`/live`）が
  router プラグを通らない場合でも `UiWeb.Hooks.BasicAuth` で弾けるようにする。
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
        put_session(conn, :ui_basic_ok, true)
      end
    else
      put_session(conn, :ui_basic_ok, true)
    end
  end
end
