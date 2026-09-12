import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ui, UiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+g8U+FaUo3FWx8Z4dNMsl5AdKpXMcTTdZMAWjdgboDXqBRN3fCuGNxnuMmAW7C8Q",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# LiveDashboard をテストでもマウントし、BasicAuth 保護を固定する
config :ui, dashboard_routes: true

# UI BasicAuth はテスト既定オフ（個別テストで Application.put_env する）
config :ui, :basic_auth, enabled: false, username: "", password: ""

# bitFlyer API キーはテスト既定空（runtime も :test では live 必須チェックをしない）
config :bitflyer, :exchange_api, api_key: "", api_secret: ""

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

# テストでは周期同期を止め、明示 sync_now で検証する
config :bitflyer, Bitflyer.Risk.CircuitSync, interval_ms: :disabled

# 実ネット禁止。テストは Feed を明示起動し Local socket / Stub REST を注入する
config :bitflyer, Bitflyer.MarketData,
  enabled: false,
  rest_client: Bitflyer.MarketData.Rest.Stub,
  socket_client: Bitflyer.MarketData.Socket.Local

# live 突合の時計検査向け。失敗経路は Stub response: :error で個別に戻す
config :bitflyer, Bitflyer.MarketData.Rest.Stub, response: :ok

config :bitflyer, Bitflyer.Strategy, enabled: false

# Risk のテスト注入（:daily_loss 等）を許可。本番 config では無効のまま。
config :bitflyer, Bitflyer.Risk, allow_test_injections: true

# テスト既定では halt cancel-all を無効化（Exchange スタブ解体後の非同期 cancel を避ける）。
# 有効化は OpenOrderPolicyTest が個別に put_env する。
config :bitflyer, Bitflyer.Risk.OpenOrderPolicy,
  max_open_age_ms: :infinity,
  cancel_on_halt: %{},
  # テストは同期 cancel（Exchange スタブ解体後の孤児 Task を避ける）
  async_default: false,
  # stampede テストで即再試行できるよう短くする（個別 put_env でも上書き可）
  halt_cancel_retry_backoff_ms: 30_000

# 実 Webhook を叩かない。個別テストは start_supervised で注入する。
config :bitflyer, Bitflyer.Observe.Discord, webhook_url: nil

# 既存 paper 期待値（LTP/指値ちょうど）を壊さない。fee/slip は専用テストで明示する。
config :bitflyer, Bitflyer.OrderExecutor.Paper,
  slippage_bps: "0",
  fee_bps: "0"
