defmodule UiWeb.Hooks.Locale do
  @moduledoc """
  LiveView 接続時に session のロケールを Gettext へ反映する。
  """
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    locale =
      session
      |> Map.get("locale")
      |> UiWeb.Plugs.Locale.validate_locale()

    Gettext.put_locale(UiWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end
