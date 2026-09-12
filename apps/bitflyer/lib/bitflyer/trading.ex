defmodule Bitflyer.Trading do
  @moduledoc """
  取引永続状態の Domain。

  注文・建玉・約定明細・残高スナップショット・当日 equity ピーク・
  baseline import 監査・戦略パラメータ適用履歴・リスク状態の正本。
  板・Ticker・判定ループはここを呼ばない（Architecture: Ash は永続のみ）。
  """
  use Ash.Domain,
    otp_app: :bitflyer

  resources do
    resource Bitflyer.Trading.Order
    resource Bitflyer.Trading.Position
    resource Bitflyer.Trading.Fill
    resource Bitflyer.Trading.BalanceSnapshot
    resource Bitflyer.Trading.BaselineImport
    resource Bitflyer.Trading.StrategyParameterRevision
    resource Bitflyer.Trading.RiskState
    resource Bitflyer.Trading.DailyEquityPeak
  end
end
