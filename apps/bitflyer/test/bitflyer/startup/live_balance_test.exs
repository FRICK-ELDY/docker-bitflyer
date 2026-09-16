defmodule Bitflyer.Startup.LiveBalanceTest do
  use Bitflyer.DataCase, async: false

  alias Bitflyer.Startup.LiveBalance
  alias Bitflyer.Trading.{BalanceSnapshot, Fill}

  @jpy Decimal.new("1000000")
  @btc Decimal.new("0.5")
  @captured ~U[2026-09-01 00:00:00.000000Z]

  test "exact match needs no advance" do
    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(@jpy, @jpy, @btc, @btc), ["JPY", "BTC"],
               fills: []
             )

    refute Enum.any?(plan.rows, & &1.changed?)
    assert :ok = LiveBalance.advance(plan)
    assert {:ok, []} = BalanceSnapshot.latest_tips(:live)
  end

  test "available-only change is explained and appended" do
    held = Decimal.new("950000")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(@jpy, held, @btc, @btc), ["JPY", "BTC"],
               fills: []
             )

    jpy = Enum.find(plan.rows, &(&1.currency == "JPY"))
    assert jpy.changed?
    assert Decimal.eq?(jpy.available, held)
    assert Decimal.eq?(jpy.amount, @jpy)

    assert :ok = LiveBalance.advance(plan)
    assert {:ok, rows} = BalanceSnapshot.latest_tips(:live)
    tip = Enum.find(rows, &(&1.currency == "JPY"))
    assert Decimal.eq?(tip.available, held)
    assert Decimal.eq?(tip.amount, @jpy)
  end

  test "BTC_JPY fee fixture matches LiveBalance expected amounts" do
    path =
      Path.expand("../../fixtures/exchange/getexecutions_btc_jpy_fee.json", __DIR__)

    [buy, sell] =
      path
      |> File.read!()
      |> Jason.decode!()

    buy_fill = %{
      product_code: "BTC_JPY",
      side: :buy,
      size: Decimal.new(buy["size"]),
      price: Decimal.new(buy["price"]),
      fee: Decimal.new(buy["commission"]),
      fee_currency: "BTC",
      inserted_at: ~U[2026-09-01 00:01:00.000000Z]
    }

    after_buy_jpy = Decimal.new("950000")
    after_buy_btc = Decimal.new("0.50999")

    assert {:ok, plan} =
             LiveBalance.explain(
               tips(),
               exchange(after_buy_jpy, after_buy_jpy, after_buy_btc, after_buy_btc),
               ["JPY", "BTC"],
               fills: [buy_fill],
               fee_tolerance_bps: 0
             )

    assert Enum.any?(plan.rows, & &1.changed?)
    assert :ok = LiveBalance.advance(plan)

    sell_fill = %{
      product_code: "BTC_JPY",
      side: :sell,
      size: Decimal.new(sell["size"]),
      price: Decimal.new(sell["price"]),
      fee: Decimal.new(sell["commission"]),
      fee_currency: "BTC",
      inserted_at: ~U[2026-09-01 00:02:00.000000Z]
    }

    after_sell_jpy = Decimal.new("999900")
    after_sell_btc = @btc

    assert {:ok, plan2} =
             LiveBalance.explain(
               [
                 %{
                   currency: "JPY",
                   amount: after_buy_jpy,
                   available: after_buy_jpy,
                   captured_at: @captured
                 },
                 %{
                   currency: "BTC",
                   amount: after_buy_btc,
                   available: after_buy_btc,
                   captured_at: @captured
                 }
               ],
               exchange(after_sell_jpy, after_sell_jpy, after_sell_btc, after_sell_btc),
               ["JPY", "BTC"],
               fills: [sell_fill],
               fee_tolerance_bps: 0
             )

    assert Enum.any?(plan2.rows, & &1.changed?)
  end

  test "spot buy fill plus fee within tolerance advances" do
    fills = [spot_buy_fill()]
    # 50_000 notional, 20bps = 100. Exchange took 80 JPY fee.
    jpy = Decimal.new("949920")
    btc = Decimal.new("0.51")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )

    assert Enum.any?(plan.rows, & &1.changed?)
    assert :ok = LiveBalance.advance(plan)
    assert {:ok, rows} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "JPY")).amount, jpy)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "BTC")).amount, btc)
  end

  test "unexplained deposit is balance_mismatch" do
    deposited = Decimal.new("1100000")

    assert {:error, :reconcile_mismatch,
            %{kind: :balance_mismatch, currency: "JPY", unexplained: unexplained}} =
             LiveBalance.explain(
               tips(),
               exchange(deposited, deposited, @btc, @btc),
               ["JPY", "BTC"],
               fills: []
             )

    assert unexplained == "100000"
  end

  test "in-band deposit after fill is still balance_mismatch" do
    fills = [spot_buy_fill()]
    # expected JPY 950_000. +80 is inside 20bps but is an increase (deposit).
    jpy = Decimal.new("950080")
    btc = Decimal.new("0.51")

    assert {:error, :reconcile_mismatch,
            %{kind: :balance_mismatch, currency: "JPY", unexplained: "80"}} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )
  end

  test "one yen change with no fills is balance_mismatch" do
    jpy = Decimal.new("999999")

    assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"}} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, @btc, @btc), ["JPY", "BTC"],
               fills: []
             )
  end

  test "fee beyond allowance is balance_mismatch" do
    fills = [spot_buy_fill()]
    # expected JPY 950_000, allowance 100. 900 JPY gap.
    jpy = Decimal.new("949100")

    assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"}} =
             LiveBalance.explain(
               tips(),
               exchange(jpy, jpy, Decimal.new("0.51"), Decimal.new("0.51")),
               [
                 "JPY",
                 "BTC"
               ],
               fills: fills
             )
  end

  test "FX fill does not explain spot amount change" do
    fills = [
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        price: Decimal.new("5000000"),
        inserted_at: ~U[2026-09-01 00:01:00.000000Z]
      }
    ]

    jpy = Decimal.new("950000")

    assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"}} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, @btc, @btc), ["JPY", "BTC"],
               fills: fills
             )
  end

  test "recorded base fee advances without bps allowance" do
    fills = [
      spot_buy_fill(%{fee: Decimal.new("0.00001"), fee_currency: "BTC"})
    ]

    # JPY = tip - notional。BTC = tip + size - fee
    jpy = Decimal.new("950000")
    btc = Decimal.new("0.50999")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills,
               fee_tolerance_bps: 0
             )

    assert Enum.any?(plan.rows, & &1.changed?)
    assert :ok = LiveBalance.advance(plan)
    assert {:ok, rows} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "JPY")).amount, jpy)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "BTC")).amount, btc)
  end

  test "recorded sell base fee advances without bps allowance" do
    fills = [
      Map.merge(spot_sell_fill(), %{fee: Decimal.new("0.00001"), fee_currency: "BTC"})
    ]

    # JPY = tip + notional - fee*price。BTC = tip - size
    jpy = Decimal.new("1049950")
    btc = Decimal.new("0.49")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills,
               fee_tolerance_bps: 0
             )

    assert Enum.any?(plan.rows, & &1.changed?)
  end

  test "spot sell fill plus fee within tolerance advances" do
    fills = [spot_sell_fill()]
    # fee 未記録。expected JPY 1_050_000、BTC 0.49。20bps 内の減額を許容
    jpy = Decimal.new("1049920")
    btc = Decimal.new("0.49")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )

    assert Enum.any?(plan.rows, & &1.changed?)
  end

  test "spot sell fill plus in-band extra JPY is deposit mismatch" do
    fills = [spot_sell_fill()]
    jpy = Decimal.new("1050080")
    btc = Decimal.new("0.49")

    assert {:error, :reconcile_mismatch,
            %{kind: :balance_mismatch, currency: "JPY", unexplained: "80"}} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )
  end

  test "BTC as base and quote sums fee allowance instead of picking one leg" do
    fills = [
      %{
        product_code: "BTC_JPY",
        side: :sell,
        size: Decimal.new("1"),
        price: Decimal.new("5000000"),
        inserted_at: ~U[2026-09-01 00:01:00.000000Z]
      },
      %{
        product_code: "ETH_BTC",
        side: :buy,
        size: Decimal.new("0.001"),
        price: Decimal.new("0.05"),
        inserted_at: ~U[2026-09-01 00:01:01.000000Z]
      }
    ]

    # expected BTC = 1.5 - 1 - 0.00005 = 0.49995。実残高は売り手数料 0.00015 を引く。
    # exclusive なら ETH_BTC の quote 側 20bps だけ（≈5e-8）になり halt する。
    tips = [
      %{currency: "JPY", amount: @jpy, available: @jpy, captured_at: @captured},
      %{
        currency: "BTC",
        amount: Decimal.new("1.5"),
        available: Decimal.new("1.5"),
        captured_at: @captured
      }
    ]

    jpy = Decimal.new("6000000")
    btc = Decimal.new("0.4998")

    assert {:ok, _} =
             LiveBalance.explain(tips, exchange(jpy, jpy, btc, btc), ["JPY", "BTC"], fills: fills)
  end

  test "two partial buy fills add to the same notional" do
    fills = [
      spot_buy_fill(%{
        size: Decimal.new("0.004"),
        inserted_at: ~U[2026-09-01 00:01:00.000000Z]
      }),
      spot_buy_fill(%{
        size: Decimal.new("0.006"),
        inserted_at: ~U[2026-09-01 00:01:01.000000Z]
      })
    ]

    jpy = Decimal.new("949920")
    btc = Decimal.new("0.51")

    assert {:ok, _} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )
  end

  test "delayed fill uses inserted_at even when filled_at is before tip" do
    fills = [
      spot_buy_fill(%{
        filled_at: ~U[2026-08-31 23:59:00.000000Z],
        inserted_at: ~U[2026-09-01 00:01:00.000000Z]
      })
    ]

    jpy = Decimal.new("950000")
    btc = Decimal.new("0.51")

    assert {:ok, _} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )
  end

  test "persisted delayed fill is loaded by inserted_at after tip" do
    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "live-delayed-1",
               exchange_execution_id: "exec-delayed-1",
               product_code: "BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               price: Decimal.new("5000000"),
               realized_pnl: Decimal.new(0),
               trade_mode: :live,
               filled_at: ~U[2026-08-31 23:59:00.000000Z]
             })
             |> Ash.create()

    jpy = Decimal.new("950000")
    btc = Decimal.new("0.51")

    assert {:ok, _} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"])
  end

  test "fill with unmoved exchange amount is balance_exchange_lag" do
    fills = [spot_buy_fill()]

    assert {:error, :reconcile_mismatch, %{kind: :balance_exchange_lag, currency: currency}} =
             LiveBalance.explain(tips(), exchange(@jpy, @jpy, @btc, @btc), ["JPY", "BTC"],
               fills: fills
             )

    assert currency in ["JPY", "BTC"]
  end

  test "stale plan does not overwrite a newer different tip" do
    fills = [spot_buy_fill()]
    jpy = Decimal.new("950000")
    btc = Decimal.new("0.51")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )

    later = DateTime.add(plan.captured_at, 1, :second)

    for {currency, amount} <- [{"JPY", Decimal.new("940000")}, {"BTC", btc}] do
      assert {:ok, _} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: currency,
                 amount: amount,
                 available: amount,
                 captured_at: later,
                 trade_mode: :live
               })
               |> Ash.create()
    end

    assert :ok = LiveBalance.advance(plan)
    assert {:ok, rows} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "JPY")).amount, Decimal.new("940000"))
    refute Enum.any?(rows, &(DateTime.compare(&1.captured_at, later) == :gt))
  end

  test "stale plan is skipped when latest tip already matches" do
    fills = [spot_buy_fill()]
    jpy = Decimal.new("950000")
    btc = Decimal.new("0.51")

    assert {:ok, plan} =
             LiveBalance.explain(tips(), exchange(jpy, jpy, btc, btc), ["JPY", "BTC"],
               fills: fills
             )

    later = DateTime.add(plan.captured_at, 1, :second)

    for {currency, amount} <- [{"JPY", jpy}, {"BTC", btc}] do
      assert {:ok, _} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: currency,
                 amount: amount,
                 available: amount,
                 captured_at: later,
                 trade_mode: :live
               })
               |> Ash.create()
    end

    assert :ok = LiveBalance.advance(plan)
    assert {:ok, rows} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(rows, &(&1.currency == "JPY")).amount, jpy)
    refute Enum.any?(rows, &(DateTime.compare(&1.captured_at, later) == :gt))
  end

  test "missing required tip is baseline missing" do
    only_jpy = [hd(tips())]

    assert {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing, currency: "BTC"}} =
             LiveBalance.explain(only_jpy, exchange(@jpy, @jpy, @btc, @btc), ["JPY", "BTC"],
               fills: []
             )
  end

  defp tips do
    [
      %{currency: "JPY", amount: @jpy, available: @jpy, captured_at: @captured},
      %{currency: "BTC", amount: @btc, available: @btc, captured_at: @captured}
    ]
  end

  defp exchange(jpy_amount, jpy_available, btc_amount, btc_available) do
    [
      %{currency: "JPY", amount: jpy_amount, available: jpy_available},
      %{currency: "BTC", amount: btc_amount, available: btc_available}
    ]
  end

  defp spot_buy_fill(overrides \\ %{}) do
    Map.merge(
      %{
        product_code: "BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        price: Decimal.new("5000000"),
        inserted_at: ~U[2026-09-01 00:01:00.000000Z]
      },
      overrides
    )
  end

  defp spot_sell_fill do
    %{
      product_code: "BTC_JPY",
      side: :sell,
      size: Decimal.new("0.01"),
      price: Decimal.new("5000000"),
      inserted_at: ~U[2026-09-01 00:01:00.000000Z]
    }
  end
end
