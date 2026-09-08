defmodule Bitflyer.TestSupport.ReadinessHelper do
  @moduledoc false

  import ExUnit.Assertions

  alias Bitflyer.Readiness

  @doc """
  共有 Readiness を `:not_ready` に戻す（テスト間の汚染防止）。
  """
  def reset_readiness do
    case Readiness.get() do
      {:halted, _} ->
        assert Readiness.clear_halt() == :ok

      :ready ->
        assert Readiness.mark_not_ready() == :ok

      :not_ready ->
        :ok
    end
  end
end
