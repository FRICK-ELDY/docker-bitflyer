defmodule Bitflyer.Exchange.Rest.HTTP do
  @moduledoc false

  @doc """
  Private REST 1 回分。`body` は署名に使った文字列と同一を送る（POST）。
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], String.t() | nil, keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(method, url, headers, body, opts \\ [])

  def request(:get, url, headers, _body, opts) when is_binary(url) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 5_000)

    Req.get(url,
      headers: headers,
      receive_timeout: receive_timeout,
      retry: false
    )
  end

  def request(:post, url, headers, body, opts)
      when is_binary(url) and is_binary(body) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 5_000)

    Req.post(url,
      headers: headers,
      body: body,
      receive_timeout: receive_timeout,
      retry: false
    )
  end
end
