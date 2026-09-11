defmodule Bitflyer.TestSupport.ExchangeClientStubs do
  @moduledoc false

  # Behaviour 追加 callback の共通スタブ（テスト用クライアント向け）
  # fetch_order は ACTIVE・未約定を返し、認可前/発注後の LiveFills が黙って成功するようにする。
  defmacro __using__(_opts) do
    quote do
      @impl true
      def cancel_order(_request), do: {:error, :not_used_in_test}

      @impl true
      def fetch_order(%{exchange_order_id: id}) do
        {:ok,
         %{
           exchange_order_id: id,
           product_code: "FX_BTC_JPY",
           side: :buy,
           size: Decimal.new("1"),
           filled_size: Decimal.new("0"),
           average_price: nil,
           status: :active
         }}
      end

      @impl true
      def fetch_executions(%{exchange_order_id: id}) do
        {:ok, Bitflyer.TestSupport.FillExecutions.from_process(id)}
      end

      @impl true
      def list_child_orders(_request), do: {:ok, []}

      @impl true
      def get_permissions do
        {:ok,
         [
           "/v1/me/getpermissions",
           "/v1/me/getbalance",
           "/v1/me/getchildorders",
           "/v1/me/getexecutions",
           "/v1/me/getpositions",
           "/v1/me/sendchildorder",
           "/v1/me/cancelchildorder"
         ]}
      end

      defoverridable cancel_order: 1,
                     fetch_order: 1,
                     fetch_executions: 1,
                     list_child_orders: 1,
                     get_permissions: 0
    end
  end
end
