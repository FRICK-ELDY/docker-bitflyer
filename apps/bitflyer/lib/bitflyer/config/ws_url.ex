defmodule Bitflyer.Config.WsUrl do
  @moduledoc """
  Game Day 用 `BITFLYER_WS_URL` の解釈。

  `config/runtime.exs` から呼ぶ（Application 起動前でもモジュールは利用可。
  `LiveSafety` と同じ。プロセスや未適用の Application env には触れない）。
  live では公式 Lightstream 以外を読めない。空・未設定は config.exs の既定を残す。
  """

  @official_host "ws.lightstream.bitflyer.com"

  @doc """
  環境変数の生値を解釈する。

  - 空 / nil → `:unchanged`
  - `:test` → `:ignored_in_test`（Socket.Local を壊さない）
  - `:live` かつ非空 → `ArgumentError`（残った切断 URL や偽エンドポイントを拒否）
  - `:dry_run` / `:paper` かつ非空 → `{:override, url}`
  """
  @spec resolve(String.t() | nil, atom(), atom()) ::
          :unchanged | :ignored_in_test | {:override, String.t()}
  def resolve(raw, trade_mode, config_env)

  def resolve(nil, _trade_mode, _config_env), do: :unchanged

  def resolve(raw, trade_mode, config_env) when is_binary(raw) do
    case String.trim(raw) do
      "" -> :unchanged
      url -> resolve_trimmed(url, trade_mode, config_env)
    end
  end

  @doc """
  警告用。クエリや認証情報は出さず scheme + host だけ。
  """
  @spec host_label(String.t()) :: String.t()
  def host_label(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        "unparseable"
    end
  end

  @doc false
  @spec official_host() :: String.t()
  def official_host, do: @official_host

  defp resolve_trimmed(_url, _trade_mode, :test), do: :ignored_in_test

  defp resolve_trimmed(_url, :live, _config_env) do
    raise ArgumentError, """
    BITFLYER_WS_URL cannot be set when TRADE_MODE=live.
    Game Day feed inject is dry_run / paper only. A leftover URL would
    replace official Lightstream (#{@official_host}) and could accept forged ticks.
    Unset BITFLYER_WS_URL and use the config.exs default.
    """
  end

  defp resolve_trimmed(url, trade_mode, _config_env)
       when trade_mode in [:dry_run, :paper] do
    {:override, url}
  end
end
