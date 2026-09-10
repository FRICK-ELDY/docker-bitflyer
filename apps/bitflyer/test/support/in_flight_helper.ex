defmodule Bitflyer.TestSupport.InFlightHelper do
  @moduledoc false

  alias Bitflyer.OrderExecutor.InFlight

  @doc """
  InFlight を空にして受付を再開する（prep_stop 後の汚染防止）。
  """
  def reset_inflight do
    InFlight.clear()
  end
end
