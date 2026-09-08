defmodule UiWeb.Plugs.Locale do
  @moduledoc """
  Session からロケールを読み、Gettext に設定する。
  """
  import Plug.Conn

  @locales ~w(en ja)
  @default_locale "en"

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = current_locale(conn)
    Gettext.put_locale(UiWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  @doc """
  対応ロケールかどうか。
  """
  def known_locale?(locale) when is_binary(locale), do: locale in @locales
  def known_locale?(_), do: false

  @doc """
  既定ロケール。
  """
  def default_locale, do: @default_locale

  @doc """
  対応ロケール一覧。
  """
  def locales, do: @locales

  defp current_locale(conn) do
    case get_session(conn, "locale") do
      locale when locale in @locales -> locale
      _ -> @default_locale
    end
  end
end
