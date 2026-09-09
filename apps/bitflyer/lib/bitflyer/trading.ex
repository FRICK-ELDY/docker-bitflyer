defmodule Bitflyer.Trading do
  @moduledoc """
  取引永続状態の Domain。

  注文・建玉・約定明細・残高スナップショット・リスク状態の正本。
  板・Ticker・判定ループはここを呼ばない（Architecture: Ash は永続のみ）。
  """
  use Ash.Domain,
    otp_app: :bitflyer

  resources do
    resource Bitflyer.Trading.Order
    resource Bitflyer.Trading.Position
    resource Bitflyer.Trading.Fill
    resource Bitflyer.Trading.BalanceSnapshot
    resource Bitflyer.Trading.RiskState
  end
end
