defmodule Bitflyer.OperationalStatus do
  @moduledoc """
  運用画面向けの発注可否スナップショット。

  「今トレードしてよいか」の判定正本。UI は表示のみ行い、ここで
  readiness / live 解禁 / 市場データ鮮度 / Feed 接続を合成する。

  MarketData 有効時の Feed＋鮮度は `market_feed_gate/2` が正本で、
  `Health` の `/health/ready` も同じ判定を使う（切断直後に ALLOWED と ready が矛盾しない）。

  ## 残差（P1 #9 完了条件外）

  実発注の `Risk.authorize/2` は Cache 鮮度のみを見る。Feed 切断直後〜stale までの
  短時間は Status が STOPPED・`/health/ready` が 503 でも authorize が通りうる。
  発注経路への Feed 接続ゲートは別途（Risk / TradeMode）の課題。
  """

  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.Cache
  alias Bitflyer.MarketData.Feed
  alias Bitflyer.Readiness
  alias Bitflyer.TradeMode

  @type reason :: atom()

  @type market_entry :: %{
          product_code: String.t(),
          key: {:ticker, String.t()},
          fresh?: boolean(),
          age_ms: non_neg_integer() | :miss
        }

  @type market :: %{
          enabled?: boolean(),
          max_age_ms: pos_integer(),
          all_fresh?: boolean(),
          entries: [market_entry()]
        }

  @type feed :: %{
          enabled?: boolean(),
          available?: boolean(),
          connected?: boolean(),
          subscribe_count: non_neg_integer(),
          reconnect_attempt: non_neg_integer()
        }

  @type t :: %{
          trade_mode: TradeMode.t(),
          readiness: Readiness.state(),
          readiness_label: String.t(),
          halt_reason: reason() | nil,
          orders_allowed?: boolean(),
          orders_reason: reason() | nil,
          market_data: market(),
          feed: feed()
        }

  @doc """
  現時点の運用スナップショット。

  発注可否は `orders_gate/5` 経由（UI・Health と同一分類）。
  テスト注入は `Application.put_env(:bitflyer, :operational_status_snapshot_opts, opts)` も可。
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    opts = Keyword.merge(snapshot_env_opts(), opts)
    readiness = Keyword.get_lazy(opts, :readiness, &Readiness.get/0)
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &TradeMode.current/0)
    live_confirmed? = Keyword.get_lazy(opts, :live_confirmed?, &TradeMode.live_confirmed?/0)
    market_data = Keyword.get_lazy(opts, :market_data, fn -> market_data_snapshot(opts) end)
    feed = Keyword.get_lazy(opts, :feed, fn -> feed_snapshot(opts) end)

    {allowed?, reason} =
      case orders_gate(readiness, trade_mode, market_data, live_confirmed?, feed) do
        :ok -> {true, nil}
        {:halted, gate_reason} -> {false, gate_reason}
      end

    %{
      trade_mode: trade_mode,
      readiness: readiness,
      readiness_label: Readiness.format(readiness),
      halt_reason: halt_reason(readiness),
      orders_allowed?: allowed?,
      orders_reason: reason,
      market_data: market_data,
      feed: feed
    }
  end

  @doc """
  発注ゲート。`:ok` または `{:halted, reason}`。

  `snapshot/1` の発注可否はこの関数の結果を写す。プログラムからゲートだけ欲しいときもここを使う。
  """
  @spec orders_gate(Readiness.state(), TradeMode.t(), market(), boolean(), feed()) ::
          :ok | {:halted, reason()}
  def orders_gate(readiness, trade_mode, market_data, live_confirmed?, feed) do
    case classify(readiness, trade_mode, market_data, live_confirmed?, feed) do
      {true, nil} -> :ok
      {false, reason} -> {:halted, reason}
    end
  end

  @doc """
  MarketData 有効時の Feed 接続＋鮮度ゲート。

  `/health/ready` と Status orders gate が共有する。無効時は `:ok`（スキップ）。
  """
  @spec market_feed_gate(market(), feed()) :: :ok | {:halted, reason()}
  def market_feed_gate(market_data, feed) when is_map(market_data) and is_map(feed) do
    cond do
      not market_data.enabled? ->
        :ok

      not feed_connected?(feed) ->
        {:halted, feed_reason(feed)}

      not market_data.all_fresh? ->
        {:halted, :stale_market_data}

      true ->
        :ok
    end
  end

  @doc """
  設定銘柄の鮮度スナップショット。
  """
  @spec market_data_snapshot(keyword()) :: market()
  def market_data_snapshot(opts \\ []) do
    max_age_ms =
      Keyword.get_lazy(opts, :max_age_ms, fn ->
        Application.get_env(:bitflyer, Bitflyer.Risk, [])
        |> Keyword.get(:market_data_max_age_ms, Cache.default_max_age_ms())
      end)

    product_codes = Keyword.get_lazy(opts, :product_codes, &MarketData.product_codes/0)
    enabled? = Keyword.get_lazy(opts, :enabled?, &MarketData.enabled?/0)
    now = Keyword.get_lazy(opts, :now, &Cache.monotonic_ms/0)
    server = Keyword.get(opts, :server, Cache)

    entries =
      Enum.map(product_codes, fn product_code ->
        key = MarketData.ticker_key(product_code)

        case Cache.get(key, server) do
          {:ok, _value, received_at} ->
            %{
              product_code: product_code,
              key: key,
              fresh?: Cache.entry_fresh?(received_at, max_age_ms, now),
              age_ms: max(now - received_at, 0)
            }

          :miss ->
            %{
              product_code: product_code,
              key: key,
              fresh?: false,
              age_ms: :miss
            }
        end
      end)

    %{
      enabled?: enabled?,
      max_age_ms: max_age_ms,
      all_fresh?: entries != [] and Enum.all?(entries, & &1.fresh?),
      entries: entries
    }
  end

  @doc """
  Feed 接続状態のスナップショット。
  """
  @spec feed_snapshot(keyword()) :: feed()
  def feed_snapshot(opts \\ []) do
    enabled? = Keyword.get_lazy(opts, :feed_enabled?, &MarketData.enabled?/0)

    status =
      if enabled? do
        Keyword.get_lazy(opts, :feed_status, &safe_feed_status/0)
      else
        :unavailable
      end

    normalize_feed(status, enabled?)
  end

  defp classify(readiness, trade_mode, market_data, live_confirmed?, feed) do
    case readiness do
      {:halted, reason} ->
        {false, reason}

      :ready ->
        cond do
          TradeMode.live?(trade_mode) and not live_confirmed? ->
            {false, :live_confirm_missing}

          true ->
            case market_feed_gate(market_data, feed) do
              :ok -> {true, nil}
              {:halted, reason} -> {false, reason}
            end
        end

      _ ->
        {false, :not_ready}
    end
  end

  defp feed_connected?(%{available?: true, connected?: true}), do: true
  defp feed_connected?(_), do: false

  defp feed_reason(%{available?: false}), do: :feed_unavailable
  defp feed_reason(_), do: :feed_disconnected

  defp halt_reason({:halted, reason}) when is_atom(reason), do: reason
  defp halt_reason(_), do: nil

  defp safe_feed_status do
    try do
      Feed.status()
    catch
      :exit, _ -> :unavailable
    end
  end

  defp normalize_feed(:unavailable, enabled?) do
    %{
      enabled?: enabled?,
      available?: false,
      connected?: false,
      subscribe_count: 0,
      reconnect_attempt: 0
    }
  end

  defp normalize_feed(status, enabled?) when is_map(status) do
    %{
      enabled?: enabled?,
      available?: true,
      connected?: Map.get(status, :connected?, false) == true,
      subscribe_count: non_neg_int(Map.get(status, :subscribe_count, 0)),
      reconnect_attempt: non_neg_int(Map.get(status, :reconnect_attempt, 0))
    }
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp snapshot_env_opts do
    case Application.get_env(:bitflyer, :operational_status_snapshot_opts, []) do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end
end
