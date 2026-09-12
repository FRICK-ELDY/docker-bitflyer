defmodule Bitflyer.Startup.LiveInventory do
  @moduledoc """
  live spot の在庫突合。

  取引所 `getbalance` の base **amount** と、内部の買い `Position.size` を
  通貨ごとに比べる。平均単価は取引所に無いので見ない
  （`Equity.unrealized` は内部 VWAP × LTP の推定）。

  売れるのは買い建玉 − 未約定売りまで（`Trading.SpotInventory`）。
  Position なしのベースライン通貨は売らない。売建玉が残っていたら
  `spot_short_position`（fill 同期が先でも検知する）。

  売り残を Position に足すと二重になる。**超過（claimed > amount + 絶対床）**
  と売り超過・売建玉だけ halt。取引所側が多い分は LiveBalance に任せる。
  """

  alias Bitflyer.Startup.Reconcile
  alias Bitflyer.Trading.SpotInventory

  @type mismatch :: {:error, :reconcile_mismatch, map()}

  @doc """
  内部建玉・未約定売りと取引所残高を照合する。

  ## Options
  - `:position_size_tolerance_abs` — 通貨 → 絶対床。省略時は Reconcile の
    `position_size_tolerance_abs`（丸め専用。bps は使わない）
  """
  @spec compare([map()], [map()], [map()], keyword()) :: :ok | mismatch()
  def compare(positions, open_orders, balances, opts \\ [])
      when is_list(positions) and is_list(open_orders) and is_list(balances) do
    with :ok <- reject_short_spot(positions) do
      compare_longs(positions, open_orders, balances, opts)
    end
  end

  defp reject_short_spot(positions) do
    case SpotInventory.first_short_spot(positions) do
      nil ->
        :ok

      currency ->
        {:error, :reconcile_mismatch,
         %{
           kind: :position_mismatch,
           reason: :spot_short_position,
           currency: currency
         }}
    end
  end

  defp compare_longs(positions, open_orders, balances, opts) do
    claimed = SpotInventory.buy_claimed(positions)
    sell_holds = SpotInventory.sell_holds(open_orders)
    currencies = MapSet.union(MapSet.new(Map.keys(claimed)), MapSet.new(Map.keys(sell_holds)))

    Enum.reduce_while(currencies, :ok, fn currency, :ok ->
      case compare_currency(
             currency,
             Map.get(claimed, currency, Decimal.new(0)),
             Map.get(sell_holds, currency, Decimal.new(0)),
             balances,
             opts
           ) do
        :ok -> {:cont, :ok}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp compare_currency(currency, claimed, sell_hold, balances, opts) do
    with {:ok, actual} <- exchange_amount(balances, currency) do
      allowance = tolerance_abs(currency, opts)

      cond do
        exceeds?(sell_hold, claimed, allowance) ->
          {:error, :reconcile_mismatch,
           %{
             kind: :position_mismatch,
             reason: :spot_sell_exceeds_position,
             currency: currency,
             expected: Decimal.to_string(claimed),
             actual: Decimal.to_string(sell_hold),
             allowance: Decimal.to_string(allowance)
           }}

        exceeds?(claimed, actual, allowance) ->
          {:error, :reconcile_mismatch,
           %{
             kind: :position_mismatch,
             reason: :spot_inventory_inflated,
             currency: currency,
             expected: Decimal.to_string(claimed),
             actual: Decimal.to_string(actual),
             allowance: Decimal.to_string(allowance)
           }}

        true ->
          :ok
      end
    end
  end

  defp exceeds?(left, right, allowance) do
    Decimal.compare(Decimal.sub(left, right), allowance) == :gt
  end

  defp exchange_amount(balances, currency) do
    case Enum.find(balances, &(balance_currency(&1) == currency)) do
      nil ->
        {:ok, Decimal.new(0)}

      row ->
        case balance_amount(row) do
          %Decimal{} = amount ->
            {:ok, amount}

          _ ->
            {:error, :reconcile_mismatch,
             %{
               kind: :position_mismatch,
               reason: :invalid_balance_amount,
               currency: currency
             }}
        end
    end
  end

  # Decode / Client.balance はアトムキー。テスト注入は文字列キーもありうる（Risk と同じ）。
  # どちらも無い行は通貨不一致として amount 0 扱い（KeyError で突合全体を落とさない）。
  defp balance_currency(row), do: Map.get(row, :currency) || Map.get(row, "currency")

  defp balance_amount(row), do: Map.get(row, :amount) || Map.get(row, "amount")

  defp tolerance_abs(currency, opts) do
    abs_map =
      Keyword.get_lazy(opts, :position_size_tolerance_abs, fn ->
        Application.get_env(:bitflyer, Reconcile, [])
        |> Keyword.get(:position_size_tolerance_abs, %{"JPY" => "1", "BTC" => "0.00000001"})
      end)

    # キーは config どおり文字列。アトムキーは見ない（String.to_atom 禁止。欠落は 0＝許容なし）。
    parse_decimal(Map.get(abs_map, currency, 0))
  end

  # float は受けない（金額の float 禁止。config は string / Decimal / integer）。
  # 未知型は 0（許容なし）へ倒し、端数をごまかして前進しない。
  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(_), do: Decimal.new(0)
end
