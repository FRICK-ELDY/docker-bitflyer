# Umbrella 共通設定。apps/bitflyer と apps/ui がこのファイルを共有する。
import Config

config :bitflyer,
  ecto_repos: [Bitflyer.Repo],
  ash_domains: [Bitflyer.Trading],
  exchange_client: Bitflyer.Exchange.Unavailable

# Private API 資格情報（runtime で上書き。live 時のみ必須）
config :bitflyer, :exchange_api, api_key: "", api_secret: ""

config :bitflyer, Bitflyer.Exchange.Rest,
  base_url: "https://api.bitflyer.com",
  http_client: Bitflyer.Exchange.Rest.HTTP,
  receive_timeout: 5_000

config :bitflyer, Bitflyer.Startup.Reconciler,
  boot?: true,
  interval_ms: 60_000

# 未約定期限 / halt 時 cancel-all（P1 #10）。詳細は OpenOrderPolicy / prod.md。
# 自前 TIF は持たず、期限は max_open_age_ms（inserted_at）。未記載の halt 理由は取消しない。
config :bitflyer, Bitflyer.Risk.OpenOrderPolicy,
  max_open_age_ms: :infinity,
  # 本番は非同期 cancel（Task.Supervisor）。test.exs は false。
  async_default: true,
  # 取消失敗／open 残留後の再試行間隔（CircuitSync 2s より長くして連打を防ぐ）
  halt_cancel_retry_backoff_ms: 30_000,
  # in-flight ロック失効（大量 open の逐次 cancel が長くても二重起動しにくくする）
  halt_cancel_in_flight_stale_ms: 600_000,
  cancel_on_halt: %{
    manual_halt: true,
    daily_loss_exceeded: true,
    daily_drawdown_exceeded: true,
    consecutive_exchange_errors: true,
    auth_failed: true,
    fill_sync_failed: true,
    fill_price_unavailable: true,
    # reconcile_mismatch / submission_unknown / persist_failed 等は既定 false（証拠・recover 優先）
    reconcile_mismatch: false,
    submission_unknown: false,
    persist_failed: false,
    restore_failed: false,
    exchange_unavailable: false,
    invalid_exchange_payload: false,
    unsafe_api_permissions: false,
    clock_skew: false,
    risk_halted: false,
    failure_rate_unsynced: false
  }

# live 突合で必須の残高 baseline（内部 BalanceSnapshot が無いと Ready にしない）
# amount 差分は Fill 合計 + 支払超過側の手数料許容だけで前進。増加は入金として halt。
# 絶対床は Fill があるときの丸め専用。Fill が無い通貨では 0（1 JPY の入出金も halt）。
# 20bps は fee 未記録（NULL）Fill だけの見積り上限。記録済みは絶対床。
config :bitflyer, Bitflyer.Startup.Reconcile,
  required_balance_currencies: ["JPY", "BTC"],
  balance_fee_tolerance_bps: "20",
  balance_fee_tolerance_abs: %{"JPY" => "1", "BTC" => "0.00000001"},
  position_size_tolerance_abs: %{"JPY" => "1", "BTC" => "0.00000001"}

config :bitflyer, Bitflyer.MarketData.Cache, default_max_age_ms: 5_000

config :bitflyer, Bitflyer.MarketData,
  enabled: true,
  product_codes: ["BTC_JPY"],
  rest_base_url: "https://api.bitflyer.com",
  ws_url: "wss://ws.lightstream.bitflyer.com/json-rpc",
  rest_client: Bitflyer.MarketData.Rest,
  socket_client: Bitflyer.MarketData.Socket,
  gap_fill_on_connect?: true,
  reconnect_base_ms: 500,
  reconnect_max_ms: 30_000

# stall_timeout_ms 未設定時は Risk の market_data_max_age_ms × 3（Feed 既定）

# Feed → Strategy → Risk → Executor（dry_run 既定で意図を 1 回出す）
# live では runtime が enabled を false にし、FixedOnce 有効化を拒否する。
config :bitflyer, Bitflyer.Strategy,
  enabled: true,
  module: Bitflyer.Strategy.FixedOnce,
  params: [size: "0.01", side: :buy],
  throttle_ms: 1_000,
  submitted_lookback_days: 7,
  submitted_id_prefix: "strategy-"

# dry_run / paper 用の開発上限。live では runtime が環境変数必須で上書きする。
config :bitflyer, Bitflyer.Risk,
  max_order_size: "1",
  max_position_size: "5",
  market_data_max_age_ms: 5_000,
  max_clock_skew_ms: 5_000,
  max_daily_loss: "100000",
  # realized + unrealized。未指定時 Limits は max_daily_loss に揃える
  max_daily_drawdown: "100000",
  max_orders_per_minute: 20,
  max_price_deviation_pct: "2",
  exchange_error_window_ms: 60_000,
  max_exchange_errors_per_window: 5

# SIGTERM 時の in-flight drain。
# 予算: drain ≤10s + 明示 shutdown 子（最大おおよそ 5×5s）≪ Compose stop_grace_period 45s
config :bitflyer, Bitflyer.OrderExecutor, drain_timeout_ms: 10_000

# paper 擬似約定: LTP/指値を基準に不利方向へ bps を加味（1 bps = 0.01%）
config :bitflyer, Bitflyer.OrderExecutor.Paper,
  slippage_bps: "5",
  fee_bps: "15"

# Discord Incoming Webhook（未設定なら通知を送らず起動する）
config :bitflyer, Bitflyer.Observe.Discord,
  webhook_url: nil,
  cooldown_ms: 60_000,
  # 通知経路の死はイベント欠落では分からない。0 / infinity でオフ。
  heartbeat_interval_ms: 900_000,
  http_client: Bitflyer.Observe.Discord.HTTP

config :ui,
  generators: [timestamp_type: :utc_datetime]

# UI BasicAuth（runtime で上書き。prod は必須）
config :ui, :basic_auth, enabled: false, username: "", password: ""

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
    :currencies,
    :expected,
    :actual,
    :unexplained,
    :allowance,
    :limit,
    :operator,
    :snapshot_hash,
    :skew_ms,
    :max_ms,
    :strategy_parameter_revision_id,
    :trading_day
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
