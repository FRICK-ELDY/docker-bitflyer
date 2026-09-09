# Umbrella 共通設定。apps/bitflyer と apps/ui がこのファイルを共有する。
import Config

config :bitflyer,
  ecto_repos: [Bitflyer.Repo],
  ash_domains: [Bitflyer.System, Bitflyer.Trading],
  exchange_client: Bitflyer.Exchange.Unavailable

config :bitflyer, Bitflyer.Startup.Reconciler,
  boot?: true,
  interval_ms: 60_000

# live 突合で必須の残高 baseline（内部 BalanceSnapshot が無いと Ready にしない）
config :bitflyer, Bitflyer.Startup.Reconcile, required_balance_currencies: ["JPY", "BTC"]

config :bitflyer, Bitflyer.MarketData.Cache, default_max_age_ms: 5_000

config :bitflyer, Bitflyer.MarketData,
  enabled: true,
  product_codes: ["FX_BTC_JPY"],
  rest_base_url: "https://api.bitflyer.com",
  ws_url: "wss://ws.lightstream.bitflyer.com/json-rpc",
  rest_client: Bitflyer.MarketData.Rest,
  socket_client: Bitflyer.MarketData.Socket,
  gap_fill_on_connect?: true,
  reconnect_base_ms: 500,
  reconnect_max_ms: 30_000

# Feed → Strategy → Risk → Executor（dry_run 既定で意図を 1 回出す）
config :bitflyer, Bitflyer.Strategy,
  enabled: true,
  module: Bitflyer.Strategy.FixedOnce,
  params: [size: "0.01", side: :buy],
  throttle_ms: 1_000,
  submitted_lookback_days: 7,
  submitted_id_prefix: "strategy-"

config :bitflyer, Bitflyer.Risk,
  max_order_size: "1",
  max_position_size: "5",
  market_data_max_age_ms: 5_000,
  max_daily_loss: "100000",
  max_orders_per_minute: 20,
  max_price_deviation_pct: "2"

config :ui,
  generators: [timestamp_type: :utc_datetime]

config :ui, UiWeb.Gettext,
  default_locale: "en",
  locales: ~w(en ja)

# Configure the endpoint
config :ui, UiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UiWeb.ErrorHTML, json: UiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ui.PubSub,
  live_view: [signing_salt: "tKeWPKna"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ui, Ui.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/ui/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/ui", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :trade_mode,
    :readiness,
    :reason,
    :status,
    :from,
    :to,
    :internal_order_id,
    :exchange_order_id,
    :product_code,
    :side,
    :rejection_code,
    :circuit_reason,
    :db,
    :healthy,
    :kind,
    :currency,
    :limit
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
