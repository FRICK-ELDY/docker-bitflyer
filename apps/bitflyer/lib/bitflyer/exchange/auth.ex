defmodule Bitflyer.Exchange.Auth do
  @moduledoc """
  bitFlyer Private API の ACCESS-SIGN 生成。

  署名対象文字列は `timestamp <> METHOD <> path <> body`。
  path にクエリを含める（GET）。POST の body は送信する JSON 文字列と同一であること。
  """

  @doc """
  HMAC-SHA256（hex）で ACCESS-SIGN を作る。
  """
  @spec sign(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def sign(api_secret, timestamp, method, path, body \\ "")
      when is_binary(api_secret) and is_binary(timestamp) and is_binary(method) and
             is_binary(path) and is_binary(body) do
    payload = timestamp <> method <> path <> body

    :hmac
    |> :crypto.mac(:sha256, api_secret, payload)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Private API 用ヘッダを組み立てる。`api_key` / `api_secret` は返さない。
  """
  @spec headers(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          [{String.t(), String.t()}]
  def headers(api_key, api_secret, timestamp, method, path, body \\ "") do
    [
      {"ACCESS-KEY", api_key},
      {"ACCESS-TIMESTAMP", timestamp},
      {"ACCESS-SIGN", sign(api_secret, timestamp, method, path, body)},
      {"Content-Type", "application/json"}
    ]
  end

  @doc """
  Unix 秒（小数）のタイムスタンプ文字列。
  """
  @spec timestamp() :: String.t()
  def timestamp do
    (System.system_time(:millisecond) / 1000)
    |> :erlang.float_to_binary(decimals: 3)
  end
end
