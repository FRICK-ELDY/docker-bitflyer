defmodule Bitflyer.Health do
  @moduledoc """
  稼働判定の集約。UI の監視エンドポイントと Compose が同じ結果を読む。

  プローブ方針（LiveView Socket が Endpoint で `/live` を使うため、liveness は
  `/health/live` とする）:

  - `live_snapshot` / `GET /health/live` — プロセス生存。常に 200。
    Compose の restart 判定用。WS 断や stale では落とさない（Feed が再接続する）。
  - `ready_snapshot` / `GET /health/ready` — 外形 readiness。
    DB 可 + `Readiness` が `:ready` +（MarketData 有効時は Feed 接続かつ全銘柄鮮度）。
    Feed／鮮度は `OperationalStatus.market_feed_gate/2` と同一（Status ALLOWED・
    `Risk.authorize` と矛盾しない。接続は `Feed.connection_snapshot/0`）。
    WS 断・stale・halt・DB 断は 503。外部監視はこちらを見る。
  - `snapshot` / `GET /health` — 従来互換。DB 断または halted で 503。
    起動中の `:not_ready` は 200（boot reconcile 完了前でも Compose が通しやすい）。

  公開 JSON（`to_json_map/1` 等）には DB エラー詳細を載せない。
  """

  alias Bitflyer.OperationalStatus
  alias Bitflyer.Readiness
  alias Bitflyer.TradeMode

  @type status :: :live | :ready | :not_ready | :halted | :unavailable

  @type t :: %{
          status: status(),
          healthy?: boolean(),
          db: boolean(),
          db_error: String.t() | nil,
          readiness: term(),
          trade_mode: TradeMode.t(),
          reason: atom() | nil,
          market_data: OperationalStatus.market() | nil,
          feed: OperationalStatus.feed() | nil
        }

  @doc """
  プロセス生存スナップショット（常に healthy）。
  """
  @spec live_snapshot(keyword()) :: t()
  def live_snapshot(opts \\ []) do
    trade_mode = Keyword.get(opts, :trade_mode, &TradeMode.current/0)

    %{
      status: :live,
      healthy?: true,
      db: true,
      db_error: nil,
      readiness: :live,
      trade_mode: trade_mode.(),
      reason: nil,
      market_data: nil,
      feed: nil
    }
  end

  @doc """
  外形 readiness スナップショット（stale / Feed を含む）。
  """
  @spec ready_snapshot(keyword()) :: t()
  def ready_snapshot(opts \\ []) do
    database = Keyword.get(opts, :database, &Bitflyer.System.check_database/0)
    readiness = Keyword.get(opts, :readiness, &Readiness.get/0)
    trade_mode = Keyword.get(opts, :trade_mode, &TradeMode.current/0)

    market_data =
      Keyword.get_lazy(opts, :market_data, fn -> OperationalStatus.market_data_snapshot(opts) end)

    feed = Keyword.get_lazy(opts, :feed, fn -> OperationalStatus.feed_snapshot(opts) end)

    build_ready(database.(), readiness.(), trade_mode.(), market_data, feed)
  end

  @doc """
  従来のヘルススナップショット（DB + readiness halt）。
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    database = Keyword.get(opts, :database, &Bitflyer.System.check_database/0)
    readiness = Keyword.get(opts, :readiness, &Readiness.get/0)
    trade_mode = Keyword.get(opts, :trade_mode, &TradeMode.current/0)

    build(database.(), readiness.(), trade_mode.())
  end

  @doc """
  DB 結果と readiness から従来ヘルスを組み立てる（単体テスト用）。
  """
  @spec build(term(), term(), TradeMode.t()) :: t()
  def build(db_result, readiness, trade_mode) do
    {db_ok?, db_error} = db_fields(db_result)
    {status, reason} = classify(db_ok?, readiness)

    %{
      status: status,
      healthy?: legacy_healthy?(status),
      db: db_ok?,
      db_error: db_error,
      readiness: readiness,
      trade_mode: trade_mode,
      reason: reason,
      market_data: nil,
      feed: nil
    }
  end

  @doc """
  外形 readiness を組み立てる（単体テスト用）。
  """
  @spec build_ready(
          term(),
          term(),
          TradeMode.t(),
          OperationalStatus.market(),
          OperationalStatus.feed()
        ) ::
          t()
  def build_ready(db_result, readiness, trade_mode, market_data, feed) do
    {db_ok?, db_error} = db_fields(db_result)
    {status, reason} = classify_ready(db_ok?, readiness, market_data, feed)

    %{
      status: status,
      healthy?: status == :ready,
      db: db_ok?,
      db_error: db_error,
      readiness: readiness,
      trade_mode: trade_mode,
      reason: reason,
      market_data: market_data,
      feed: feed
    }
  end

  @doc """
  公開用 JSON。DB エラー本文は含めない。
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%{} = health) do
    base = %{
      "status" => Atom.to_string(health.status),
      "db" => health.db,
      "trade_mode" => TradeMode.name(health.trade_mode),
      "readiness" => readiness_label(health),
      "reason" => reason_to_string(health.reason)
    }

    base
    |> maybe_put_feed(health.feed)
    |> maybe_put_market_data(health.market_data)
  end

  defp readiness_label(%{status: :live}), do: "live"
  defp readiness_label(%{readiness: readiness}), do: Readiness.format(readiness)

  defp maybe_put_feed(map, nil), do: map

  defp maybe_put_feed(map, feed) do
    Map.put(map, "feed", %{
      "enabled" => feed.enabled?,
      "available" => feed.available?,
      "connected" => feed.connected?,
      "subscribe_count" => feed.subscribe_count,
      "reconnect_attempt" => feed.reconnect_attempt
    })
  end

  defp maybe_put_market_data(map, nil), do: map

  defp maybe_put_market_data(map, market_data) do
    entries =
      Enum.map(market_data.entries, fn entry ->
        %{
          "product_code" => entry.product_code,
          "fresh" => entry.fresh?,
          "age_ms" => age_ms_json(entry.age_ms)
        }
      end)

    Map.put(map, "market_data", %{
      "enabled" => market_data.enabled?,
      "all_fresh" => market_data.all_fresh?,
      "entries" => entries
    })
  end

  defp age_ms_json(:miss), do: nil
  defp age_ms_json(age) when is_integer(age), do: age

  defp db_fields(db_result) do
    case db_result do
      :ok -> {true, nil}
      {:error, message} when is_binary(message) -> {false, message}
      {:error, message} -> {false, inspect(message)}
      other -> {false, "unexpected database result: #{inspect(other)}"}
    end
  end

  defp classify(false, _readiness), do: {:unavailable, :database_unavailable}

  defp classify(true, :ready), do: {:ready, nil}
  defp classify(true, :not_ready), do: {:not_ready, nil}
  defp classify(true, {:halted, reason}) when is_atom(reason), do: {:halted, reason}
  defp classify(true, {:halted, _reason}), do: {:halted, :invalid_halt_reason}
  defp classify(true, _other), do: {:unavailable, :unknown_readiness}

  defp classify_ready(false, _readiness, _market, _feed),
    do: {:unavailable, :database_unavailable}

  defp classify_ready(true, {:halted, reason}, _market, _feed) when is_atom(reason),
    do: {:halted, reason}

  defp classify_ready(true, {:halted, _reason}, _market, _feed),
    do: {:halted, :invalid_halt_reason}

  defp classify_ready(true, :not_ready, _market, _feed), do: {:not_ready, :not_ready}

  defp classify_ready(true, :ready, market_data, feed) do
    case OperationalStatus.market_feed_gate(market_data, feed) do
      :ok -> {:ready, nil}
      {:halted, reason} -> {:not_ready, reason}
    end
  end

  defp classify_ready(true, _other, _market, _feed), do: {:unavailable, :unknown_readiness}

  defp legacy_healthy?(:unavailable), do: false
  defp legacy_healthy?(:halted), do: false
  defp legacy_healthy?(:ready), do: true
  defp legacy_healthy?(:not_ready), do: true

  defp reason_to_string(nil), do: nil
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)
end
