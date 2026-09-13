import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

# test は開発 DB を触らない。TEST_DATABASE_URL 優先、未設定なら DB 名を *_test に寄せる。
database_url =
  case config_env() do
    :test ->
      case System.get_env("TEST_DATABASE_URL") do
        url when is_binary(url) and url != "" ->
          url

        _ ->
          uri = URI.new!(database_url)
          db_name = uri.path |> to_string() |> String.trim_leading("/")

          test_name =
            cond do
              String.ends_with?(db_name, "_test") ->
                db_name

              String.ends_with?(db_name, "_dev") ->
                String.replace_suffix(db_name, "_dev", "_test")

              true ->
                db_name <> "_test"
            end

          partition = System.get_env("MIX_TEST_PARTITION") || ""
          URI.to_string(%{uri | path: "/#{test_name}#{partition}"})
      end

    _ ->
      database_url
  end

repo_config = [
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  # 起動直後や一時切断向け。接続確立まで待つ。
  timeout: 15_000,
  queue_target: 5_000,
  queue_interval: 2_000
]

repo_config =
  case config_env() do
    :test ->
      Keyword.merge(repo_config,
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: System.schedulers_online() * 2
      )

    :dev ->
      Keyword.put(repo_config, :show_sensitive_data_on_connection_error, true)

    _ ->
      repo_config
  end

config :bitflyer, Bitflyer.Repo, repo_config

# TRADE_MODE は dry_run / paper / live のみ。不正値はここで起動停止。
# live の実発注は BITFLYER_LIVE_CONFIRM（UTC の YYYY-MM-DD）+ Ready が揃うまで不可。
#
# ここは stdlib のみでパースする（Application 未起動のため自アプリモジュールに依存しない）。
# 許可値・確認規則は Bitflyer.TradeMode と揃えること。
trade_mode_raw = System.get_env("TRADE_MODE") || "dry_run"

trade_mode =
  case String.trim(trade_mode_raw) do
    "dry_run" ->
      :dry_run

    "paper" ->
      :paper

    "live" ->
      :live

    _ ->
      raise ArgumentError, """
      invalid TRADE_MODE #{inspect(trade_mode_raw)}.
      Allowed values: dry_run, paper, live.
      """
  end

live_confirm_raw = System.get_env("BITFLYER_LIVE_CONFIRM")

live_confirmed =
  is_binary(live_confirm_raw) and
    String.trim(live_confirm_raw) == Date.to_iso8601(Date.utc_today())

config :bitflyer,
  trade_mode: trade_mode,
  live_confirmed: live_confirmed

# bitFlyer Private API 資格情報。名前は固定。値は Git / イメージ / ログに出さない。
# TRADE_MODE=live のときのみ必須（:test は除く。.env の live でテスト起動を止めない）。
# live + キーありのとき署名付き Rest を差し込む。それ以外は Unavailable（fail-closed）。
# 出金権限付きキーは運用禁止（文書の正: overview / prod.md）。
bitflyer_api_key =
  case System.get_env("BITFLYER_API_KEY") do
    nil -> ""
    val -> String.trim(val)
  end

bitflyer_api_secret =
  case System.get_env("BITFLYER_API_SECRET") do
    nil -> ""
    val -> String.trim(val)
  end

bitflyer_api_present? = bitflyer_api_key != "" and bitflyer_api_secret != ""

if trade_mode == :live and config_env() != :test and not bitflyer_api_present? do
  raise """
  BITFLYER_API_KEY and BITFLYER_API_SECRET are required when TRADE_MODE=live.
  Issue keys from bitFlyer Lightning developer page without withdrawal permission.
  dry_run / paper may omit keys.
  """
end

{exchange_api_key, exchange_api_secret} =
  case config_env() do
    :test ->
      # runtime は test.exs の後。.env のキーがテストに漏れないよう空にする。
      {"", ""}

    _ ->
      {bitflyer_api_key, bitflyer_api_secret}
  end

config :bitflyer, :exchange_api,
  api_key: exchange_api_key,
  api_secret: exchange_api_secret

# live 実運用のみ Rest を刺す。test / dry_run / paper / キー欠落は Unavailable のまま。
if trade_mode == :live and config_env() != :test and bitflyer_api_present? do
  config :bitflyer, exchange_client: Bitflyer.Exchange.Rest
end

# live（:test 除く）: Strategy 既定無効・FixedOnce 禁止・Risk 上限は環境変数必須。
# confirm だけでは開発用 FixedOnce 成行や 1BTC 上限が載らないようにする。
if trade_mode == :live and config_env() != :test do
  strategy_cfg = Application.get_env(:bitflyer, Bitflyer.Strategy, [])
  risk_cfg = Application.get_env(:bitflyer, Bitflyer.Risk, [])

  {strategy_cfg, risk_cfg} =
    Bitflyer.Config.LiveSafety.apply_live_overrides!(
      strategy_cfg,
      risk_cfg,
      &System.get_env/1
    )

  config :bitflyer, Bitflyer.Strategy, strategy_cfg
  config :bitflyer, Bitflyer.Risk, risk_cfg

  max_open_age_ms = Bitflyer.Config.LiveSafety.require_max_open_age_ms!(&System.get_env/1)
  open_order_cfg = Application.get_env(:bitflyer, Bitflyer.Risk.OpenOrderPolicy, [])

  config :bitflyer,
         Bitflyer.Risk.OpenOrderPolicy,
         Keyword.put(open_order_cfg, :max_open_age_ms, max_open_age_ms)
end

