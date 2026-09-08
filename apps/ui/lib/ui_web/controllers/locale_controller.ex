defmodule UiWeb.LocaleController do
  @moduledoc """
  表示言語を session に保存してリダイレクトする。
  """
  use UiWeb, :controller

  def update(conn, %{"locale" => locale}) do
    locale = UiWeb.Plugs.Locale.validate_locale(locale)

    conn
    |> put_session("locale", locale)
    |> redirect(to: ~p"/")
  end
end
