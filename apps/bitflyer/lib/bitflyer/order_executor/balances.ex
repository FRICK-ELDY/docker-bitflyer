defmodule Bitflyer.OrderExecutor.Balances do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{BalanceSnapshot, Order, Product}

  # pg_advisory_xact_lock(int, int) 用の名前空間（残高 append 専用）
  @balance_lock_namespace 1

  @doc """
  擬似約定を残高スナップショットへ反映する（paper 用）。

  最新行を読み、デルタ適用した**新しい**行を create する（append-only）。
  `(trade_mode, currency)` ごとに `pg_advisory_xact_lock` で直列化し、
  同時約定による Lost Update を防ぐ（先端行の `FOR UPDATE` だけでは
  新 tip 挿入後も古い額から append され得る／初回行なし時も競合する）。
  複数通貨は currency 昇順でロックし、buy/sell 同時でもデッドロックしない。

  **呼び出し側は同一 DB トランザクション内で呼ぶこと**（xact ロックは
  コミット／ロールバックで解放される）。

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
      # ロック取得順を通貨コードで固定し、buy/sell 同時のデッドロックを防ぐ
      |> Enum.sort_by(fn {currency, _delta} -> currency end)

    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.reduce_while(deltas, {:ok, []}, fn {currency, delta}, {:ok, acc} ->
      case append_snapshot(trade_mode, currency, delta, captured_at) do
        {:ok, notifications} -> {:cont, {:ok, acc ++ notifications}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp append_snapshot(trade_mode, currency, delta, captured_at) do
    with :ok <- acquire_balance_lock(trade_mode, currency),
         {:ok, previous} <- latest_amount(trade_mode, currency) do
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

  defp acquire_balance_lock(trade_mode, currency) do
    key = :erlang.phash2({trade_mode, currency}, 2_147_483_647)

    case Bitflyer.Repo.query("SELECT pg_advisory_xact_lock($1, $2)", [
           @balance_lock_namespace,
           key
         ]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, :persist_failed, %{error: error, currency: currency}}
    end
  end

  defp latest_amount(trade_mode, currency) do
    case BalanceSnapshot
         |> Ash.Query.filter(trade_mode == ^trade_mode and currency == ^currency)
         |> Ash.Query.sort(captured_at: :desc, id: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one() do
      {:ok, nil} -> {:ok, Decimal.new(0)}
      {:ok, %BalanceSnapshot{amount: amount}} -> {:ok, amount}
      {:error, error} -> {:error, :persist_failed, %{error: error, currency: currency}}
    end
  end
end
