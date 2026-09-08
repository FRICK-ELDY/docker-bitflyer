defmodule Bitflyer.Startup.ReconcileTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Startup.{Reconcile, Reconciler}
  alias Bitflyer.Trading.{Position, RiskState}

  defmodule EmptyExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end
  end

  defmodule MismatchExchange do
    @behaviour Bitflyer.Exchange.Client

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
         balances: [],
         open_orders: []
       }}
    end
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

  test "live matches empty exchange snapshot and can become ready" do
    previous = Application.get_env(:bitflyer, :trade_mode)

    Application.put_env(:bitflyer, :trade_mode, :live)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
    end)

    assert {:ok, _} = Reconcile.run(trade_mode: :live, exchange: EmptyExchange)

    # Reconciler は Bitflyer.Exchange facade 経由なので client を差し替える
    Application.put_env(:bitflyer, :exchange_client, EmptyExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :exchange_client, Bitflyer.Exchange.Unavailable)
    end)

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

  test "halted readiness is not auto-cleared on successful reconcile" do
    assert Readiness.halt(:reconcile_mismatch) == :ok
    assert {:ok, _} = Reconcile.run(trade_mode: :dry_run)
    assert Reconciler.run_now() == :ok
    assert Readiness.get() == {:halted, :reconcile_mismatch}
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
