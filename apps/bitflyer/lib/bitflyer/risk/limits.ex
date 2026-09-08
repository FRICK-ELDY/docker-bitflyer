defmodule Bitflyer.Risk.Limits do
  @moduledoc """
  risk-manager の上限設定。Application env から読む。
  """

  @type t :: %{
          max_order_size: Decimal.t(),
          max_position_size: Decimal.t(),
          market_data_max_age_ms: non_neg_integer()
        }

  @doc """
  現在の上限マップ。
  """
  @spec current() :: t()
  def current do
    env = Application.get_env(:bitflyer, Bitflyer.Risk, [])

    %{
      max_order_size: decimal(Keyword.get(env, :max_order_size, "1")),
      max_position_size: decimal(Keyword.get(env, :max_position_size, "5")),
      market_data_max_age_ms:
        Keyword.get(
          env,
          :market_data_max_age_ms,
          Bitflyer.MarketData.Cache.default_max_age_ms()
        )
    }
  end

  defp decimal(%Decimal{} = d), do: d
  defp decimal(raw) when is_binary(raw), do: Decimal.new(raw)
  defp decimal(raw) when is_integer(raw), do: Decimal.new(raw)
  defp decimal(raw) when is_float(raw), do: Decimal.from_float(raw)
end
