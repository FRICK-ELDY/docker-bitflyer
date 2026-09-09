import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ui, UiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+g8U+FaUo3FWx8Z4dNMsl5AdKpXMcTTdZMAWjdgboDXqBRN3fCuGNxnuMmAW7C8Q",
  server: false

# In test we don't send emails
config :ui, Ui.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Sandbox 所有権と衝突しないよう、テストでは起動時突合を手動にする
config :bitflyer, Bitflyer.Startup.Reconciler,
  boot?: false,
  interval_ms: :infinity

# 実ネット禁止。テストは Feed を明示起動し Local socket / Stub REST を注入する
config :bitflyer, Bitflyer.MarketData,
  enabled: false,
  rest_client: Bitflyer.MarketData.Rest.Stub,
  socket_client: Bitflyer.MarketData.Socket.Local

config :bitflyer, Bitflyer.Strategy, enabled: false

# 実 Webhook を叩かない。個別テストは start_supervised で注入する。
config :bitflyer, Bitflyer.Observe.Discord,
  webhook_url: nil,
  attach?: false
