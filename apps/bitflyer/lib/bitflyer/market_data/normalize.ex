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

  @doc """
  JSON-RPC 応答（購読 ACK / error）。

  Lightstream は subscribe 成功で `result: true`（公式）。`false` / `null` /
  欠落は失敗。`channelMessage` は `:not_rpc`。`channelError` は再接続。
  応答 `id` は整数に正規化する（文字列 `"1"` も 1）。
  """
  @spec rpc_response(binary() | map()) ::
          {:ok, pos_integer()} | {:error, term(), term()} | :not_rpc
  def rpc_response(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} -> rpc_response(map)
      {:error, _} -> :not_rpc
    end
  end

  def rpc_response(map) when is_map(map) do
    method = Map.get(map, "method") || Map.get(map, :method)

    cond do
      method == "channelMessage" ->
        :not_rpc

      method == "channelError" ->
        {:error, rpc_id(map), :channel_error}

      true ->
        classify_rpc_result(map)
    end
  end

  def rpc_response(_), do: :not_rpc

  defp classify_rpc_result(map) do
    case normalize_rpc_id(rpc_id(map)) do
      :error ->
        if is_nil(rpc_id(map)), do: :not_rpc, else: {:error, rpc_id(map), :invalid_id}

      {:ok, id} ->
        error = Map.get(map, "error") || Map.get(map, :error)

        cond do
          not is_nil(error) ->
            {:error, id, rpc_error_reason(error)}

          rpc_result(map) == true ->
            {:ok, id}

          true ->
            {:error, id, :subscribe_rejected}
        end
    end
  end

  defp rpc_id(map), do: Map.get(map, "id") || Map.get(map, :id)

  defp rpc_result(map) do
    cond do
      Map.has_key?(map, "result") -> Map.get(map, "result")
      Map.has_key?(map, :result) -> Map.get(map, :result)
      true -> :missing
    end
  end

  defp normalize_rpc_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_rpc_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp normalize_rpc_id(_), do: :error

  defp rpc_error_reason(%{"message" => message}) when is_binary(message), do: message
  defp rpc_error_reason(%{message: message}) when is_binary(message), do: message
  defp rpc_error_reason(_), do: :rpc_error

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
