defmodule Bitflyer.TestSupport.LiveExchangeHarness do
  @moduledoc false

  # P0 #2 用の擬似取引所。Agent に注文・約定・残高を持ち、
  # テストプロセスと Reconciler の両方から同じ正本を読む。

  @behaviour Bitflyer.Exchange.Client
  use Bitflyer.TestSupport.ExchangeClientStubs

  @jpy Decimal.new("1000000")
  @btc Decimal.new("0.5")
  @default_ltp Decimal.new("5000000")

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(_opts \\ []) do
    # コールバックは Agent 名を __MODULE__ に固定している。
    # :name を受けてずらすと fetch/place が別プロセスを見て壊れる。
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  @impl true
  def fetch_reconcile_snapshot do
    Agent.get(__MODULE__, fn state ->
      {:ok,
       %{
         positions: [],
         balances: state.balances,
         open_orders: open_orders(state.orders)
       }}
    end)
  end

  @impl true
  def place_order(request) when is_map(request) do
    exchange_order_id = "ex-" <> request.internal_order_id
    price = request.price || @default_ltp

    Agent.update(__MODULE__, fn state ->
      order = %{
        exchange_order_id: exchange_order_id,
        product_code: request.product_code,
        side: request.side,
        size: request.size,
        filled_size: Decimal.new(0),
        average_price: nil,
        status: :active,
        price: price
      }

      state
      |> put_order(order)
      |> hold_available(order)
    end)

    {:ok, %{exchange_order_id: exchange_order_id}}
  end

  @impl true
  def fetch_order(%{exchange_order_id: id}) do
    case Agent.get(__MODULE__, &Map.get(&1.orders, id)) do
      nil -> {:error, :order_not_found}
      info -> {:ok, Map.drop(info, [:price])}
    end
  end

  @impl true
  def fetch_executions(%{exchange_order_id: id}) do
    {:ok, Agent.get(__MODULE__, &Map.get(&1.executions, id, []))}
  end

  def fetch_executions(_request), do: {:ok, []}

  @impl true
  def list_child_orders(_request), do: {:ok, []}

  @spec apply_fill(String.t(), map()) :: :ok | {:error, :unknown_order}
  def apply_fill(exchange_order_id, attrs) when is_binary(exchange_order_id) and is_map(attrs) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.orders, exchange_order_id) do
        :error ->
          {{:error, :unknown_order}, state}

        {:ok, order} ->
          exec = execution(order, attrs)
          execs = Map.get(state.executions, exchange_order_id, []) ++ [exec]
          updated = refresh_order(order, execs)

          next =
            state
            |> put_order(updated)
            |> Map.update!(:executions, &Map.put(&1, exchange_order_id, execs))
            |> apply_execution_balances(order, exec)

          {:ok, next}
      end
    end)
  end

  @spec credit(String.t(), Decimal.t()) :: :ok
  def credit(currency, %Decimal{} = delta) when is_binary(currency) do
    Agent.update(__MODULE__, fn state ->
      %{state | balances: adjust_balance(state.balances, currency, delta, delta)}
    end)
  end

  @spec balances() :: [map()]
  def balances do
    Agent.get(__MODULE__, & &1.balances)
  end

  defp initial_state do
    %{
      orders: %{},
      executions: %{},
      balances: [
        %{currency: "JPY", amount: @jpy, available: @jpy},
        %{currency: "BTC", amount: @btc, available: @btc}
      ]
    }
  end

  defp put_order(state, order) do
    %{state | orders: Map.put(state.orders, order.exchange_order_id, order)}
  end

  defp hold_available(state, %{side: :buy, size: size, price: price, product_code: code}) do
    quote = Decimal.mult(size, price)
    currency = Bitflyer.Trading.Product.quote_currency(code)

    %{
      state
      | balances: adjust_balance(state.balances, currency, Decimal.new(0), Decimal.negate(quote))
    }
  end

  defp hold_available(state, %{side: :sell, size: size, product_code: code}) do
    currency = Bitflyer.Trading.Product.base_currency(code)

    %{
      state
      | balances: adjust_balance(state.balances, currency, Decimal.new(0), Decimal.negate(size))
    }
  end

  defp hold_available(state, _order), do: state

  defp execution(order, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      id: Map.fetch!(attrs, :id),
      exchange_order_id: order.exchange_order_id,
      product_code: order.product_code,
      side: order.side,
      price: Map.fetch!(attrs, :price),
      size: Map.fetch!(attrs, :size),
      executed_at: Map.get(attrs, :executed_at, now)
    }
  end

  defp refresh_order(order, execs) do
    filled =
      Enum.reduce(execs, Decimal.new(0), fn exec, acc -> Decimal.add(acc, exec.size) end)

    notional =
      Enum.reduce(execs, Decimal.new(0), fn exec, acc ->
        Decimal.add(acc, Decimal.mult(exec.size, exec.price))
      end)

    average =
      if Decimal.compare(filled, 0) == :gt do
        Decimal.div(notional, filled)
      end

    status =
      if Decimal.compare(filled, order.size) != :lt do
        :completed
      else
        :active
      end

    %{order | filled_size: filled, average_price: average, status: status}
  end

  # 拘束は place 時に available から引く。約定では amount だけ動かし、
  # 他注文の残拘束を available=amount で消さない。
  defp apply_execution_balances(state, %{side: :buy} = order, exec) do
    quote = Decimal.mult(exec.size, exec.price)
    quote_ccy = Bitflyer.Trading.Product.quote_currency(order.product_code)
    base = Bitflyer.Trading.Product.base_currency(order.product_code)

    balances =
      state.balances
      |> adjust_balance(quote_ccy, Decimal.negate(quote), Decimal.new(0))
      |> adjust_balance(base, exec.size, exec.size)

    %{state | balances: balances}
  end

  defp apply_execution_balances(state, %{side: :sell} = order, exec) do
    quote = Decimal.mult(exec.size, exec.price)
    quote_ccy = Bitflyer.Trading.Product.quote_currency(order.product_code)
    base = Bitflyer.Trading.Product.base_currency(order.product_code)

    balances =
      state.balances
      |> adjust_balance(quote_ccy, quote, quote)
      |> adjust_balance(base, Decimal.negate(exec.size), Decimal.new(0))

    %{state | balances: balances}
  end

  defp adjust_balance(balances, currency, amount_delta, available_delta) do
    {updated, found?} =
      Enum.map_reduce(balances, false, fn
        %{currency: ^currency} = row, _found? ->
          {%{
             row
             | amount: Decimal.add(row.amount, amount_delta),
               available: Decimal.add(row.available, available_delta)
           }, true}

        row, found? ->
          {row, found?}
      end)

    if found? do
      updated
    else
      raise ArgumentError, "LiveExchangeHarness has no #{currency} balance row"
    end
  end

  defp open_orders(orders) do
    orders
    |> Map.values()
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(&Map.take(&1, [:exchange_order_id, :product_code, :side, :size, :filled_size]))
  end
end
