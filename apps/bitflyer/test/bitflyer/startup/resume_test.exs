defmodule Bitflyer.Startup.ResumeTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Startup.{Reconcile, Resume}
  alias Bitflyer.Trading.RiskState

  defmodule EmptyExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot do
      {:ok, %{positions: [], balances: [], open_orders: []}}
    end

    @impl true
    def place_order(_request), do: {:error, :not_used_in_resume}
  end

  defmodule UnavailableExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

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

  test "System.halt_trading does not overwrite existing halt reason" do
    assert :ok = Bitflyer.Risk.Circuit.open(:reconcile_mismatch)
    assert :ok = Bitflyer.System.halt_trading(operator: "test")
    assert Readiness.get() == {:halted, :reconcile_mismatch}
  end

  test "System.halt_trading persists when ETS halted but RiskState is clear" do
    assert :ok = Readiness.halt(:persist_failed)
    clear_default_risk_state()
    assert Bitflyer.Risk.Circuit.persisted_halt_reason() == :clear

    assert :ok = Bitflyer.System.halt_trading(operator: "heal-persist")
    assert Readiness.get() == {:halted, :persist_failed}

    assert {:ok, %RiskState{halted: true, reason: "persist_failed"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "System.halt_trading does not overwrite persisted RiskState reason" do
    assert Readiness.mark_ready() == :ok

    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "submission_unknown",
               halted_at: halted_at
             })
             |> Ash.create()

    assert :ok = Bitflyer.System.halt_trading(operator: "mix.bitflyer.halt")
    assert Readiness.get() == {:halted, :submission_unknown}

    assert {:ok, %RiskState{halted: true, reason: "submission_unknown"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "System.halt_trading syncs persist_failed and daily_loss_exceeded without collapsing" do
    for reason <- ["persist_failed", "daily_loss_exceeded"] do
      reset_readiness()
      clear_default_risk_state()

      halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _} =
               RiskState
               |> Ash.Changeset.for_create(:create, %{
                 name: "default",
                 halted: true,
                 reason: reason,
                 halted_at: halted_at
               })
               |> Ash.create(
                 upsert?: true,
                 upsert_identity: :unique_name,
                 upsert_fields: [:halted, :reason, :halted_at, :updated_at]
               )

      assert :ok = Bitflyer.System.halt_trading(operator: "mix.bitflyer.halt")
      assert Readiness.get() == {:halted, String.to_existing_atom(reason)}
    end
  end

  test "System.halt_trading opens circuit when not halted" do
    assert Readiness.mark_ready() == :ok
    assert :ok = Bitflyer.System.halt_trading(operator: "test")
    assert Readiness.get() == {:halted, :manual_halt}
  end

  test "Release.halt_trading returns ok without CaseClauseError" do
    assert :ok = Bitflyer.Release.halt_trading(operator: "test-release")
    assert match?({:halted, _}, Readiness.get())
  end

  test "Release.halt_trading_result accepts persist_failed from System" do
    assert :ok = Bitflyer.Release.halt_trading_result({:ok, :persist_failed})
    assert :ok = Bitflyer.Release.halt_trading_result(:ok)

    assert_raise RuntimeError, ~r/halt_trading failed/, fn ->
      Bitflyer.Release.halt_trading_result({:error, :boom})
    end
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
