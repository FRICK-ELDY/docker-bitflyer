defmodule Bitflyer.TestSupport.DailyLossHelper do
  @moduledoc false

  alias Bitflyer.Risk.DailyLoss

  @doc """
  共有 DailyLoss ETS を synced・損失 0 に戻す（テスト間の汚染防止）。
  """
  def reset_daily_loss do
    DailyLoss.reset()
  end

  @doc """
  DailyLoss プロセス再起動相当（Fill + 永続 HWM から読み直す）。
  """
  def reinit_daily_loss(opts \\ []) do
    DailyLoss.reinit(opts)
  end
end
