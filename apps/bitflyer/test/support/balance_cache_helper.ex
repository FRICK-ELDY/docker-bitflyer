defmodule Bitflyer.TestSupport.BalanceCacheHelper do
  @moduledoc false

  alias Bitflyer.Risk.BalanceCache
  alias Bitflyer.Trading.BalanceSnapshot

  @default_balances %{
    "JPY" => Decimal.new("10000000"),
    "BTC" => Decimal.new("1")
  }

  @doc """
  共有 BalanceCache ETS を全モード unsynced に戻す。
  """
  def reset_balance_cache do
    BalanceCache.reset()
  end

  @doc """
  paper/live 認可用に十分な残高をキャッシュへ書く（DB は触らない）。
  """
  def seed_balance_cache!(trade_mode, balances \\ @default_balances)
      when trade_mode in [:paper, :live, :dry_run] do
    normalized = normalize_balances(balances)
    assert_put!(trade_mode, normalized)
  end

  @doc """
  paper 用に BalanceSnapshot を作り、キャッシュへ refresh する。
  fill 後の refresh と認可が同じ正本を見る。
  """
  def seed_paper_balances!(balances \\ @default_balances) do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(normalize_balances(balances), fn {currency, available} ->
      {:ok, _} =
        BalanceSnapshot
        |> Ash.Changeset.for_create(:create, %{
          currency: currency,
          amount: available,
          available: available,
          captured_at: captured_at,
          trade_mode: :paper
        })
        |> Ash.create()
    end)

    case BalanceCache.refresh(:paper) do
      :ok -> :ok
      other -> raise "BalanceCache.refresh(:paper) failed: #{inspect(other)}"
    end
  end

  defp normalize_balances(balances) do
    Map.new(balances, fn {currency, value} ->
      available =
        case value do
          %Decimal{} = d -> d
          raw when is_binary(raw) or is_integer(raw) -> Decimal.new(raw)
          %{available: val} -> Decimal.new(to_string(val))
        end

      {to_string(currency), available}
    end)
  end

  defp assert_put!(trade_mode, balances) do
    case BalanceCache.put(trade_mode, balances) do
      :ok -> :ok
      other -> raise "BalanceCache.put failed: #{inspect(other)}"
    end
  end
end
