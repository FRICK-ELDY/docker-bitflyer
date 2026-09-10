defmodule Bitflyer.Risk.CircuitSyncTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Readiness
  alias Bitflyer.Risk.CircuitSync
  alias Bitflyer.Trading.RiskState

  setup do
    reset_readiness()
    clear_default_risk_state()

    on_exit(fn ->
      reset_readiness()
      clear_default_risk_state()
    end)

    :ok
  end

  test "sync_now halts Readiness from persisted RiskState without overwriting reason" do
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
             |> Ash.create(
               upsert?: true,
               upsert_identity: :unique_name,
               upsert_fields: [:halted, :reason, :halted_at, :updated_at]
             )

    assert {:ok, :synced} = CircuitSync.sync_now()
    assert Readiness.get() == {:halted, :submission_unknown}

    assert :ok = CircuitSync.sync_now()
    assert Readiness.get() == {:halted, :submission_unknown}
  end

  test "sync_now does not clear ETS halt when RiskState is clear" do
    assert :ok = Readiness.halt(:manual_halt)
    assert :ok = CircuitSync.sync_now()
    assert Readiness.get() == {:halted, :manual_halt}
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
