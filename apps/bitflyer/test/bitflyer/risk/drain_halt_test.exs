defmodule Bitflyer.Risk.DrainHaltTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.DrainHalt
  alias Bitflyer.Startup.Reconciler
  alias Bitflyer.Trading.RiskState

  setup do
    reset_readiness()
    clear_halted_risk_state()

    path =
      Path.join(System.tmp_dir!(), "bitflyer-drain-halt-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:bitflyer, DrainHalt)
    Application.put_env(:bitflyer, DrainHalt, path: path)

    on_exit(fn ->
      File.rm(path)

      case previous do
        nil -> Application.delete_env(:bitflyer, DrainHalt)
        value -> Application.put_env(:bitflyer, DrainHalt, value)
      end

      _ = Risk.clear_circuit()
      reset_readiness()
    end)

    :ok
  end

  test "a failed RiskState write still halts the next boot" do
    assert :marker_only =
             DrainHalt.record(open_circuit: fn _reason -> {:error, :db_down} end)

    assert File.exists?(DrainHalt.path())
    assert Readiness.get() == {:halted, :persist_failed}
    assert risk_state_clear?()

    # プロセス再起動。メモリの halt は消え、印と空の RiskState だけが残る。
    assert Readiness.clear_halt() == :ok
    assert Readiness.get() == :not_ready

    assert Reconciler.run_now() == :ok
    assert Readiness.get() == {:halted, :persist_failed}
    refute File.exists?(DrainHalt.path())

    assert {:ok, %RiskState{halted: true, reason: "persist_failed"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "boot keeps a persisted persist_failed halt after the marker is gone" do
    assert :persisted = DrainHalt.record()
    refute File.exists?(DrainHalt.path())
    assert Readiness.get() == {:halted, :persist_failed}

    # 印を消した再起動。ETS は not_ready、RiskState の halt だけが残る。
    assert Readiness.clear_halt() == :ok
    assert Readiness.get() == :not_ready

    assert {:error, :persist_failed} = Reconciler.run_now()
    assert Readiness.get() == {:halted, :persist_failed}

    assert {:ok, %RiskState{halted: true, reason: "persist_failed"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "clear_marker reports a failed delete and treats a missing file as gone" do
    File.mkdir_p!(DrainHalt.path())

    assert {:error, _} = DrainHalt.clear_marker()
    assert File.exists?(DrainHalt.path())

    File.rm_rf!(DrainHalt.path())
    assert :ok = DrainHalt.clear_marker()
  end

  defp risk_state_clear? do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} -> true
      {:ok, %RiskState{halted: false}} -> true
      _ -> false
    end
  end

  defp clear_halted_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, %RiskState{halted: true} = risk} -> Ash.destroy!(risk)
      _ -> :ok
    end

    :ok
  end
end
