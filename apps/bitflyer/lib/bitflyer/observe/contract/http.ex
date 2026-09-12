defmodule Bitflyer.Observe.Contract.HTTP do
  @moduledoc false

  @doc """
  公開 REST 1 回。発注経路には使わない。
  """
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(url, opts \\ []) when is_binary(url) do
    params = Keyword.get(opts, :params, [])
    receive_timeout = Keyword.get(opts, :receive_timeout, 5_000)

    case Req.get(url, params: params, receive_timeout: receive_timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
