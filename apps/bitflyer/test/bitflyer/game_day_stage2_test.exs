defmodule Bitflyer.GameDayStage2Test do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.DailyLossHelper
  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper
  import ExUnit.CaptureIO

  alias Bitflyer.Readiness
  alias Bitflyer.Repo
  alias Bitflyer.Risk.{BalanceCache, CircuitSync, DrainHalt, OpenOrderPolicy}
  alias Bitflyer.Startup.Reconciler
  alias Bitflyer.Trading.{BalanceSnapshot, RiskState}
  alias Mix.Tasks.Bitflyer.GameDayStage2

  setup do
    reset_readiness()
    reset_daily_loss()
    reset_market_data_cache()
    clear_default_risk_state()

    path =
      Path.join(System.tmp_dir!(), "bitflyer-gameday-drain-#{System.unique_integer([:positive])}")

    previous = %{
      drain: Application.get_env(:bitflyer, DrainHalt),
      mode: Application.get_env(:bitflyer, :trade_mode, :dry_run),
      reconciler: Application.get_env(:bitflyer, Reconciler),
      circuit_sync: Application.get_env(:bitflyer, CircuitSync),
      policy: Application.get_env(:bitflyer, OpenOrderPolicy)
    }

    Application.put_env(:bitflyer, DrainHalt, path: path)

    on_exit(fn ->
      File.rm(path)
      restore_env(DrainHalt, previous.drain)
      restore_env(Reconciler, previous.reconciler)
      restore_env(CircuitSync, previous.circuit_sync)
      restore_env(OpenOrderPolicy, previous.policy)
      Application.put_env(:bitflyer, :trade_mode, previous.mode)
      clear_default_risk_state()
      reset_readiness()
      reset_daily_loss()
      reset_market_data_cache()
    end)

    :ok
  end

  test "run aborts a persisted halt before starting the supervision tree" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    risk = persist_halt!(:manual_halt)

    output =
      capture_io(:stderr, fn ->
        result =
          GameDayStage2.run([], start: fn -> send(self(), :started) end, halt: halt_fun())

        send(self(), {:result, result})
      end)

    assert_received {:result, :aborted}
    refute_received :started
    assert output =~ "reason=manual_halt"
    assert Readiness.get() == :not_ready

    assert {:ok, %RiskState{halted: true, reason: "manual_halt", halted_at: halted_at}} =
             read_default_risk_state()

    assert DateTime.compare(halted_at, risk.halted_at) == :eq
  end

  test "a failed RiskState read is unsynced and run does not start" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    before = paper_snapshot_count()

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE risk_states RENAME TO risk_states_hidden_gameday"
    )

    assert GameDayStage2.persisted_start_block() == :unsynced

    output =
      capture_io(:stderr, fn ->
        result =
          GameDayStage2.run([], start: fn -> send(self(), :started) end, halt: halt_fun())

        send(self(), {:result, result})
      end)

    assert_received {:result, :aborted}
    refute_received :started
    assert output =~ "unsynced"
    assert paper_snapshot_count() == before
    assert Readiness.get() == :not_ready
  end

  test "application reconciler child boots only when env boot? is true" do
    spec = Bitflyer.Application.reconciler_child_spec()
    assert {Reconciler, :start_link, [[]]} = spec.start

    risk = persist_halt!(:manual_halt)
    set_boot!(false)

    with_application_reconciler(fn ->
      assert Reconciler.booted?() == false
    end)

    assert {:ok, %RiskState{halted_at: halted_at}} = read_default_risk_state()
    assert DateTime.compare(halted_at, risk.halted_at) == :eq

    set_boot!(true)

    with_application_reconciler(fn ->
      assert Reconciler.booted?() == true
    end)

    assert {:ok, %RiskState{halted: true, reason: "manual_halt", halted_at: rewritten}} =
             read_default_risk_state()

    assert DateTime.compare(rewritten, risk.halted_at) == :gt
  end

  test "order gate refuses a persisted halt while this BEAM is still ready" do
    assert Readiness.mark_ready() == :ok
    risk = persist_halt!(:manual_halt)

    assert GameDayStage2.order_gate() == {:error, {:persisted_halt, :manual_halt}}
    assert Readiness.get() == :ready

    assert {:ok, %RiskState{halted_at: halted_at}} = read_default_risk_state()
    assert DateTime.compare(halted_at, risk.halted_at) == :eq
  end

  test "run refuses a non-paper mode before app start" do
    Application.put_env(:bitflyer, :trade_mode, :live)

    output =
      capture_io(:stderr, fn ->
        result =
          GameDayStage2.run([], start: fn -> send(self(), :started) end, halt: halt_fun())

        send(self(), {:result, result})
      end)

    assert_received {:result, :aborted}
    refute_received :started
    assert output =~ "TRADE_MODE must be paper"
  end

  test "paper reconcile stays not ready until the balance cache is synced" do
    Application.put_env(:bitflyer, :trade_mode, :paper)
    assert Readiness.get() == :not_ready

    assert {:error, {:not_ready, :not_ready}} = GameDayStage2.require_ready_via_reconcile()
    assert Readiness.get() == :not_ready

    :ok = seed_paper_tips()
    assert BalanceCache.refresh(:paper) == :ok
    assert put_fresh_ticker({:ticker, "BTC_JPY"}, Decimal.new("6000000")) == :ok

    assert GameDayStage2.require_ready_via_reconcile() == :ok
    assert Readiness.get() == :ready
  end

  defp halt_fun, do: fn 1 -> :aborted end

  defp set_boot!(boot?) do
    reconciler = Application.get_env(:bitflyer, Reconciler, [])
    Application.put_env(:bitflyer, Reconciler, Keyword.put(reconciler, :boot?, boot?))
  end

  defp with_application_reconciler(fun) do
    stop_running_reconciler!()
    spec = Bitflyer.Application.reconciler_child_spec()
    {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)

    try do
      fun.()
    after
      # 再起動した常駐子が boot?: true のまま次のテストへ突合を流さない。
      set_boot!(false)
      Supervisor.stop(sup)
      restart_app_reconciler!()
    end
  end

  defp stop_running_reconciler! do
    case Supervisor.terminate_child(Bitflyer.Supervisor, Reconciler) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(Bitflyer.Supervisor, Reconciler) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restart_app_reconciler! do
    spec = Bitflyer.Application.reconciler_child_spec()

    case Supervisor.start_child(Bitflyer.Supervisor, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp persist_halt!(reason) when is_atom(reason) do
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, risk} =
             RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: Atom.to_string(reason),
               halted_at: halted_at
             })
             |> Ash.create(
               upsert?: true,
               upsert_identity: :unique_name,
               upsert_fields: [:halted, :reason, :halted_at, :updated_at]
             )

    risk
  end

  defp seed_paper_tips do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {currency, amount} <- [{"JPY", "1000000"}, {"BTC", "0"}] do
      amt = Decimal.new(amount)

      BalanceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        currency: currency,
        amount: amt,
        available: amt,
        captured_at: captured_at,
        trade_mode: :paper
      })
      |> Ash.create!()
    end

    :ok
  end

  defp paper_snapshot_count do
    BalanceSnapshot
    |> Ash.Query.filter(trade_mode == :paper)
    |> Ash.read!()
    |> length()
  end

  defp read_default_risk_state do
    RiskState
    |> Ash.Query.filter(name == "default")
    |> Ash.read_one()
  end

  defp clear_default_risk_state do
    case read_default_risk_state() do
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

  defp restore_env(key, nil), do: Application.delete_env(:bitflyer, key)
  defp restore_env(key, value), do: Application.put_env(:bitflyer, key, value)
end
