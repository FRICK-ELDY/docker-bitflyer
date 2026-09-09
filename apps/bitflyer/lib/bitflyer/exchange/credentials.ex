defmodule Bitflyer.Exchange.Credentials do
  @moduledoc """
  bitFlyer Private API の資格情報（Application env `:exchange_api`）。

  環境変数名は `BITFLYER_API_KEY` / `BITFLYER_API_SECRET` で固定。
  `TRADE_MODE=live` の起動時必須チェックは `config/runtime.exs` が担う。
  このモジュールの戻り値をログ・telemetry に出さないこと。
  """

  @spec api_key() :: String.t()
  def api_key do
    :bitflyer
    |> Application.get_env(:exchange_api, [])
    |> Keyword.get(:api_key, "")
  end

  @spec api_secret() :: String.t()
  def api_secret do
    :bitflyer
    |> Application.get_env(:exchange_api, [])
    |> Keyword.get(:api_secret, "")
  end

  @spec present?() :: boolean()
  def present? do
    api_key() != "" and api_secret() != ""
  end
end
