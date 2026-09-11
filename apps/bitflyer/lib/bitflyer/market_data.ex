defmodule Bitflyer.MarketData do
  @moduledoc """
  市場データ購読の設定と公開ヘルパ。

  WebSocket で ticker を受け、切断時は再購読と REST 穴埋めで Cache を更新する。
  古いデータでの発注拒否は `Cache.fresh?/2` + `Risk.authorize/2` に任せる。
  """

  @doc """
  Application env（`Bitflyer.MarketData`）を読む。
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:bitflyer, __MODULE__, [])
  end

  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true

  @spec product_codes() :: [String.t()]
  def product_codes do
    case Keyword.get(config(), :product_codes, ["BTC_JPY"]) do
      codes when is_list(codes) -> Enum.map(codes, &to_string/1)
      code when is_binary(code) -> [code]
      _ -> ["BTC_JPY"]
    end
  end

  @spec ticker_channel(String.t()) :: String.t()
  def ticker_channel(product_code) when is_binary(product_code) do
    "lightning_ticker_#{product_code}"
  end

  @spec ticker_key(String.t()) :: {:ticker, String.t()}
  def ticker_key(product_code) when is_binary(product_code), do: {:ticker, product_code}

  @doc """
  gap-fill 用 Task.Supervisor 名。
  """
  def task_supervisor, do: Bitflyer.MarketData.TaskSupervisor
end
