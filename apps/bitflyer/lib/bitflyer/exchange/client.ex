defmodule Bitflyer.Exchange.Client do
  @moduledoc """
  取引所アダプタの契約。

  - 突合: `fetch_reconcile_snapshot/0`
  - 発注: `place_order/1`（live の order-executor 出口のみが呼ぶ）
  - 取消: `cancel_order/1`
  - 照会: `fetch_order/1`
  - 一覧: `list_child_orders/1`（submission_unknown 回収用。時刻・side・size 照合）
  - 約定: `fetch_executions/1`（live 約定反映用）
  - 権限: `get_permissions/0`（live 起動時の出金禁止検査）

  未実装クライアントは `Bitflyer.Exchange.Unavailable`（fail-closed）。
  署名付き REST は `Bitflyer.Exchange.Rest`。

  ## `place_order/1` のエラー契約

  呼び出し側（`OrderExecutor.Live`）が結果を分類する。

  - **確定拒否**（注文が取引所に無いと分かる）→ Order `rejected`  
    例: `:exchange_unavailable`（未送信）、`:rejected_by_exchange`、`:insufficient_funds`、
    `:invalid_order`、`:invalid_request`、`:rate_limited`  
    ※ `:auth_failed`（401/403）も確定拒否だが **即サーキット**（鍵違いの連発防止）  
    ※ その他の確定拒否は窓内 N 回で `:consecutive_exchange_errors` サーキット
  - **提出不明**（受注したか分からない）→ Order `submission_unknown` + Readiness/Risk halt、再送しない  
    例: `:timeout`、`:disconnected`、`:closed`、および上記以外の予期しない理由
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

  @type cancel_order_request :: %{
          required(:product_code) => String.t(),
          required(:exchange_order_id) => String.t()
        }

  @type fetch_order_request :: %{
          required(:product_code) => String.t(),
          required(:exchange_order_id) => String.t()
        }

  @type order_status :: :active | :completed | :canceled | :expired | :rejected

  @type order_info :: %{
          exchange_order_id: String.t(),
          product_code: String.t(),
          side: :buy | :sell,
          size: Decimal.t(),
          filled_size: Decimal.t(),
          average_price: Decimal.t() | nil,
          status: order_status()
        }

  @type list_child_orders_request :: %{
          required(:product_code) => String.t(),
          optional(:count) => pos_integer(),
          optional(:child_order_state) => String.t()
        }

  @type child_order :: %{
          exchange_order_id: String.t(),
          product_code: String.t(),
          side: :buy | :sell,
          size: Decimal.t(),
          filled_size: Decimal.t(),
          average_price: Decimal.t() | nil,
          status: order_status(),
          price: Decimal.t() | nil,
          order_type: :limit | :market | nil,
          ordered_at: DateTime.t()
        }

  @type fetch_executions_request :: %{
          required(:product_code) => String.t(),
          optional(:exchange_order_id) => String.t(),
          optional(:count) => pos_integer()
        }

  @type execution :: %{
          id: String.t(),
          exchange_order_id: String.t(),
          product_code: String.t(),
          side: :buy | :sell,
          price: Decimal.t(),
          size: Decimal.t(),
          executed_at: DateTime.t() | nil
        }

  @callback fetch_reconcile_snapshot() :: {:ok, snapshot()} | {:error, term()}
  @callback place_order(place_order_request()) :: {:ok, place_order_result()} | {:error, term()}
  @callback cancel_order(cancel_order_request()) :: :ok | {:error, term()}
  @callback fetch_order(fetch_order_request()) :: {:ok, order_info()} | {:error, term()}
  @callback list_child_orders(list_child_orders_request()) ::
              {:ok, [child_order()]} | {:error, term()}
  @callback fetch_executions(fetch_executions_request()) ::
              {:ok, [execution()]} | {:error, term()}
  @callback get_permissions() :: {:ok, [String.t()]} | {:error, term()}
end
