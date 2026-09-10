defmodule UiWeb.Router do
  use UiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug UiWeb.Plugs.Locale

    # /health* は :api。Status / locale / LiveView は認証必須（prod で資格情報必須）。
    plug UiWeb.Plugs.BasicAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # 認証・セッション不要。監視と Compose healthcheck 用。
  # LiveView Socket が /live を使うため、liveness は /health/live。
  scope "/", UiWeb do
    pipe_through :api

    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/health", HealthController, :show
  end

  scope "/", UiWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update

    live_session :default, on_mount: [UiWeb.Hooks.BasicAuth, UiWeb.Hooks.Locale] do
      live "/", StatusLive
    end
  end

  # 本番・開発共通: BasicAuth 配下の LiveDashboard（率・推移の確認用）。
  # Processes / ETS / Applications はライブラリ既定で残る（ページ除外 API なし）。
  # OS env・Ecto・RequestLogger・破壊操作は明示オフ。loopback / ACL 前提。
  if Application.compile_env(:ui, :dashboard_routes, false) do
    import Phoenix.LiveDashboard.Router

    scope "/ops" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: UiWeb.Telemetry,
        on_mount: [{UiWeb.Hooks.BasicAuth, :default}],
        ecto_repos: [],
        request_logger: false,
        allow_destructive_actions: false
    end
  end
end
