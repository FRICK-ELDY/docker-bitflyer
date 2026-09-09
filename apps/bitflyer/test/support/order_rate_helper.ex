defmodule Bitflyer.TestSupport.OrderRateHelper do
  @moduledoc false

  alias Bitflyer.Risk.OrderRate

  @doc """
  共有 OrderRate ETS を空にする（テスト間の汚染防止）。
  """
  def reset_order_rate do
    OrderRate.clear()
  end
end
