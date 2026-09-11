defmodule Bitflyer.Exchange.Rest do
  @moduledoc """
  bitFlyer Private REST クライアント（HMAC 署名付き）。

  `Bitflyer.Exchange.Client` を実装する。HTTP は `:http_client`（既定 `Rest.HTTP`）へ委譲し、
  テストでは fixture 応答を差し込める。実ネットを前提にしない。
  """

  @behaviour Bitflyer.Exchange.Client

  alias Bitflyer.Exchange.{Auth, Credentials}
  alias Bitflyer.Exchange.Rest.Decode
  alias Bitflyer.Trading.Product

  @default_base_url "https://api.bitflyer.com"

  @impl true
  def fetch_reconcile_snapshot do
    product_codes = product_codes()

    with {:ok, balances} <- get_balances(),
         {:ok, positions} <- get_positions(product_codes),
         {:ok, open_orders} <- get_open_orders(product_codes) do
      {:ok,
       %{
         balances: balances,
         positions: positions,
         open_orders: open_orders
       }}
    end
  end

  @impl true
  def place_order(request) when is_map(request) do
    with :ok <- require_credentials(),
         {:ok, body_map} <- build_send_body(request),
         {:ok, body} <- encode_json(body_map),
         {:ok, response} <- request(:post, "/v1/me/sendchildorder", body) do
      case response do
        %{"child_order_acceptance_id" => id} when is_binary(id) and id != "" ->
          {:ok, %{exchange_order_id: id}}

        %{child_order_acceptance_id: id} when is_binary(id) and id != "" ->
          {:ok, %{exchange_order_id: id}}

        other ->
          {:error, {:invalid_response, other}}
      end
    end
  end

  @impl true
  def cancel_order(request) when is_map(request) do
    product_code = Map.fetch!(request, :product_code)
    exchange_order_id = Map.fetch!(request, :exchange_order_id)

    body_map = %{
      "product_code" => product_code,
      "child_order_acceptance_id" => exchange_order_id
    }

    with :ok <- require_credentials(),
         {:ok, body} <- encode_json(body_map),
         {:ok, _} <- request(:post, "/v1/me/cancelchildorder", body) do
      :ok
    end
  end

  @impl true
  def fetch_order(request) when is_map(request) do
    product_code = Map.fetch!(request, :product_code)
    exchange_order_id = Map.fetch!(request, :exchange_order_id)

    query = [
      {"product_code", product_code},
      {"child_order_acceptance_id", exchange_order_id}
    ]

    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getchildorders", "", query),
         {:ok, rows} <- decode_rows(List.wrap(body), &Decode.order_info/1) do
      case Enum.find(rows, &(&1.exchange_order_id == exchange_order_id)) do
        nil -> {:error, :order_not_found}
        info -> {:ok, info}
      end
    end
  end

  @impl true
  def list_child_orders(request) when is_map(request) do
    product_code = Map.fetch!(request, :product_code)

    query =
      [{"product_code", product_code}]
      |> maybe_put_query("count", Map.get(request, :count) || 500)
      |> maybe_put_query("child_order_state", Map.get(request, :child_order_state))

    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getchildorders", "", query),
         {:ok, orders} <- decode_rows(List.wrap(body), &Decode.child_order/1) do
      {:ok, orders}
    end
  end

  @impl true
  def fetch_executions(request) when is_map(request) do
    product_code = Map.fetch!(request, :product_code)

    query =
      [{"product_code", product_code}]
      |> maybe_put_query("child_order_acceptance_id", Map.get(request, :exchange_order_id))
      |> maybe_put_query("count", Map.get(request, :count))

    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getexecutions", "", query),
         {:ok, executions} <-
           decode_rows(List.wrap(body), &Decode.execution(&1, product_code)) do
      {:ok, executions}
    end
  end

  @impl true
  def get_permissions do
    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getpermissions") do
      decode_permissions(body)
    end
  end

  defp decode_permissions(body) when is_list(body) do
    if Enum.all?(body, &is_binary/1) do
      {:ok, body}
    else
      {:error, {:invalid_response, body}}
    end
  end

  defp decode_permissions(other), do: {:error, {:invalid_response, other}}

  defp get_balances do
    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getbalance"),
         {:ok, balances} <- decode_rows(List.wrap(body), &Decode.balance/1) do
      {:ok, balances}
    end
  end

  defp get_positions(product_codes) do
    Enum.reduce_while(product_codes, {:ok, []}, fn product_code, {:ok, acc} ->
      case get_positions_for(product_code) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp get_positions_for(product_code) do
    product_code = to_string(product_code)

    # getpositions は FX/CFD 専用。spot・unsupported では呼ばない（正本は getbalance 等）。
    # product_codes が spot のみのとき、同一キー口座の FX 建玉は取得しない（運用前提は README）。
    if Product.fx?(product_code) do
      with :ok <- require_credentials(),
           {:ok, body} <-
             request(:get, "/v1/me/getpositions", "", [{"product_code", product_code}]),
           {:ok, positions} <- decode_rows(List.wrap(body), &Decode.position/1) do
        {:ok, aggregate_positions(positions)}
      end
    else
      {:ok, []}
    end
  end

  # 同一 product_code+side の建玉を合算（bitFlyer は複数行を返すことがある）
  defp aggregate_positions(positions) do
    positions
    |> Enum.group_by(&{&1.product_code, &1.side})
    |> Enum.map(fn {{product_code, side}, rows} ->
      total_size =
        Enum.reduce(rows, Decimal.new("0"), fn row, acc -> Decimal.add(acc, row.size) end)

      weighted =
        Enum.reduce(rows, Decimal.new("0"), fn row, acc ->
          Decimal.add(acc, Decimal.mult(row.size, row.average_price))
        end)

      avg =
        if Decimal.equal?(total_size, Decimal.new("0")) do
          Decimal.new("0")
        else
          Decimal.div(weighted, total_size)
        end

      %{product_code: product_code, side: side, size: total_size, average_price: avg}
    end)
  end

  defp get_open_orders(product_codes) do
    Enum.reduce_while(product_codes, {:ok, []}, fn product_code, {:ok, acc} ->
      case get_open_orders_for(product_code) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp get_open_orders_for(product_code) do
    query = [
      {"product_code", product_code},
      {"child_order_state", "ACTIVE"}
    ]

    with :ok <- require_credentials(),
         {:ok, body} <- request(:get, "/v1/me/getchildorders", "", query),
         {:ok, orders} <- decode_rows(List.wrap(body), &Decode.open_order/1) do
      {:ok, orders}
    end
  end

  defp decode_rows(rows, fun) when is_list(rows) and is_function(fun, 1) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case fun.(row) do
        {:ok, decoded} ->
          {:cont, {:ok, [decoded | acc]}}

        :skip ->
          {:cont, {:ok, acc}}

        {:error, :invalid_number} = error ->
          Bitflyer.Telemetry.log(
            :warning,
            "exchange decode rejected invalid number; failing snapshot",
            decode_error_meta(row)
          )

          {:halt, error}

        {:error, :invalid_datetime} = error ->
          Bitflyer.Telemetry.log(
            :warning,
            "exchange decode rejected invalid datetime; failing list",
            decode_error_meta(row)
          )

          {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  # 行全体の inspect は避ける（ノイズ）。識別に足りるキーだけ残す。
  defp decode_error_meta(row) when is_map(row) do
    %{
      currency: Map.get(row, "currency_code") || Map.get(row, :currency_code),
      product_code: Map.get(row, "product_code") || Map.get(row, :product_code),
      side: Map.get(row, "side") || Map.get(row, :side),
      exchange_order_id:
        Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)
    }
  end

  defp decode_error_meta(_), do: %{}

  defp build_send_body(request) do
    side =
      case Map.fetch!(request, :side) do
        :buy -> "BUY"
        :sell -> "SELL"
      end

    order_type =
      case Map.fetch!(request, :order_type) do
        :limit -> "LIMIT"
        :market -> "MARKET"
      end

    size = Map.fetch!(request, :size) |> decimal_to_string()

    base = %{
      "product_code" => Map.fetch!(request, :product_code),
      "child_order_type" => order_type,
      "side" => side,
      "size" => size
    }

    body =
      case {order_type, Map.get(request, :price)} do
        {"LIMIT", %Decimal{} = price} ->
          Map.put(base, "price", decimal_to_string(price))

        {"LIMIT", _} ->
          :invalid_price

        {"MARKET", _} ->
          base
      end

    case body do
      :invalid_price -> {:error, :invalid_request}
      map when is_map(map) -> {:ok, map}
    end
  end

  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp encode_json(map) when is_map(map) do
    {:ok, Jason.encode!(map)}
  rescue
    e -> {:error, {:json_encode_failed, e}}
  end

  defp request(method, path, body \\ "", query \\ [])

  defp request(method, path, body, query) do
    base = String.trim_trailing(base_url(), "/")
    query_string = encode_query(query)
    signed_path = path <> query_string
    url = base <> signed_path
    method_string = method |> Atom.to_string() |> String.upcase()
    timestamp = Auth.timestamp()

    headers =
      Auth.headers(
        Credentials.api_key(),
        Credentials.api_secret(),
        timestamp,
        method_string,
        signed_path,
        body
      )

    case http_client().request(method, url, headers, body, receive_timeout: receive_timeout()) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} when status in 400..499 ->
        {:error, Decode.map_error(status, resp_body)}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        # 5xx は受注不明の可能性（POST 発注時）。呼び出し側が分類する。
        {:error, :disconnected}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http_status, status, resp_body}}

      {:error, reason} ->
        {:error, Decode.transport_error(reason)}
    end
  end

  defp encode_query([]), do: ""

  defp encode_query(pairs) when is_list(pairs) do
    "?" <>
      (pairs
       |> Enum.map(fn {k, v} ->
         URI.encode_www_form(to_string(k)) <> "=" <> URI.encode_www_form(to_string(v))
       end)
       |> Enum.join("&"))
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query

  defp maybe_put_query(query, key, value) do
    query ++ [{key, value}]
  end

  defp require_credentials do
    if Credentials.present?() do
      :ok
    else
      {:error, :exchange_unavailable}
    end
  end

  defp config do
    Application.get_env(:bitflyer, __MODULE__, [])
  end

  defp base_url do
    Keyword.get(config(), :base_url) ||
      get_in(Application.get_env(:bitflyer, Bitflyer.MarketData, []), [:rest_base_url]) ||
      @default_base_url
  end

  defp http_client do
    Keyword.get(config(), :http_client, Bitflyer.Exchange.Rest.HTTP)
  end

  defp receive_timeout do
    Keyword.get(config(), :receive_timeout, 5_000)
  end

  defp product_codes, do: Bitflyer.MarketData.product_codes()
end
