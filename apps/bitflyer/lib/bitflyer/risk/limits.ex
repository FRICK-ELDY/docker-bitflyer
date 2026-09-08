defmodule Bitflyer.Risk.Limits do
  @moduledoc """
  risk-manager の上限設定。Application env または呼び出し側の上書きを正規化する。
  """

  @default_max_order_size "1"
  @default_max_position_size "5"

  @type t :: %{
          max_order_size: Decimal.t(),
          max_position_size: Decimal.t(),
          market_data_max_age_ms: non_neg_integer()
        }

  @doc """
  Application env から現在の上限マップを読む。
  """
  @spec current() :: t()
  def current do
    :bitflyer
    |> Application.get_env(Bitflyer.Risk, [])
    |> normalize()
  end

  @doc """
  任意のマップまたはキーワードリストを `Limits.t()` に正規化する。
  """
  @spec normalize(map() | keyword()) :: t()
  def normalize(limits) when is_list(limits), do: normalize(Map.new(limits))

  def normalize(limits) when is_map(limits) do
    %{
      max_order_size: decimal(Map.get(limits, :max_order_size, @default_max_order_size)),
      max_position_size: decimal(Map.get(limits, :max_position_size, @default_max_position_size)),
      market_data_max_age_ms:
        Map.get(limits, :market_data_max_age_ms) ||
          Bitflyer.MarketData.Cache.default_max_age_ms()
    }
  end

  defp decimal(%Decimal{} = d), do: d
  defp decimal(raw) when is_binary(raw), do: Decimal.new(raw)
  defp decimal(raw) when is_integer(raw), do: Decimal.new(raw)
  defp decimal(raw) when is_float(raw), do: Decimal.from_float(raw)
end
