defmodule Bitflyer.OrderExecutor.Balances do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{BalanceSnapshot, Order, Product}

  @doc """
  擬似約定を残高スナップショットへ反映する（paper 用）。

  最新行を読み、デルタ適用した**新しい**行を create する（append-only）。
  トランザクション内では `return_notifications?: true` で通知を返し、
  呼び出し側がコミット後に notify する。
  """
  @spec apply_fill(Order.t(), Decimal.t()) :: {:ok, list()} | {:error, atom(), map()}
  def apply_fill(%Order{} = order, %Decimal{} = fill_price) do
    trade_mode = order.trade_mode
    base = Product.base_currency(order.product_code)
    quote = Product.quote_currency(order.product_code)
    size = order.size
    notional = Decimal.mult(size, fill_price)

    deltas =
      case order.side do
        :buy -> [{quote, Decimal.negate(notional)}, {base, size}]
        :sell -> [{base, Decimal.negate(size)}, {quote, notional}]
      end

    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.reduce_while(deltas, {:ok, []}, fn {currency, delta}, {:ok, acc} ->
      case append_snapshot(trade_mode, currency, delta, captured_at) do
        {:ok, notifications} -> {:cont, {:ok, acc ++ notifications}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp append_snapshot(trade_mode, currency, delta, captured_at) do
    with {:ok, previous} <- latest_amount(trade_mode, currency) do
      amount = Decimal.add(previous, delta)

      case BalanceSnapshot
           |> Ash.Changeset.for_create(:create, %{
             currency: currency,
             amount: amount,
             available: amount,
             captured_at: captured_at,
             trade_mode: trade_mode
           })
           |> Ash.create(return_notifications?: true) do
        {:ok, _row, notifications} -> {:ok, notifications}
        {:error, error} -> {:error, :persist_failed, %{error: error, currency: currency}}
      end
    end
  end

  defp latest_amount(trade_mode, currency) do
    case BalanceSnapshot
         |> Ash.Query.filter(trade_mode == ^trade_mode and currency == ^currency)
         |> Ash.Query.sort(captured_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one() do
      {:ok, nil} -> {:ok, Decimal.new(0)}
      {:ok, %BalanceSnapshot{amount: amount}} -> {:ok, amount}
      {:error, error} -> {:error, :persist_failed, %{error: error, currency: currency}}
    end
  end
end
