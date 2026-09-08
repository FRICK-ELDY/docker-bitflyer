defmodule Bitflyer.Exchange.Client do
  @moduledoc """
  取引所アダプタの契約。

  - 突合: `fetch_reconcile_snapshot/0`
  - 発注: `place_order/1`（live の order-executor 出口のみが呼ぶ）

  未実装クライアントは `Bitflyer.Exchange.Unavailable`（fail-closed）。
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

  @type place_order_request :: %{
          required(:product_code) => String.t(),
          required(:side) => :buy | :sell,
          required(:size) => Decimal.t(),
          required(:order_type) => :limit | :market,
          required(:internal_order_id) => String.t(),
          optional(:price) => Decimal.t() | nil
        }

  @type place_order_result :: %{exchange_order_id: String.t()}

  @callback fetch_reconcile_snapshot() :: {:ok, snapshot()} | {:error, term()}
  @callback place_order(place_order_request()) :: {:ok, place_order_result()} | {:error, term()}
end
