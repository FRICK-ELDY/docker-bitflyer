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

  config :ui, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ui, UiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
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

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :ui, Ui.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
