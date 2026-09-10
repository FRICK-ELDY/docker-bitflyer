defmodule Bitflyer.MarketData.Normalize do
  @moduledoc """
  取引所 ticker JSON を Cache 用 `{key, value}` に正規化する。

  `ltp` に加え、取引所 `timestamp` を `source_timestamp`（UTC `DateTime`）として保持する。
  公開 ticker のオフセット無し日時は UTC とみなす（Private API の JST 契約とは別）。
  欠落は `nil`（Risk の skew は fail-closed）。
  WS は `params.channel` と message の `product_code` が一致しない場合 `:error`。
  """

  @type ticker_value :: %{
          required(:ltp) => Decimal.t(),
          required(:source_timestamp) => DateTime.t() | nil
        }

  @doc """
  REST / WS の ticker メッセージを正規化する。
  """
  @spec from_ticker(map()) :: {:ok, {:ticker, String.t()}, ticker_value()} | :error
  def from_ticker(message) when is_map(message) do
    product_code = Map.get(message, "product_code") || Map.get(message, :product_code)
    ltp = Map.get(message, "ltp") || Map.get(message, :ltp)
    timestamp = Map.get(message, "timestamp") || Map.get(message, :timestamp)

    with true <- is_binary(product_code) and product_code != "",
         {:ok, decimal_ltp} <- cast_decimal(ltp),
         {:ok, source_timestamp} <- cast_source_timestamp(timestamp) do
      {:ok, {:ticker, product_code}, %{ltp: decimal_ltp, source_timestamp: source_timestamp}}
    else
      _ -> :error
    end
  end

  def from_ticker(_), do: :error

  @doc """
  Lightstream JSON-RPC の `channelMessage` 包を正規化する。
  """
  @spec from_ws_frame(binary() | map()) ::
          {:ok, {:ticker, String.t()}, ticker_value()} | :ignore | :error
  def from_ws_frame(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} -> from_ws_frame(map)
      {:error, _} -> :error
    end
  end

  def from_ws_frame(map) when is_map(map) do
    method = Map.get(map, "method") || Map.get(map, :method)
    params = Map.get(map, "params") || Map.get(map, :params)

    if method == "channelMessage" and is_map(params) do
      channel = Map.get(params, "channel") || Map.get(params, :channel)
      message = Map.get(params, "message") || Map.get(params, :message)

      case from_ticker(message) do
        {:ok, {:ticker, product_code} = key, value} ->
          if channel == Bitflyer.MarketData.ticker_channel(product_code) do
            {:ok, key, value}
          else
            :error
          end

        _ ->
          :error
      end
    else
      :ignore
    end
  end

  def from_ws_frame(_), do: :ignore

  defp cast_decimal(v) do
    case Decimal.cast(v) do
      {:ok, %Decimal{} = d} -> {:ok, d}
      _ -> :error
    end
  end

  # 欠落は許容（nil）。値が有るのにパースできない場合のみ :error。
  defp cast_source_timestamp(nil), do: {:ok, nil}
  defp cast_source_timestamp(""), do: {:ok, nil}

  defp cast_source_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp cast_source_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive(naive, "Etc/UTC")
          {:error, _} -> :error
        end

      {:error, _} ->
        :error
    end
  end

  defp cast_source_timestamp(_), do: :error
end
