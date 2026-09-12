defmodule Bitflyer.Observe.Contract do
  @moduledoc """
  bitFlyer の read-only 契約検査（発注・取消はしない）。

  - 公開 GET（キー不要）: ticker / 直近 executions / markets
  - `--private` 時のみ署名 GET（`getpermissions` + 突合 snapshot）。POST しない
  - 記録済み匿名 corpus を Decode / 意味論で検証する（ネット不要）
  """

  alias Bitflyer.Exchange.Rest.Decode
  alias Bitflyer.Observe.Contract.HTTP

  @default_base_url "https://api.bitflyer.com"
  @default_product "BTC_JPY"
  @forbidden_private_paths ["/v1/me/sendchildorder", "/v1/me/cancelchildorder"]

  @type check :: %{name: atom(), status: :ok | :error, reason: term() | nil, detail: map()}
  @type report :: %{
          product_code: String.t(),
          public: [check()],
          private: :skipped | [check()]
        }

  @doc """
  公開（と任意で private GET）契約を走らせる。

  ## Options
  - `:product_code` — 既定 `BTC_JPY`
  - `:base_url` — 既定 `https://api.bitflyer.com`
  - `:private?` — true なら署名 GET のみ追加
  - `:http` / `:exchange` — テスト注入
  - `:write_corpus?` / `:corpus_dir` — 公開応答を匿名化して書く
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    product_code = Keyword.get(opts, :product_code, @default_product)
    public = public_checks(product_code, opts)

    private =
      if Keyword.get(opts, :private?, false) do
        private_checks(opts)
      else
        :skipped
      end

    report = %{product_code: product_code, public: public, private: private}

    if Keyword.get(opts, :write_corpus?, false) do
      _ = write_public_corpus(public, product_code, opts)
    end

    if failed?(report), do: {:error, report}, else: {:ok, report}
  end

  @doc """
  コミット済み corpus を意味論検証する（ネット不要）。
  """
  @spec check_corpus(keyword()) :: {:ok, [check()]} | {:error, [check()]}
  def check_corpus(opts \\ []) do
    dir = Keyword.get(opts, :corpus_dir, corpus_dir())
    product_code = Keyword.get(opts, :product_code, @default_product)

    checks = [
      corpus_ticker(dir, product_code),
      corpus_executions(dir, product_code),
      corpus_markets(dir, product_code)
    ]

    if Enum.any?(checks, &(&1.status == :error)), do: {:error, checks}, else: {:ok, checks}
  end

  @doc """
  契約 corpus の既定ディレクトリ。
  """
  @spec corpus_dir() :: String.t()
  def corpus_dir do
    Application.app_dir(:bitflyer, "priv/contract/corpus")
  end

  @doc false
  @spec forbidden_private_paths() :: [String.t()]
  def forbidden_private_paths, do: @forbidden_private_paths

  defp public_checks(product_code, opts) do
    http = Keyword.get(opts, :http, HTTP)
    base = String.trim_trailing(Keyword.get(opts, :base_url, @default_base_url), "/")

    [
      fetch_and_check(http, :ticker, "#{base}/v1/ticker", [product_code: product_code], fn body ->
        check_ticker(body, product_code)
      end),
      fetch_and_check(
        http,
        :executions,
        "#{base}/v1/getexecutions",
        [product_code: product_code, count: 5],
        fn body -> check_public_executions(body) end
      ),
      fetch_and_check(http, :markets, "#{base}/v1/getmarkets", [], fn body ->
        check_markets(body, product_code)
      end)
    ]
  end

  defp fetch_and_check(http, name, url, params, fun) do
    case http.get(url, params: params, receive_timeout: 5_000) do
      {:ok, body} ->
        case fun.(body) do
          {:ok, detail} ->
            check(name, :ok, nil, Map.put(detail, :raw, body))

          {:error, reason} ->
            check(name, :error, reason, %{raw: body})
        end

      {:error, reason} ->
        check(name, :error, reason, %{})
    end
  end

  defp private_checks(opts) do
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange.Rest)

    [
      private_one(:permissions, fn -> exchange.get_permissions() end),
      private_one(:reconcile_snapshot, fn -> exchange.fetch_reconcile_snapshot() end)
    ]
  end

  defp private_one(name, fun) do
    case fun.() do
      {:ok, value} ->
        check(name, :ok, nil, %{result: summarize_private(name, value)})

      {:error, reason} ->
        check(name, :error, reason, %{})
    end
  end

  defp summarize_private(:permissions, list) when is_list(list), do: %{count: length(list)}

  defp summarize_private(:reconcile_snapshot, snap) when is_map(snap) do
    %{
      balances: length(Map.get(snap, :balances, [])),
      positions: length(Map.get(snap, :positions, [])),
      open_orders: length(Map.get(snap, :open_orders, []))
    }
  end

  defp summarize_private(_name, _value), do: %{}

  defp check_ticker(body, product_code) when is_map(body) do
    with {:ok, code} <- require_string(body, "product_code"),
         :ok <- same_product(code, product_code),
         {:ok, ltp} <- require_positive(body, "ltp"),
         {:ok, bid} <- require_positive(body, "best_bid"),
         {:ok, ask} <- require_positive(body, "best_ask"),
         :ok <- require_timestamp(body, "timestamp") do
      if Decimal.compare(ask, bid) == :lt do
        {:error, :crossed_book}
      else
        {:ok, %{product_code: code, ltp: ltp, best_bid: bid, best_ask: ask}}
      end
    end
  end

  defp check_ticker(_, _), do: {:error, :invalid_structure}

  defp check_public_executions(body) when is_list(body) and body != [] do
    body
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case check_public_execution(row) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, %{count: length(rows)}}
      {:error, _} = error -> error
    end
  end

  defp check_public_executions(_), do: {:error, :invalid_structure}

  defp check_public_execution(row) when is_map(row) do
    raw_side = Map.get(row, "side") || Map.get(row, :side)
    id = Map.get(row, "id") || Map.get(row, :id)

    with {:ok, _} <- require_execution_id(id),
         {:ok, side} <- require_side(raw_side),
         {:ok, price} <- require_positive_value(Map.get(row, "price") || Map.get(row, :price)),
         {:ok, size} <- require_positive_value(Map.get(row, "size") || Map.get(row, :size)),
         :ok <- require_timestamp_value(Map.get(row, "exec_date") || Map.get(row, :exec_date)) do
      {:ok, %{id: id, side: side, price: price, size: size}}
    end
  end

  defp check_public_execution(_), do: {:error, :invalid_structure}

  defp check_markets(body, product_code) when is_list(body) and body != [] do
    codes =
      Enum.flat_map(body, fn
        %{} = row ->
          case Map.get(row, "product_code") || Map.get(row, :product_code) do
            code when is_binary(code) and code != "" -> [code]
            _ -> []
          end

        _ ->
          []
      end)

    if product_code in codes do
      {:ok, %{count: length(codes), includes: product_code}}
    else
      {:error, :product_missing}
    end
  end

  defp check_markets(_, _), do: {:error, :invalid_structure}

  defp corpus_ticker(dir, product_code) do
    path = Path.join([dir, "public", "ticker_btc_jpy.json"])

    case read_json(path) do
      {:ok, body} ->
        case check_ticker(body, product_code) do
          {:ok, detail} -> check(:corpus_ticker, :ok, nil, detail)
          {:error, reason} -> check(:corpus_ticker, :error, reason, %{path: path})
        end

      {:error, reason} ->
        check(:corpus_ticker, :error, reason, %{path: path})
    end
  end

  defp corpus_executions(dir, _product_code) do
    path = Path.join([dir, "public", "executions_btc_jpy.json"])

    case read_json(path) do
      {:ok, body} ->
        case check_public_executions(body) do
          {:ok, detail} -> check(:corpus_executions, :ok, nil, detail)
          {:error, reason} -> check(:corpus_executions, :error, reason, %{path: path})
        end

      {:error, reason} ->
        check(:corpus_executions, :error, reason, %{path: path})
    end
  end

  defp corpus_markets(dir, product_code) do
    path = Path.join([dir, "public", "markets.json"])

    case read_json(path) do
      {:ok, body} ->
        case check_markets(body, product_code) do
          {:ok, detail} -> check(:corpus_markets, :ok, nil, detail)
          {:error, reason} -> check(:corpus_markets, :error, reason, %{path: path})
        end

      {:error, reason} ->
        check(:corpus_markets, :error, reason, %{path: path})
    end
  end

  defp write_public_corpus(public, product_code, opts) do
    dir = Keyword.get(opts, :corpus_dir, corpus_dir())
    public_dir = Path.join(dir, "public")
    File.mkdir_p!(public_dir)

    Enum.each(public, fn
      %{name: :ticker, status: :ok, detail: %{raw: raw}} ->
        write_json!(Path.join(public_dir, "ticker_btc_jpy.json"), raw)

      %{name: :executions, status: :ok, detail: %{raw: raw}} ->
        write_json!(Path.join(public_dir, "executions_btc_jpy.json"), anonymize_executions(raw))

      %{name: :markets, status: :ok, detail: %{raw: raw}} ->
        write_json!(Path.join(public_dir, "markets.json"), raw)

      _ ->
        :ok
    end)

    manifest = %{
      "source" => "https://api.bitflyer.com public GET",
      "captured_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "product_code" => product_code,
      "anonymized" => ["buy_child_order_acceptance_id", "sell_child_order_acceptance_id"],
      "files" => [
        "public/ticker_btc_jpy.json",
        "public/executions_btc_jpy.json",
        "public/markets.json"
      ]
    }

    write_json!(Path.join(dir, "manifest.json"), manifest)
    :ok
  end

  defp anonymize_executions(rows) when is_list(rows) do
    Enum.map(rows, fn
      %{} = row ->
        row
        |> stringify_keys()
        |> Map.put("buy_child_order_acceptance_id", "JRF-REDACTED-BUY")
        |> Map.put("sell_child_order_acceptance_id", "JRF-REDACTED-SELL")

      other ->
        other
    end)
  end

  defp anonymize_executions(other), do: other

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp read_json(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bin) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_json!(path, term) do
    File.write!(path, Jason.encode!(term, pretty: true) <> "\n")
  end

  defp require_string(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp same_product(got, expected) when got == expected, do: :ok
  defp same_product(got, expected), do: {:error, {:product_mismatch, got, expected}}

  defp require_positive(map, key) do
    require_positive_value(Map.get(map, key) || Map.get(map, String.to_atom(key)))
  end

  defp require_positive_value(raw) do
    case Decode.to_decimal(raw) do
      {:ok, decimal} ->
        if Decimal.positive?(decimal), do: {:ok, decimal}, else: {:error, :non_positive}

      :error ->
        {:error, :invalid_number}
    end
  end

  defp require_timestamp(map, key) do
    require_timestamp_value(Map.get(map, key) || Map.get(map, String.to_atom(key)))
  end

  defp require_timestamp_value(value) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}T/, value) do
      :ok
    else
      {:error, :invalid_datetime}
    end
  end

  defp require_timestamp_value(_), do: {:error, :invalid_datetime}

  defp require_execution_id(id) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp require_execution_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp require_execution_id(_), do: {:error, :missing_identifier}

  defp require_side(raw) do
    case String.downcase(to_string(raw || "")) do
      "buy" -> {:ok, :buy}
      "sell" -> {:ok, :sell}
      _ -> {:error, :unknown_side}
    end
  end

  defp check(name, status, reason, detail) do
    %{name: name, status: status, reason: reason, detail: detail}
  end

  defp failed?(%{public: public, private: :skipped}) do
    Enum.any?(public, &(&1.status == :error))
  end

  defp failed?(%{public: public, private: private}) when is_list(private) do
    Enum.any?(public ++ private, &(&1.status == :error))
  end
end
