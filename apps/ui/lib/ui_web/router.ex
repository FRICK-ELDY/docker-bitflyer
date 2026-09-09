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

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ui, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: UiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
