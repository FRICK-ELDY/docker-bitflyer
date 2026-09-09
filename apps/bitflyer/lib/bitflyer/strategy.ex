defmodule Bitflyer.Strategy do
  @moduledoc """
  戦略の契約。

  市場スナップショットから内部発注意図（command map）を返す。
  取引所 API・OrderExecutor は呼ばない（Runner が `System.submit_order/2` へ渡す）。
  """

  @type market :: %{
          required(:product_code) => String.t(),
          required(:market_key) => {:ticker, String.t()},
          required(:ltp) => Decimal.t(),
          optional(:received_at) => integer()
        }

  @type position :: map()
  @type params :: map()
  @type command :: map()

  @callback evaluate(market(), [position()], params()) :: [command()]

  @doc """
  Application env（`Bitflyer.Strategy`）。
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:bitflyer, __MODULE__, [])

  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true

  @spec module() :: module()
  def module, do: Keyword.get(config(), :module, Bitflyer.Strategy.FixedOnce)

  @spec params() :: params()
  def params do
    config()
    |> Keyword.get(:params, [])
    |> Map.new()
  end
end
