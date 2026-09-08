defmodule Bitflyer.MarketData.Normalize do
  @moduledoc """
  取引所 ticker JSON を Cache 用 `{key, value}` に正規化する。
  """

  @doc """
  REST / WS の ticker メッセージを正規化する。
  """
  @spec from_ticker(map()) :: {:ok, {:ticker, String.t()}, %{ltp: Decimal.t()}} | :error
  def from_ticker(message) when is_map(message) do
    product_code = Map.get(message, "product_code") || Map.get(message, :product_code)
    ltp = Map.get(message, "ltp") || Map.get(message, :ltp)

    with true <- is_binary(product_code) and product_code != "",
         {:ok, decimal_ltp} <- cast_decimal(ltp) do
      {:ok, {:ticker, product_code}, %{ltp: decimal_ltp}}
    else
      _ -> :error
    end
  end

  def from_ticker(_), do: :error

  @doc """
  Lightstream JSON-RPC の `channelMessage` 包を正規化する。
  """
  @spec from_ws_frame(binary() | map()) ::
          {:ok, {:ticker, String.t()}, %{ltp: Decimal.t()}} | :ignore | :error
  def from_ws_frame(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} -> from_ws_frame(map)
      {:error, _} -> :error
    end
  end

  def from_ws_frame(%{"method" => "channelMessage", "params" => params}) when is_map(params) do
    message = Map.get(params, "message") || Map.get(params, :message)

    case from_ticker(message) do
      {:ok, _, _} = ok -> ok
      :error -> :error
    end
  end

  def from_ws_frame(%{method: "channelMessage", params: params}) when is_map(params) do
    from_ws_frame(%{"method" => "channelMessage", "params" => stringify_keys(params)})
  end

  def from_ws_frame(_), do: :ignore

  defp cast_decimal(%Decimal{} = d), do: {:ok, d}
  defp cast_decimal(v) when is_binary(v), do: {:ok, Decimal.new(v)}
  defp cast_decimal(v) when is_integer(v), do: {:ok, Decimal.new(v)}
  defp cast_decimal(v) when is_float(v), do: {:ok, Decimal.from_float(v)}
  defp cast_decimal(_), do: :error

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
