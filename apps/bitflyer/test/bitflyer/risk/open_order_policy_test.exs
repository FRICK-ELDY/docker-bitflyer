defmodule Bitflyer.Risk.OpenOrderPolicyTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.OrderExecutor
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Risk.OpenOrderPolicy
  alias Bitflyer.Risk.OpenOrderPolicy.HaltCancelGate
  alias Bitflyer.Trading.Order

  defmodule SpyCancelExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(request) do
      Agent.update(__MODULE__.Calls, fn calls -> [request | calls] end)
      :ok
    end

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      {:ok,
       %{
         exchange_order_id: id,
         product_code: "BTC_JPY",
         side: :buy,
         size: Decimal.new("0.01"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :canceled
       }}
    end

    def calls, do: Agent.get(__MODULE__.Calls, &Enum.reverse/1)
  end

  defmodule SlowCancelExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(request) do
      send(Process.get(:open_order_policy_test_pid), {:cancel_started, request})

      receive do
        :continue -> :ok
      after
        5_000 -> :ok
      end
    end

    @impl true
    def fetch_order(%{exchange_order_id: id}) do
      {:ok,
       %{
         exchange_order_id: id,
         product_code: "BTC_JPY",
         side: :buy,
         size: Decimal.new("0.01"),
         filled_size: Decimal.new("0"),
         average_price: nil,
         status: :canceled
       }}
    end
  end

  defmodule CountingFailExchange do
    @behaviour Bitflyer.Exchange.Client
    use Bitflyer.TestSupport.ExchangeClientStubs

    @impl true
    def fetch_reconcile_snapshot, do: {:ok, %{positions: [], balances: [], open_orders: []}}

    @impl true
    def place_order(_), do: {:error, :not_used}

    @impl true
    def cancel_order(_request) do
      Agent.update(__MODULE__.Count, &(&1 + 1))
      {:error, :forced_cancel_failure}
    end

    @impl true
    def fetch_order(_), do: {:error, :not_used}

    def count, do: Agent.get(__MODULE__.Count, & &1)
  end

  setup do
    reset_readiness()
    clear_default_risk_state()
    OpenOrderPolicy.reset_halt_cancel_gate!()
    previous = Application.get_env(:bitflyer, OpenOrderPolicy, [])

    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      Keyword.merge(previous,
        max_open_age_ms: :infinity,
        async_default: false,
        halt_cancel_retry_backoff_ms: 30_000,
        cancel_on_halt: %{
          manual_halt: true,
          submission_unknown: false,
          reconcile_mismatch: false
        }
      )
    )

    start_supervised!(%{
      id: SpyCancelExchange.Calls,
      start: {Agent, :start_link, [fn -> [] end, [name: SpyCancelExchange.Calls]]}
    })

    on_exit(fn ->
      Application.put_env(:bitflyer, OpenOrderPolicy, previous)
      OpenOrderPolicy.reset_halt_cancel_gate!()
      reset_readiness()
      clear_default_risk_state()
    end)

    :ok
  end

  test "cancel_on_halt? follows config map with false default" do
    assert OpenOrderPolicy.cancel_on_halt?(:manual_halt)
    refute OpenOrderPolicy.cancel_on_halt?(:submission_unknown)
    refute OpenOrderPolicy.cancel_on_halt?(:reconcile_mismatch)
    refute OpenOrderPolicy.cancel_on_halt?(:unknown_reason_xyz)
  end

  test "manual_halt cancels open live orders synchronously" do
    {:ok, order} = create_live_open("halt-cancel-1", "JRF-halt-cancel-1")
    order_id = order.id

    assert :ok =
             Risk.open_circuit(:manual_halt,
               async: false,
               exchange: SpyCancelExchange
             )

    assert Readiness.get() == {:halted, :manual_halt}
    assert [%{exchange_order_id: "JRF-halt-cancel-1"}] = SpyCancelExchange.calls()

    {:ok, reloaded} =
      Order
      |> Ash.Query.filter(id == ^order_id)
      |> Ash.read_one()

    assert reloaded.status == :cancelled
  end

  test "submission_unknown halt does not cancel open orders" do
    {:ok, _order} = create_live_open("halt-leave-1", "JRF-halt-leave-1")

    assert :ok =
             Risk.open_circuit(:submission_unknown,
               async: false,
               exchange: SpyCancelExchange
             )

    assert SpyCancelExchange.calls() == []

    {:ok, [still_open]} =
      OpenOrderPolicy.list_open_orders(trade_modes: [:live])

    assert still_open.internal_order_id == "halt-leave-1"
  end

  test "cancel_aged_opens cancels only older than threshold" do
    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      Keyword.put(Application.get_env(:bitflyer, OpenOrderPolicy, []), :max_open_age_ms, 60_000)
    )

    {:ok, old} = create_live_open("age-old-1", "JRF-age-old-1")
    {:ok, fresh} = create_live_open("age-fresh-1", "JRF-age-fresh-1")
    old_id = old.id
    fresh_id = fresh.id

    old_at =
      DateTime.utc_now()
      |> DateTime.add(-120, :second)
      |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             old
             |> Ash.Changeset.for_update(:update, %{})
             |> Ash.Changeset.force_change_attribute(:inserted_at, old_at)
             |> Ash.update()

    assert {:ok, results} =
             OpenOrderPolicy.cancel_aged_opens(exchange: SpyCancelExchange)

    ids = Enum.map(results, fn {id, _} -> id end)
    assert "age-old-1" in ids
    refute "age-fresh-1" in ids

    {:ok, reloaded_old} = Order |> Ash.Query.filter(id == ^old_id) |> Ash.read_one()
    {:ok, reloaded_fresh} = Order |> Ash.Query.filter(id == ^fresh_id) |> Ash.read_one()
    assert reloaded_old.status == :cancelled
    assert reloaded_fresh.status == :pending
  end

  test "cancel_open_orders is no-op when none open" do
    assert {:ok, []} = OrderExecutor.cancel_open_orders(trade_modes: [:live])
  end

  test "CircuitSync re-applies cancel-all for persisted cancel_on_halt reason" do
    {:ok, order} = create_live_open("sync-cancel-1", "JRF-sync-cancel-1")
    order_id = order.id

    # Circuit.open を通さず DB だけ halt（再起動後の永続状態を模擬）
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Bitflyer.Trading.RiskState
             |> Ash.Changeset.for_create(:create, %{
               name: "default",
               halted: true,
               reason: "manual_halt",
               halted_at: halted_at
             })
             |> Ash.create(
               upsert?: true,
               upsert_identity: :unique_name,
               upsert_fields: [:halted, :reason, :halted_at, :updated_at]
             )

    assert Readiness.mark_ready() == :ok

    previous_policy = Application.get_env(:bitflyer, OpenOrderPolicy, [])
    previous_client = Application.get_env(:bitflyer, :exchange_client)

    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      Keyword.merge(previous_policy,
        cancel_on_halt: %{manual_halt: true},
        async_default: false
      )
    )

    Application.put_env(:bitflyer, :exchange_client, SpyCancelExchange)

    on_exit(fn ->
      Application.put_env(:bitflyer, :exchange_client, previous_client)
    end)

    assert {:ok, :synced} = Bitflyer.Risk.CircuitSync.sync_now()
    assert Readiness.get() == {:halted, :manual_halt}
    assert [%{exchange_order_id: "JRF-sync-cancel-1"}] = SpyCancelExchange.calls()

    {:ok, reloaded} = Order |> Ash.Query.filter(id == ^order_id) |> Ash.read_one()
    assert reloaded.status == :cancelled
  end

  test "ensure_halt_cancels while already halted recovers leftover opens" do
    {:ok, order} = create_live_open("ensure-left-1", "JRF-ensure-left-1")
    order_id = order.id

    assert :ok = Readiness.halt(:manual_halt)

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               exchange: SpyCancelExchange
             )

    assert [%{exchange_order_id: "JRF-ensure-left-1"}] = SpyCancelExchange.calls()
    {:ok, reloaded} = Order |> Ash.Query.filter(id == ^order_id) |> Ash.read_one()
    assert reloaded.status == :cancelled
  end

  test "ensure_halt_cancels no-ops when policy is false even if opens exist" do
    {:ok, _} = create_live_open("ensure-skip-1", "JRF-ensure-skip-1")
    assert :ok = Readiness.halt(:submission_unknown)

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:submission_unknown,
               async: false,
               exchange: SpyCancelExchange
             )

    assert SpyCancelExchange.calls() == []
  end

  test "ensure_halt_cancels skips while in-flight (no stampede)" do
    test_pid = self()
    {:ok, _} = create_live_open("stampede-1", "JRF-stampede-1")

    task =
      Task.async(fn ->
        Process.put(:open_order_policy_test_pid, test_pid)

        OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
          async: false,
          exchange: SlowCancelExchange
        )
      end)

    assert_receive {:cancel_started, %{exchange_order_id: "JRF-stampede-1"}}, 1_000

    # 1 本目の cancel 中に 2 本目は in-flight でスキップ
    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               force: true,
               exchange: SlowCancelExchange
             )

    refute_receive {:cancel_started, _}, 100

    send(task.pid, :continue)
    assert :ok = Task.await(task)
  end

  test "ensure_halt_cancels backs off after failed cancel until force" do
    start_supervised!(%{
      id: CountingFailExchange.Count,
      start: {Agent, :start_link, [fn -> 0 end, [name: CountingFailExchange.Count]]}
    })

    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      Keyword.put(
        Application.get_env(:bitflyer, OpenOrderPolicy, []),
        :halt_cancel_retry_backoff_ms,
        60_000
      )
    )

    {:ok, _} = create_live_open("backoff-1", "JRF-backoff-1")

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               exchange: CountingFailExchange
             )

    assert CountingFailExchange.count() == 1

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               exchange: CountingFailExchange
             )

    assert CountingFailExchange.count() == 1

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               force: true,
               exchange: CountingFailExchange
             )

    assert CountingFailExchange.count() == 2
  end

  test "HaltCancelGate ETS survives caller process exit (backoff retained)" do
    start_supervised!(%{
      id: CountingFailExchange.Count,
      start: {Agent, :start_link, [fn -> 0 end, [name: CountingFailExchange.Count]]}
    })

    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      Keyword.put(
        Application.get_env(:bitflyer, OpenOrderPolicy, []),
        :halt_cancel_retry_backoff_ms,
        60_000
      )
    )

    {:ok, _} = create_live_open("gate-owner-1", "JRF-gate-owner-1")

    gate_pid = Process.whereis(HaltCancelGate)
    assert is_pid(gate_pid)
    table = HaltCancelGate.table_name()
    assert :ets.info(table, :owner) == gate_pid

    parent = self()

    caller =
      spawn(fn ->
        OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
          async: false,
          exchange: CountingFailExchange
        )

        send(parent, :caller_done)
      end)

    caller_ref = Process.monitor(caller)
    assert_receive :caller_done, 1_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000

    # 呼び出し元終了後も gate ETS と backoff は GenServer 所有のまま残る
    assert Process.alive?(gate_pid)
    assert :ets.info(table, :owner) == gate_pid
    assert CountingFailExchange.count() == 1

    assert :ok =
             OpenOrderPolicy.ensure_halt_cancels(:manual_halt,
               async: false,
               exchange: CountingFailExchange
             )

    assert CountingFailExchange.count() == 1
  end

  defp create_live_open(internal_id, exchange_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{
      internal_order_id: internal_id,
      exchange_order_id: exchange_id,
      product_code: "BTC_JPY",
      side: :buy,
      status: :pending,
      order_type: :limit,
      price: Decimal.new("5000000"),
      size: Decimal.new("0.01"),
      filled_size: Decimal.new("0"),
      filled_notional: Decimal.new("0"),
      trade_mode: :live
    })
    |> Ash.create()
  end

  defp clear_default_risk_state do
    case Bitflyer.Trading.RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, %Bitflyer.Trading.RiskState{} = risk} ->
        _ =
          risk
          |> Ash.Changeset.for_update(:update, %{
            halted: false,
            reason: nil,
            halted_at: nil
          })
          |> Ash.update()

        :ok

      _ ->
        :ok
    end
  end
end
