defmodule Bitflyer.Exchange.Client do
  @moduledoc """
  取引所スナップショット取得の契約。

  live 突合はこの behaviour 経由のみ。未実装クライアントは
  `Bitflyer.Exchange.Unavailable` を使い、fail-closed で Ready にしない。
  """

  @type position :: %{
          product_code: String.t(),
          side: :buy | :sell,
          size: Decimal.t(),
          average_price: Decimal.t()
        }

  @type balance :: %{
          currency: String.t(),
          amount: Decimal.t(),
          available: Decimal.t()
        }

  @type open_order :: %{
          exchange_order_id: String.t(),
          product_code: String.t(),
          side: :buy | :sell,
          size: Decimal.t(),
          filled_size: Decimal.t()
        }

  @type snapshot :: %{
          positions: [position()],
          balances: [balance()],
          open_orders: [open_order()]
        }

  @callback fetch_reconcile_snapshot() :: {:ok, snapshot()} | {:error, term()}
end
