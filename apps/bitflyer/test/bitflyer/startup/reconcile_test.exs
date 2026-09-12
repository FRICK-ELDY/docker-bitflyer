defmodule Bitflyer.Startup.ReconcileTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Startup.{Reconcile, Reconciler}
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Position, RiskState}

  @jpy_amount Decimal.new("1000000")
  @btc_amount Decimal.new("0.5")

  defmodule EmptyExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule MatchingBalancesExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [],
         balances: [
           %{
             currency: "JPY",
             amount: Decimal.new("1000000"),
             available: Decimal.new("1000000")
           },
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule UnsafePermissionsExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}

    @impl true
    def get_permissions do
      {:ok, ["/v1/me/getbalance", "/v1/me/withdraw"]}
    end
  end

  defmodule SkewedTickerRest do
    @behaviour Bitflyer.MarketData.Rest.Client

    @impl true
    def fetch_ticker(product_code) do
      skewed = DateTime.add(DateTime.utc_now(), -120, :second)

      {:ok,
       %{
         "product_code" => product_code,
         "ltp" => 5_000_000,
         "timestamp" => DateTime.to_iso8601(skewed)
       }}
    end
  end

  defmodule MismatchExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [
           %{
             product_code: "FX_BTC_JPY",
             side: :buy,
             size: Decimal.new("0.01"),
             average_price: Decimal.new("5000000")
           }
         ],
         balances: [
           %{
             currency: "JPY",
             amount: Decimal.new("1000000"),
             available: Decimal.new("1000000")
           },
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule AttrMismatchExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [],
         balances: [
           %{
             currency: "JPY",
             amount: Decimal.new("1000000"),
             available: Decimal.new("1000000")
           },
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
         ],
         open_orders: [
           %{
             exchange_order_id: "ex-1",
             product_code: "FX_BTC_JPY",
             side: :buy,
             size: Decimal.new("0.01"),
             filled_size: Decimal.new("0.005")
           }
         ]
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}

    @impl true
    def cancel_order(_request), do: {:error, :not_used_in_reconcile}

    # 突合前の LiveFills 用。ACTIVE のまま返し、filled 差分は載せない
    @impl true
    def fetch_order(%{exchange_order_id: "ex-1"}) do
      {:ok,
       %{
         exchange_order_id: "ex-1",
         product_code: "FX_BTC_JPY",
         side: :buy,
         size: Decimal.new("0.01"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :active
       }}
    end

    def fetch_order(_), do: {:error, :order_not_found}

    @impl true
    def fetch_executions(_request), do: {:ok, []}

    @impl true
    def list_child_orders(_request), do: {:ok, []}
  end

  defmodule DustExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok,
       %{
         positions: [],
         balances: [
           %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("1000000")},
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")},
           %{currency: "XYZ", amount: Decimal.new("0.0001"), available: Decimal.new("0.0001")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule HedgePositionsExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      positions = Application.get_env(:bitflyer, :test_hedge_positions, [])

      {:ok,
       %{
         positions: positions,
         balances: [
           %{
             currency: "JPY",
             amount: Decimal.new("1000000"),
             available: Decimal.new("1000000")
           },
           %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
         ],
         open_orders: []
       }}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule LiveBalancesExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      balances =
        case Application.get_env(:bitflyer, :test_live_balance_queue) do
          [head | tail] ->
            Application.put_env(:bitflyer, :test_live_balance_queue, tail)
            head

          _ ->
            Application.get_env(:bitflyer, :test_live_balances, [
              %{
                currency: "JPY",
                amount: Decimal.new("1000000"),
                available: Decimal.new("1000000")
              },
              %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
            ])
        end

      {:ok, %{positions: [], balances: balances, open_orders: []}}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule InvalidNumberExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:error, :invalid_number}

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  defmodule UnknownSideExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:error, :unknown_side}

    @impl true
    def place_order(_request), do: {:error, :not_used_in_reconcile}
  end

  setup do
    reset_readiness()
    clear_default_risk_state()

    on_exit(fn ->
      reset_readiness()
    end)

    :ok
  end

  test "dry_run restore succeeds and reconciler marks ready" do
    assert {:ok, internal} = Reconcile.run(trade_mode: :dry_run)
    assert internal.trade_mode == :dry_run
    assert internal.positions == []

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
  end

  test "persisted risk halt prevents ready and surfaces reason" do
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "reconcile_mismatch",
               halted_at: halted_at
             })
             |> Ash.create()

    assert {:error, :reconcile_mismatch, _} = Reconcile.run(trade_mode: :dry_run)
    assert {:error, :reconcile_mismatch} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :reconcile_mismatch}
    assert Readiness.format(Readiness.get()) == "halted:reconcile_mismatch"
    refute Readiness.ready?()

    assert {:ok, _} =
             Reconcile.run(trade_mode: :dry_run, skip_persisted_risk?: true)
  end

  test "paper mode treats internal state as source of truth" do
    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.05"),
               average_price: Decimal.new("4800000"),
               trade_mode: :paper
             })
             |> Ash.create()

    assert {:ok, internal} = Reconcile.run(trade_mode: :paper)
    assert length(internal.positions) == 1
    assert hd(internal.positions).trade_mode == :paper
  end

  test "live without exchange client stays halted" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :live_confirmed, true)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :live_confirmed, false)
    end)

    assert {:error, :exchange_unavailable, _} =
             Reconcile.run(trade_mode: :live, exchange: Bitflyer.Exchange)

    assert {:error, :exchange_unavailable} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :exchange_unavailable}
  end

  test "live empty BalanceSnapshot halts with balance_baseline_missing" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, EmptyExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    assert {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing, currency: "JPY"}} =
             Reconcile.run(trade_mode: :live, exchange: EmptyExchange)

    assert {:error, :reconcile_mismatch} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :reconcile_mismatch}
    refute Readiness.ready?()
  end

  test "live invalid exchange number fails snapshot and halts" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, InvalidNumberExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    assert {:error, :invalid_exchange_payload, %{kind: :invalid_number}} =
             Reconcile.run(trade_mode: :live, exchange: InvalidNumberExchange)

    assert {:error, :invalid_exchange_payload} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :invalid_exchange_payload}
  end

  test "live unknown exchange side fails snapshot and halts" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, UnknownSideExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    assert {:error, :invalid_exchange_payload, %{kind: :unknown_side}} =
             Reconcile.run(trade_mode: :live, exchange: UnknownSideExchange)

    assert {:error, :invalid_exchange_payload} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :invalid_exchange_payload}
    refute Readiness.ready?()
  end

  test "live with required balance baseline matching exchange can become ready" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, MatchingBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: MatchingBalancesExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
  end

  test "live position mismatch halts with reconcile_mismatch" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, MismatchExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    assert {:error, :reconcile_mismatch, %{kind: :position_missing_internal}} =
             Reconcile.run(trade_mode: :live, exchange: MismatchExchange)

    assert {:error, :reconcile_mismatch} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert {:ok, risk} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()

    assert risk.halted
    assert risk.reason == "reconcile_mismatch"
  end

  test "live spot internal position is excluded from position compare" do
    alias Bitflyer.Trading.Position

    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, MatchingBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    # spot 内部 Position があっても getpositions 空なら建玉不一致にしない（正本は getbalance）
    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "BTC_JPY",
               trade_mode: :live,
               side: :buy,
               size: Decimal.new("0.01"),
               average_price: Decimal.new("5000000")
             })
             |> Ash.create()

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: MatchingBalancesExchange)
  end

  test "live open order attribute mismatch is detected" do
    alias Bitflyer.Trading.Order

    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
    end)

    seed_live_balance_baseline!()

    assert {:ok, _} =
             Order
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "ord-live-1",
               exchange_order_id: "ex-1",
               product_code: "FX_BTC_JPY",
               side: :buy,
               price: Decimal.new("5000000"),
               size: Decimal.new("0.01"),
               filled_size: Decimal.new("0"),
               trade_mode: :live
             })
             |> Ash.create()

    assert {:error, :reconcile_mismatch, %{kind: :open_order_mismatch}} =
             Reconcile.run(trade_mode: :live, exchange: AttrMismatchExchange)
  end

  test "restore picks latest balance snapshot per currency" do
    older = ~U[2026-01-01 00:00:00.000000Z]
    newer = ~U[2026-01-02 00:00:00.000000Z]

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: "JPY",
               amount: Decimal.new("100"),
               available: Decimal.new("100"),
               captured_at: older,
               trade_mode: :dry_run
             })
             |> Ash.create()

    assert {:ok, _} =
             BalanceSnapshot
             |> Ash.Changeset.for_create(:create, %{
               currency: "JPY",
               amount: Decimal.new("200"),
               available: Decimal.new("150"),
               captured_at: newer,
               trade_mode: :dry_run
             })
             |> Ash.create()

    assert {:ok, internal} = Reconcile.restore(:dry_run)
    assert [snap] = internal.balance_snapshots
    assert Decimal.eq?(snap.amount, Decimal.new("200"))
  end

  test "live ignores untracked dust currencies on exchange" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
    end)

    seed_live_balance_baseline!()

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: DustExchange)
  end

  test "live hedges net to internal position regardless of buy/sell list order" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               average_price: Decimal.new("5000000"),
               trade_mode: :live
             })
             |> Ash.create()

    buy = %{
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.03"),
      average_price: Decimal.new("5000000")
    }

    sell = %{
      product_code: "FX_BTC_JPY",
      side: :sell,
      size: Decimal.new("0.02"),
      average_price: Decimal.new("5100000")
    }

    for order <- [[buy, sell], [sell, buy]] do
      Application.put_env(:bitflyer, :test_hedge_positions, order)
      assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
      assert Reconciler.run_now() == :ok
      assert Readiness.get() == :ready
      assert Readiness.mark_not_ready() == :ok
    end
  end

  test "live hedge nets to short regardless of buy/sell list order" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "FX_BTC_JPY",
               side: :sell,
               size: Decimal.new("0.01"),
               average_price: Decimal.new("5100000"),
               trade_mode: :live
             })
             |> Ash.create()

    buy = %{
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.02"),
      average_price: Decimal.new("5000000")
    }

    sell = %{
      product_code: "FX_BTC_JPY",
      side: :sell,
      size: Decimal.new("0.03"),
      average_price: Decimal.new("5100000")
    }

    for order <- [[buy, sell], [sell, buy]] do
      Application.put_env(:bitflyer, :test_hedge_positions, order)
      assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
      assert Reconciler.run_now() == :ok
      assert Readiness.get() == :ready
      assert Readiness.mark_not_ready() == :ok
    end
  end

  test "live hedged net matches side+size even when winning-side VWAP differs from internal" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    # ドテン後の内部平均（fill 単価）と、勝ちサイド全量 VWAP が食い違うケース
    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "FX_BTC_JPY",
               side: :sell,
               size: Decimal.new("0.01"),
               average_price: Decimal.new("5200000"),
               trade_mode: :live
             })
             |> Ash.create()

    Application.put_env(:bitflyer, :test_hedge_positions, [
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.02"),
        average_price: Decimal.new("5000000")
      },
      %{
        product_code: "FX_BTC_JPY",
        side: :sell,
        size: Decimal.new("0.03"),
        average_price: Decimal.new("5100000")
      }
    ])

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
  end

  test "live invalid exchange position side fail-closes" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    Application.put_env(:bitflyer, :test_hedge_positions, [
      %{
        product_code: "FX_BTC_JPY",
        side: :unknown,
        size: Decimal.new("0.01"),
        average_price: Decimal.new("5000000")
      }
    ])

    assert {:error, :reconcile_mismatch, %{kind: :position_invalid_exchange}} =
             Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
  end

  test "live hedge that only matches one leg (not net) still mismatches" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    # 旧実装は product_code Map で buy だけ残ると誤 Ready になり得た
    assert {:ok, _} =
             Position
             |> Ash.Changeset.for_create(:create, %{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.03"),
               average_price: Decimal.new("5000000"),
               trade_mode: :live
             })
             |> Ash.create()

    buy = %{
      product_code: "FX_BTC_JPY",
      side: :buy,
      size: Decimal.new("0.03"),
      average_price: Decimal.new("5000000")
    }

    sell = %{
      product_code: "FX_BTC_JPY",
      side: :sell,
      size: Decimal.new("0.02"),
      average_price: Decimal.new("5100000")
    }

    for order <- [[buy, sell], [sell, buy]] do
      Application.put_env(:bitflyer, :test_hedge_positions, order)

      assert {:error, :reconcile_mismatch, %{kind: :position_mismatch}} =
               Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
    end
  end

  test "live equal buy+sell hedge nets to flat" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, HedgePositionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_hedge_positions)
    end)

    seed_live_balance_baseline!()

    Application.put_env(:bitflyer, :test_hedge_positions, [
      %{
        product_code: "FX_BTC_JPY",
        side: :sell,
        size: Decimal.new("0.01"),
        average_price: Decimal.new("5100000")
      },
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        average_price: Decimal.new("5000000")
      }
    ])

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: HedgePositionsExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
  end

  test "live fill then periodic reconcile and restart keep ready and advance tip" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, LiveBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()
    seed_live_spot_buy_fill!()

    filled = [
      %{currency: "JPY", amount: Decimal.new("950000"), available: Decimal.new("950000")},
      %{currency: "BTC", amount: Decimal.new("0.51"), available: Decimal.new("0.51")}
    ]

    Application.put_env(:bitflyer, :test_live_balances, filled)

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready

    assert {:ok, tips} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "JPY")).amount, Decimal.new("950000"))
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "BTC")).amount, Decimal.new("0.51"))

    # 再起動相当: 同じ取引所残高でもう一度突合しても Ready を維持
    assert Readiness.mark_not_ready() == :ok
    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == :ready
  end

  test "live unexplained deposit after fill advances then halt" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, LiveBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()
    seed_live_spot_buy_fill!()

    Application.put_env(:bitflyer, :test_live_balances, [
      %{currency: "JPY", amount: Decimal.new("950000"), available: Decimal.new("950000")},
      %{currency: "BTC", amount: Decimal.new("0.51"), available: Decimal.new("0.51")}
    ])

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)

    Application.put_env(:bitflyer, :test_live_balances, [
      %{currency: "JPY", amount: Decimal.new("1050000"), available: Decimal.new("1050000")},
      %{currency: "BTC", amount: Decimal.new("0.51"), available: Decimal.new("0.51")}
    ])

    assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"}} =
             Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
  end

  test "live in-band deposit after fill is balance_mismatch" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, LiveBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()
    seed_live_spot_buy_fill!()

    # expected JPY 950_000. +80 is inside 20bps but is an increase.
    Application.put_env(:bitflyer, :test_live_balances, [
      %{currency: "JPY", amount: Decimal.new("950080"), available: Decimal.new("950080")},
      %{currency: "BTC", amount: Decimal.new("0.51"), available: Decimal.new("0.51")}
    ])

    assert {:error, :reconcile_mismatch,
            %{kind: :balance_mismatch, currency: "JPY", unexplained: "80"}} =
             Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
  end

  test "live getbalance lag after fill refetches and advances" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, LiveBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()
    seed_live_spot_buy_fill!()

    stale = [
      %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("1000000")},
      %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
    ]

    filled = [
      %{currency: "JPY", amount: Decimal.new("950000"), available: Decimal.new("950000")},
      %{currency: "BTC", amount: Decimal.new("0.51"), available: Decimal.new("0.51")}
    ]

    Application.put_env(:bitflyer, :test_live_balance_queue, [stale, filled])

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
    assert {:ok, tips} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "JPY")).amount, Decimal.new("950000"))
  end

  test "live getbalance still stale after refetch is balance_mismatch" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, LiveBalancesExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()
    seed_live_spot_buy_fill!()

    stale = [
      %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("1000000")},
      %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
    ]

    Application.put_env(:bitflyer, :test_live_balance_queue, [stale, stale])

    assert {:error, :reconcile_mismatch,
            %{kind: :balance_mismatch, reason: :balance_exchange_lag, currency: currency}} =
             Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)

    assert currency in ["JPY", "BTC"]
  end

  test "live available hold without amount change still reconciles" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.delete_env(:bitflyer, :test_live_balances)
      Application.delete_env(:bitflyer, :test_live_balance_queue)
    end)

    seed_live_balance_baseline!()

    Application.put_env(:bitflyer, :test_live_balances, [
      %{currency: "JPY", amount: Decimal.new("1000000"), available: Decimal.new("950000")},
      %{currency: "BTC", amount: Decimal.new("0.5"), available: Decimal.new("0.5")}
    ])

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: LiveBalancesExchange)
    assert {:ok, tips} = BalanceSnapshot.latest_tips(:live)
    assert Decimal.eq?(Enum.find(tips, &(&1.currency == "JPY")).available, Decimal.new("950000"))
  end

  test "halted readiness is not auto-cleared on successful reconcile" do
    assert Readiness.halt(:reconcile_mismatch) == :ok
    assert {:ok, _} = Reconcile.run(trade_mode: :dry_run)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == {:halted, :reconcile_mismatch}
  end

  test "live with withdraw permission halts as unsafe_api_permissions" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, UnsafePermissionsExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

    seed_live_balance_baseline!()

    assert {:error, :unsafe_api_permissions, %{permission: "/v1/me/withdraw"}} =
             Reconcile.run(trade_mode: :live, exchange: UnsafePermissionsExchange)

    assert {:error, :unsafe_api_permissions} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :unsafe_api_permissions}
  end

  test "live with skewed ticker timestamp halts as clock_skew" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData)

    Application.put_env(:bitflyer, :trade_mode, :live)
    Application.put_env(:bitflyer, :exchange_client, MatchingBalancesExchange)

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.merge(previous_md || [], rest_client: SkewedTickerRest)
    )

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous_md)
    end)

    seed_live_balance_baseline!()

    assert {:error, :clock_skew, %{skew_ms: skew_ms}} =
             Reconcile.run(trade_mode: :live, exchange: MatchingBalancesExchange)

    assert skew_ms > 5_000
    assert {:error, :clock_skew} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :clock_skew}
  end

  defp seed_live_spot_buy_fill! do
    filled_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Fill
             |> Ash.Changeset.for_create(:create, %{
               internal_order_id: "live-bal-fill-1",
               exchange_execution_id: "exec-live-bal-1",
               product_code: "BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               price: Decimal.new("5000000"),
               realized_pnl: Decimal.new(0),
               trade_mode: :live,
               filled_at: filled_at
             })
             |> Ash.create()

    :ok
  end

  defp seed_live_balance_baseline! do
    captured_at =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:microsecond)

    for {currency, amount} <- [{"JPY", @jpy_amount}, {"BTC", @btc_amount}] do
      assert {:ok, _} =
               BalanceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 currency: currency,
                 amount: amount,
                 available: amount,
                 captured_at: captured_at,
                 trade_mode: :live
               })
               |> Ash.create()
    end

    :ok
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} ->
        :ok

      {:ok, risk} ->
        Ash.destroy!(risk)

      {:error, _} ->
        :ok
    end
  end
end
