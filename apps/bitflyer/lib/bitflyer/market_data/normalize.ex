defmodule Bitflyer.MarketData.Normalize do
  @moduledoc """
  取引所 ticker JSON を Cache 用 `{key, value}` に正規化する。

  値は `{ltp, book}` の 2 層。`ltp` は価格と取引所 `timestamp`
  （`source_timestamp`、UTC `DateTime`）。公開 ticker のオフセット無し日時は
  UTC とみなす（Private API の JST 契約とは別）。時刻欠落は `nil`
  （Risk の skew は fail-closed）。
  `book` は有効な `best_bid` / `best_ask`（正かつ ask >= bid）。
  正の `best_ask_size` があるときだけ板に載せる。欠落・ゼロは板を消さない。
  欠落・ゼロ・負・パース不能・crossed（ask < bid）は板だけ `nil` にし、
  LTP は Cache に載せる（鮮度と時計検査は残る。spread は `bid_ask_missing`）。
  `ltp` の欠落・ゼロ・負、および時刻文字列のパース失敗は `:error`
  （Cache に載せない）。
  WS は `params.channel` と message の `product_code` が一致しない場合 `:error`。
  """

  @type ltp_layer :: %{
          required(:price) => Decimal.t(),
          required(:source_timestamp) => DateTime.t() | nil
        }

  @type book_layer :: %{
          required(:best_bid) => Decimal.t(),
          required(:best_ask) => Decimal.t(),
          optional(:best_ask_size) => Decimal.t()
        }

  @type ticker_value :: %{
          required(:ltp) => ltp_layer(),
          required(:book) => book_layer() | nil
        }

  @doc """
  REST / WS の ticker メッセージを正規化する。
  """
  @spec from_ticker(map()) :: {:ok, {:ticker, String.t()}, ticker_value()} | :error
  def from_ticker(message) when is_map(message) do
    product_code = Map.get(message, "product_code") || Map.get(message, :product_code)
    ltp = Map.get(message, "ltp") || Map.get(message, :ltp)
    bid = Map.get(message, "best_bid") || Map.get(message, :best_bid)
    ask = Map.get(message, "best_ask") || Map.get(message, :best_ask)
    ask_size = Map.get(message, "best_ask_size") || Map.get(message, :best_ask_size)
    timestamp = Map.get(message, "timestamp") || Map.get(message, :timestamp)

    with true <- is_binary(product_code) and product_code != "",
         {:ok, decimal_ltp} <- cast_positive_decimal(ltp),
         {:ok, source_timestamp} <- cast_source_timestamp(timestamp) do
      {:ok, {:ticker, product_code},
       %{
         ltp: %{price: decimal_ltp, source_timestamp: source_timestamp},
         book: cast_book(bid, ask, ask_size)
       }}
    else
      _ -> :error
    end
  end

  def from_ticker(_), do: :error

  @doc """
  WS フレームを 1 回だけ JSON デコードする。
  """
  @spec decode_ws_frame(binary()) :: {:ok, term()} | :error
  def decode_ws_frame(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  def decode_ws_frame(_), do: :error

  @doc """
  Lightstream JSON-RPC の `channelMessage` 包を正規化する。
  """
  @spec from_ws_frame(binary() | map()) ::
          {:ok, {:ticker, String.t()}, ticker_value()} | :ignore | :error
  def from_ws_frame(raw) when is_binary(raw) do
    case decode_ws_frame(raw) do
      {:ok, decoded} -> from_ws_frame(decoded)
      :error -> :error
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
  ticker 値から正の LTP を取る。

  本番は `{ltp: %{price: ...}}`。平坦な `%{ltp: Decimal}` も読む
  （テストや移行前の手書き値）。
  """
  @spec ltp_price(term()) :: Decimal.t() | nil
  def ltp_price(%{ltp: %{price: price}}), do: positive_decimal(price)
  def ltp_price(%{"ltp" => %{"price" => price}}), do: positive_decimal(price)
  def ltp_price(%{ltp: price}), do: positive_decimal(price)
  def ltp_price(%{"ltp" => price}), do: positive_decimal(price)
  def ltp_price(_), do: nil

  @doc """
  ticker 値から有効な板（正かつ ask >= bid）を取る。

  `book` キーがあるときはその層だけを見る。`nil` や異常は `:miss` で、
  同じマップの平坦な `best_bid` / `best_ask` には落ちない。
  層が無い手書き値だけ、平坦な気配を読む。
  """
  @spec book(term()) :: {:ok, Decimal.t(), Decimal.t()} | :miss
  def book(%{book: nil}), do: :miss
  def book(%{"book" => nil}), do: :miss
  def book(%{book: book}) when is_map(book), do: book_quotes(book)
  def book(%{"book" => book}) when is_map(book), do: book_quotes(book)
  def book(%{best_bid: bid, best_ask: ask}), do: valid_book(bid, ask)
  def book(%{"best_bid" => bid, "best_ask" => ask}), do: valid_book(bid, ask)
  def book(_), do: :miss

  @doc """
  最上段の ask 数量。板が無い、または正の数量が無いときは `:miss`。

  JSON 数値は float になるので、satoshi（小数 8 桁）へ切り捨ててから使う。
  切り上げると、見えている数量より大きい注文を最上段以内とみなす。
  """
  @spec best_ask_size(term()) :: {:ok, Decimal.t()} | :miss
  def best_ask_size(%{book: book}) when is_map(book), do: quote_size(book)
  def best_ask_size(%{"book" => book}) when is_map(book), do: quote_size(book)
  def best_ask_size(%{book: _}), do: :miss
  def best_ask_size(%{"book" => _}), do: :miss
  def best_ask_size(value) when is_map(value), do: quote_size(value)
  def best_ask_size(_), do: :miss

  @doc """
  時計検査用の取引所時刻。

  LTP 層（`ltp.price` がある）があるときはその `source_timestamp` だけを見る。
  層の時刻が nil なら平坦フィールドへは落ちない。層が無い手書き値だけ平坦な
  `source_timestamp` を読む。
  """
  @spec source_timestamp(term()) :: DateTime.t() | nil
  def source_timestamp(%{ltp: ltp}) when is_map(ltp) and is_map_key(ltp, :price) do
    case Map.get(ltp, :source_timestamp) do
      %DateTime{} = ts -> ts
      _ -> nil
    end
  end

  def source_timestamp(%{"ltp" => ltp}) when is_map(ltp) and is_map_key(ltp, "price") do
    case Map.get(ltp, "source_timestamp") do
      %DateTime{} = ts -> ts
      _ -> nil
    end
  end

  def source_timestamp(%{source_timestamp: %DateTime{} = ts}), do: ts
  def source_timestamp(%{"source_timestamp" => %DateTime{} = ts}), do: ts
  def source_timestamp(_), do: nil

  @doc """
  JSON-RPC 応答（購読 ACK / error）。

  Lightstream は subscribe 成功で `result: true`（公式）。`false` / `null` /
  欠落は失敗。`channelMessage` は `:not_rpc`。`channelError` は再接続。
  応答 `id` は整数に正規化する（文字列 `"1"` も 1）。
  """
  @spec rpc_response(binary() | map()) ::
          {:ok, pos_integer()} | {:error, term(), term()} | :not_rpc
  def rpc_response(raw) when is_binary(raw) do
    case decode_ws_frame(raw) do
      {:ok, decoded} -> rpc_response(decoded)
      :error -> :not_rpc
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

  defp cast_book(bid, ask, ask_size) do
    with {:ok, decimal_bid} <- cast_positive_decimal(bid),
         {:ok, decimal_ask} <- cast_positive_decimal(ask),
         true <- Decimal.compare(decimal_ask, decimal_bid) != :lt do
      book = %{best_bid: decimal_bid, best_ask: decimal_ask}

      case cast_size(ask_size) do
        {:ok, size} -> Map.put(book, :best_ask_size, size)
        _ -> book
      end
    else
      _ -> nil
    end
  end

  defp quote_size(map) when is_map(map) do
    raw = Map.get(map, :best_ask_size) || Map.get(map, "best_ask_size")

    case cast_size(raw) do
      {:ok, size} -> {:ok, size}
      _ -> :miss
    end
  end

  # JSON 数値は float。satoshi へ切り捨て、見えている数量を大きく見せない。
  defp cast_size(v) do
    case Decimal.cast(v) do
      {:ok, %Decimal{} = decimal} ->
        floored = Decimal.round(decimal, 8, :floor)

        if Decimal.positive?(floored), do: {:ok, floored}, else: :error

      _ ->
        :error
    end
  end

  defp cast_positive_decimal(v) do
    case Decimal.cast(v) do
      {:ok, %Decimal{} = d} ->
        if Decimal.positive?(d), do: {:ok, d}, else: :error

      _ ->
        :error
    end
  end

  defp positive_decimal(%Decimal{} = d) do
    if Decimal.positive?(d), do: d, else: nil
  end

  defp positive_decimal(_), do: nil

  defp book_quotes(%{best_bid: bid, best_ask: ask}), do: valid_book(bid, ask)
  defp book_quotes(%{"best_bid" => bid, "best_ask" => ask}), do: valid_book(bid, ask)
  defp book_quotes(_), do: :miss

  defp valid_book(%Decimal{} = bid, %Decimal{} = ask) do
    if Decimal.positive?(bid) and Decimal.positive?(ask) and
         Decimal.compare(ask, bid) != :lt do
      {:ok, bid, ask}
    else
      :miss
    end
  end

  defp valid_book(_, _), do: :miss

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
