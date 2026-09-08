defmodule UiWeb.Hooks.Locale do
  @moduledoc """
  LiveView 接続時に session のロケールを Gettext へ反映する。
  """
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    locale =
      case session do
        %{"locale" => locale} ->
          if UiWeb.Plugs.Locale.known_locale?(locale),
            do: locale,
            else: UiWeb.Plugs.Locale.default_locale()

        _ ->
          UiWeb.Plugs.Locale.default_locale()
      end

    Gettext.put_locale(UiWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end