# Game Day の Feed 断注入。live では残っていても公式 Lightstream を上書きしない（起動停止）。
# :test は無視（Socket.Local）。空なら config.exs の既定。
case Bitflyer.Config.WsUrl.resolve(
       System.get_env("BITFLYER_WS_URL"),
       trade_mode,
       config_env()
     ) do
  {:override, url} ->
    md = Application.get_env(:bitflyer, Bitflyer.MarketData, [])
    config :bitflyer, Bitflyer.MarketData, Keyword.put(md, :ws_url, url)

    IO.warn(
      "BITFLYER_WS_URL overrides MarketData ws_url host=#{Bitflyer.Config.WsUrl.host_label(url)}; official Lightstream unused"
    )

  :unchanged ->
    :ok

  :ignored_in_test ->
    :ok
end

config :bitflyer, Bitflyer.Exchange.Rest,
  base_url: "https://api.bitflyer.com",
  http_client: Bitflyer.Exchange.Rest.HTTP,
  receive_timeout: 5_000

# paper 不利化 bps（任意。未設定は config.exs 既定）
paper_slippage = System.get_env("PAPER_SLIPPAGE_BPS")
paper_fee = System.get_env("PAPER_FEE_BPS")

if is_binary(paper_slippage) or is_binary(paper_fee) do
  updates =
    [slippage_bps: paper_slippage, fee_bps: paper_fee]
    |> Enum.filter(fn {_key, val} -> is_binary(val) end)

  paper_cfg =
    Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper, [])
    |> Keyword.merge(updates)

  config :bitflyer, Bitflyer.OrderExecutor.Paper, paper_cfg
end

discord_webhook =
  case System.get_env("DISCORD_WEBHOOK_URL") do
    url when is_binary(url) ->
      trimmed = String.trim(url)
      if trimmed == "", do: nil, else: trimmed

    _ ->
      nil
  end

discord_heartbeat_ms =
  case System.get_env("DISCORD_HEARTBEAT_INTERVAL_MS") do
    nil ->
      :bitflyer
      |> Application.get_env(Bitflyer.Observe.Discord, [])
      |> Keyword.get(:heartbeat_interval_ms, 900_000)

    raw ->
      trimmed = String.trim(raw)

      cond do
        trimmed in ["", "infinity"] ->
          :infinity

        true ->
          case Integer.parse(trimmed) do
            {ms, ""} when ms > 0 ->
              ms

            {0, ""} ->
              :infinity

            _ ->
              raise """
              invalid DISCORD_HEARTBEAT_INTERVAL_MS #{inspect(raw)}.
              Use a positive millisecond integer, 0, or infinity.
              """
          end
      end
  end

config :bitflyer, Bitflyer.Observe.Discord,
  webhook_url: discord_webhook,
  heartbeat_interval_ms: discord_heartbeat_ms

# UI BasicAuth。prod は必須。dev は両方揃ったときだけ有効（test は既定オフ）。
ui_basic_user =
  case System.get_env("UI_BASIC_AUTH_USERNAME") do
    nil -> ""
    val -> String.trim(val)
  end

ui_basic_pass =
  case System.get_env("UI_BASIC_AUTH_PASSWORD") do
    nil -> ""
    val -> String.trim(val)
  end

ui_basic_present? = ui_basic_user != "" and ui_basic_pass != ""

ui_basic_enabled? =
  case config_env() do
    :prod ->
      if ui_basic_present? do
        true
      else
        raise """
        UI_BASIC_AUTH_USERNAME and UI_BASIC_AUTH_PASSWORD are required in prod.
        /health* stays unauthenticated; Status UI and /ops/dashboard require BasicAuth.
        """
      end

    :test ->
      # runtime.exs は test.exs の後に走る。.env の資格情報で StatusLive 等が 401 にならないよう固定オフ。
      false

    _ ->
      ui_basic_present?
  end

config :ui, :basic_auth,
  enabled: ui_basic_enabled?,
  username: ui_basic_user,
  password: ui_basic_pass

# 本番 metrics 消費者（ログ）。未設定時は prod のみ ConsoleReporter を起動。
# イベント毎に stdout へ出すが、tick / Phoenix / VM は除外（低頻度ドメインのみ）。
# UI_METRICS_CONSOLE=false で明示オフ、true/1/yes でオン。率・推移の本線は /ops/dashboard。
metrics_console? =
  case System.get_env("UI_METRICS_CONSOLE") do
    nil ->
      config_env() == :prod

    val ->
      String.downcase(String.trim(val)) in ["1", "true", "yes"]
  end

config :ui, :metrics_console_reporter, metrics_console?

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ui start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ui, UiWeb.Endpoint, server: true
end

config :ui, UiWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :ui, UiWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/ui_web/router\.ex$",
        ~r"lib/ui_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # 公開面の最小化: 既定は loopback。VLAN 等へ意図的に出すときだけ PHX_HTTP_IP を変える。
  # 許可値: 127.0.0.1（既定）/ 0.0.0.0 / ::1 / ::
  phx_http_ip =
    case System.get_env("PHX_HTTP_IP") do
      nil -> "127.0.0.1"
      val -> String.trim(val)
    end

  http_ip =
    case phx_http_ip do
      "127.0.0.1" ->
        {127, 0, 0, 1}

      "0.0.0.0" ->
        {0, 0, 0, 0}

      "::1" ->
        {0, 0, 0, 0, 0, 0, 0, 1}

      "::" ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      other ->
        raise """
        invalid PHX_HTTP_IP #{inspect(other)}.
        Allowed: 127.0.0.1, 0.0.0.0, ::1, ::
        """
    end

  config :ui, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ui, UiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: http_ip
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ui, UiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ui, UiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
