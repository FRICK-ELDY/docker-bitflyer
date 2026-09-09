defmodule Bitflyer.Observe.Discord.HTTP do
  @moduledoc false

  @doc """
  Discord Incoming Webhook へ JSON を POST する。
  """
  @spec post_json(String.t(), map()) :: :ok | {:error, term()}
  def post_json(url, body) when is_binary(url) and is_map(body) do
    case Req.post(url, json: body, receive_timeout: 5_000, retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
