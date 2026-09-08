defmodule UiWeb.LocaleController do
  @moduledoc """
  表示言語を session に保存してリダイレクトする。
  """
  use UiWeb, :controller

  def update(conn, %{"locale" => locale}) do
    locale =
      if UiWeb.Plugs.Locale.known_locale?(locale),
        do: locale,
        else: UiWeb.Plugs.Locale.default_locale()

    conn
    |> put_session("locale", locale)
    |> redirect(to: ~p"/")
  end
end
