defmodule UiWeb.Hooks.BasicAuth do
  @moduledoc """
  LiveView 接続時に `:ui_basic_ok` session を確認する。

  `/health*` 経由で得た匿名 session だけで Status を購読できないようにする。
  操作ログ用に `:ui_basic_username` を `ops_operator` assign へ載せる。
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    if session_ok?(session) do
      {:cont, assign(socket, :ops_operator, session_username(session))}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp session_ok?(%{"ui_basic_ok" => true}), do: true
  defp session_ok?(%{ui_basic_ok: true}), do: true
  defp session_ok?(_), do: false

  defp session_username(%{"ui_basic_username" => name})
       when is_binary(name) and name != "",
       do: name

  defp session_username(%{ui_basic_username: name})
       when is_binary(name) and name != "",
       do: name

  defp session_username(_), do: "anonymous"
end
