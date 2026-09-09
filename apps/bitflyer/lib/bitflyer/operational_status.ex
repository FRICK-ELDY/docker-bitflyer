defmodule Bitflyer.OperationalStatus do
  @moduledoc """
  運用画面向けの発注可否スナップショット。

  「今トレードしてよいか」の判定正本。UI は表示のみ行い、ここで
  readiness / live 解禁 / 市場データ鮮度を合成する。
  """

  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.Cache
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

  @type t :: %{
          trade_mode: TradeMode.t(),
          readiness: Readiness.state(),
          readiness_label: String.t(),
          halt_reason: reason() | nil,
          orders_allowed?: boolean(),
          orders_reason: reason() | nil,
          market_data: market()
        }

  @doc """
  現時点の運用スナップショット。
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    readiness = Keyword.get_lazy(opts, :readiness, &Readiness.get/0)
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &TradeMode.current/0)
    live_confirmed? = Keyword.get_lazy(opts, :live_confirmed?, &TradeMode.live_confirmed?/0)
    market_data = Keyword.get_lazy(opts, :market_data, fn -> market_data_snapshot(opts) end)

    {allowed?, reason} = classify(readiness, trade_mode, market_data, live_confirmed?)

    %{
      trade_mode: trade_mode,
      readiness: readiness,
      readiness_label: Readiness.format(readiness),
      halt_reason: halt_reason(readiness),
      orders_allowed?: allowed?,
      orders_reason: reason,
      market_data: market_data
    }
  end

  @doc """
  発注ゲート。`:ok` または `{:halted, reason}`。
  """
  @spec orders_gate(Readiness.state(), TradeMode.t(), market(), boolean()) ::
          :ok | {:halted, reason()}
  def orders_gate(readiness, trade_mode, market_data, live_confirmed?) do
    case classify(readiness, trade_mode, market_data, live_confirmed?) do
      {true, nil} -> :ok
      {false, reason} -> {:halted, reason}
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

  defp classify(readiness, trade_mode, market_data, live_confirmed?) do
    case readiness do
      {:halted, reason} ->
        {false, reason}

      :ready ->
        cond do
          TradeMode.live?(trade_mode) and not live_confirmed? ->
            {false, :live_confirm_missing}

          not market_data.all_fresh? ->
            {false, :stale_market_data}

          true ->
            {true, nil}
        end

      _ ->
        {false, :not_ready}
    end
  end

  defp halt_reason({:halted, reason}) when is_atom(reason), do: reason
  defp halt_reason(_), do: nil
end
