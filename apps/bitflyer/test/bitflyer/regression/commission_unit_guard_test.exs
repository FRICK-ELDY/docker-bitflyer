defmodule Bitflyer.Regression.CommissionUnitGuardTest do
  @moduledoc """
  P0 #2 反証回帰（LiveBalance / LiveInventory）。

  `getexecutions_btc_jpy_fee.json` と取引所残高（base fee モデル）だけで、
  commission を quote（JPY）と決め打ちした旧実装が reconcile 失敗することを固定する。

  ハーネスが quote だけから fee を引く退行は本ファイル外。
  `live_balance_advance_test` の `apply_fill deducts commission from base...` が担当する。
  """

  use ExUnit.Case, async: true

  alias Bitflyer.Startup.{LiveBalance, LiveInventory}

  @fixture Path.expand("../../fixtures/exchange/getexecutions_btc_jpy_fee.json", __DIR__)
  @jpy Decimal.new("1000000")
  @btc Decimal.new("0.5")
  @captured ~U[2026-09-01 00:00:00.000000Z]
  @inventory_tol %{"BTC" => "0.00000001"}

  describe "fixture buy (P0 #2 guard)" do
    setup do
      [buy | _] = load_fixture()
      {:ok, buy: buy, fill: fill_from_execution(buy)}
    end

    test "BTC fee_currency explains real exchange balances", %{fill: fill} do
      assert {:ok, plan} =
               LiveBalance.explain(
                 tips(),
                 exchange(Decimal.new("950000"), Decimal.new("0.50999")),
                 ["JPY", "BTC"],
                 fills: [fill],
                 fee_tolerance_bps: 0
               )

      assert Enum.any?(plan.rows, & &1.changed?)
    end

    test "JPY fee_currency fails balance_mismatch", %{fill: fill} do
      wrong = Map.put(fill, :fee_currency, "JPY")

      assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}} =
               LiveBalance.explain(
                 tips(),
                 exchange(Decimal.new("950000"), Decimal.new("0.50999")),
                 ["JPY", "BTC"],
                 fills: [wrong],
                 fee_tolerance_bps: 0
               )

      assert currency in ["JPY", "BTC"]
    end

    test "legacy quote-only exchange balances fail reconcile with BTC fee fill", %{fill: fill} do
      # 旧モデル残高: JPY から commission を引き BTC は size 全量 → 949_920 / 0.51
      assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}} =
               LiveBalance.explain(
                 tips(),
                 exchange(Decimal.new("949920"), Decimal.new("0.51")),
                 ["JPY", "BTC"],
                 fills: [fill],
                 fee_tolerance_bps: 0
               )

      assert currency in ["JPY", "BTC"]
    end
  end

  describe "fixture sell (P0 #2 guard)" do
    setup do
      [_buy, sell] = load_fixture()
      {:ok, sell: sell, fill: fill_from_execution(sell, side: :sell)}
    end

    test "BTC fee_currency explains round-trip exchange balances", %{fill: fill} do
      after_buy_jpy = Decimal.new("950000")
      after_buy_btc = Decimal.new("0.50999")

      assert {:ok, plan} =
               LiveBalance.explain(
                 tips_after_buy(after_buy_jpy, after_buy_btc),
                 exchange(Decimal.new("999900"), @btc),
                 ["JPY", "BTC"],
                 fills: [fill],
                 fee_tolerance_bps: 0
               )

      assert Enum.any?(plan.rows, & &1.changed?)
    end

    test "JPY fee_currency fails sell reconcile", %{fill: fill} do
      wrong = Map.put(fill, :fee_currency, "JPY")

      assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch}} =
               LiveBalance.explain(
                 tips_after_buy(Decimal.new("950000"), Decimal.new("0.50999")),
                 exchange(Decimal.new("999900"), @btc),
                 ["JPY", "BTC"],
                 fills: [wrong],
                 fee_tolerance_bps: 0
               )
    end

    test "legacy quote-only sell balances fail reconcile with BTC fee fill", %{fill: fill} do
      # tip は買い後 base 正。旧売り: commission を JPY 額として notional から引く
      # → 950000 + 49950 − 0.00001 = 999949.99999 / BTC 0.5。正は 999900 / 0.5
      assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}} =
               LiveBalance.explain(
                 tips_after_buy(Decimal.new("950000"), Decimal.new("0.50999")),
                 exchange(Decimal.new("999949.99999"), @btc),
                 ["JPY", "BTC"],
                 fills: [fill],
                 fee_tolerance_bps: 0
               )

      assert currency in ["JPY", "BTC"]
    end
  end

  test "exec_size position vs base-fee exchange amount is spot_inventory_inflated" do
    # 取引所 net = size − fee。Position が exec_size 全量だと在庫膨張。
    assert {:error, :reconcile_mismatch,
            %{kind: :position_mismatch, reason: :spot_inventory_inflated, currency: "BTC"}} =
             LiveInventory.compare(
               [%{product_code: "BTC_JPY", side: :buy, size: Decimal.new("0.01")}],
               [],
               [
                 %{
                   currency: "BTC",
                   amount: Decimal.new("0.00999"),
                   available: Decimal.new("0.00999")
                 }
               ],
               position_size_tolerance_abs: @inventory_tol
             )
  end

  test "held net position matches base-fee exchange amount" do
    assert :ok =
             LiveInventory.compare(
               [%{product_code: "BTC_JPY", side: :buy, size: Decimal.new("0.00999")}],
               [],
               [
                 %{
                   currency: "BTC",
                   amount: Decimal.new("0.00999"),
                   available: Decimal.new("0.00999")
                 }
               ],
               position_size_tolerance_abs: @inventory_tol
             )
  end

  defp load_fixture do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp fill_from_execution(row, opts \\ []) do
    side =
      case Keyword.get(opts, :side, row["side"]) do
        :sell -> :sell
        "SELL" -> :sell
        _ -> :buy
      end

    %{
      product_code: "BTC_JPY",
      side: side,
      size: decimal_field(row, "size"),
      price: decimal_field(row, "price"),
      fee: decimal_field(row, "commission"),
      fee_currency: "BTC",
      inserted_at: ~U[2026-09-01 00:01:00.000000Z]
    }
  end

  # JSON number 経由の float を避ける（文字列 fixture でも to_string で揃える）
  defp decimal_field(row, key), do: Decimal.new(to_string(Map.fetch!(row, key)))

  defp tips do
    [
      %{currency: "JPY", amount: @jpy, available: @jpy, captured_at: @captured},
      %{currency: "BTC", amount: @btc, available: @btc, captured_at: @captured}
    ]
  end

  defp tips_after_buy(jpy, btc) do
    [
      %{currency: "JPY", amount: jpy, available: jpy, captured_at: @captured},
      %{currency: "BTC", amount: btc, available: btc, captured_at: @captured}
    ]
  end

  defp exchange(jpy_amount, btc_amount) do
    [
      %{currency: "JPY", amount: jpy_amount, available: jpy_amount},
      %{currency: "BTC", amount: btc_amount, available: btc_amount}
    ]
  end
end
