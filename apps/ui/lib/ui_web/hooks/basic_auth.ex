defmodule UiWeb.Hooks.BasicAuth do
  @moduledoc """
  LiveView 接続時に `:ui_basic_ok` session を確認する。

  `/health*` 経由で得た匿名 session だけで Status を購読できないようにする。
  """
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    if session_ok?(session) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp session_ok?(session) when is_map(session) do
    Map.get(session, "ui_basic_ok") == true or Map.get(session, :ui_basic_ok) == true
  end

  defp session_ok?(_), do: false
end
