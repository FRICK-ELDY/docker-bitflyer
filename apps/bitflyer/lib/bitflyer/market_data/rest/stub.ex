defmodule Bitflyer.MarketData.Rest.Stub do
  @moduledoc false
  @behaviour Bitflyer.MarketData.Rest.Client

  @impl true
  def fetch_ticker(product_code) when is_binary(product_code) do
    case Keyword.get(config(), :response, :error) do
      :ok ->
        {:ok, fresh_ticker(product_code)}

      :error ->
        {:error, :stub}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_stub_response, other}}
    end
  end

  defp fresh_ticker(product_code) do
    %{
      "product_code" => product_code,
      "ltp" => 5_000_000,
      "timestamp" =>
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }
  end

  defp config, do: Application.get_env(:bitflyer, __MODULE__, [])
end
