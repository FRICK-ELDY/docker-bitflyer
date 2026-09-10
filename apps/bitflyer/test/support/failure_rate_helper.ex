defmodule Bitflyer.TestSupport.FailureRateHelper do
  @moduledoc false

  alias Bitflyer.Risk.FailureRate

  @doc """
  共有 FailureRate ETS を空にする（テスト間の汚染防止）。
  """
  def reset_failure_rate do
    FailureRate.clear()
  end
end
