defmodule Bitflyer.Startup.ResumeTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Startup.{Reconcile, Resume}
  alias Bitflyer.Trading.RiskState

  defmodule EmptyExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_resume}
  end

  defmodule UnavailableExchange do
    @behaviour Bitflyer.Exchange.Client

    @impl true
    def fetch_reconcile_snapshot, do: {:error, :exchange_unavailable}

    @impl true
    def place_order(_request), do: {:error, :not_used_in_resume}
  end

  setup do
    reset_readiness()
    clear_default_risk_state()

    previous_mode = Application.get_env(:bitflyer, :trade_mode, :dry_run)
    Application.put_env(:bitflyer, :trade_mode, :dry_run)

    on_exit(fn ->
      reset_readiness()
      clear_default_risk_state()
      Application.put_env(:bitflyer, :trade_mode, previous_mode)
    end)

    :ok
  end

  test "resume clears halt and marks ready after successful re-reconcile" do
    assert :ok = Bitflyer.Risk.Circuit.open(:reconcile_mismatch)
    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert {:ok, risk} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()

    assert risk.halted

    # 永続 halt があると通常突合は失敗する
    assert {:error, :reconcile_mismatch, %{source: :risk_state}} =
             Reconcile.run(trade_mode: :dry_run, exchange: EmptyExchange)

    assert :ok = Resume.run(trade_mode: :dry_run, exchange: EmptyExchange)
    assert Readiness.get() == :ready

    assert {:ok, %RiskState{halted: false}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "resume keeps halt when re-reconcile fails" do
    previous = Application.get_env(:bitflyer, :trade_mode)
    Application.put_env(:bitflyer, :trade_mode, :live)

    on_exit(fn ->
      Application.put_env(:bitflyer, :trade_mode, previous)
    end)

    assert :ok = Bitflyer.Risk.Circuit.open(:reconcile_mismatch)

    assert {:error, :exchange_unavailable, _} =
             Resume.run(trade_mode: :live, exchange: UnavailableExchange)

    assert Readiness.get() == {:halted, :reconcile_mismatch}

    assert {:ok, %RiskState{halted: true}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "resume rejects when not halted" do
    assert Readiness.mark_ready() == :ok
    assert {:error, :not_halted} = Resume.run(trade_mode: :dry_run, exchange: EmptyExchange)
    assert Readiness.get() == :ready
  end

  test "System.resume delegates to Startup.Resume" do
    assert :ok = Bitflyer.Risk.Circuit.open(:risk_halted)
    assert :ok = Bitflyer.System.resume(trade_mode: :dry_run, exchange: EmptyExchange)
    assert Readiness.ready?()
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, %RiskState{} = risk} ->
        _ =
          risk
          |> Ash.Changeset.for_update(:update, %{
            halted: false,
            reason: nil,
            halted_at: nil
          })
          |> Ash.update()

        :ok

      {:ok, nil} ->
        :ok

      {:error, _} ->
        :ok
    end
  end
end
