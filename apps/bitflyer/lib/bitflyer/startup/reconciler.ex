defmodule Bitflyer.Startup.Reconciler do
  @moduledoc """
  起動時・定期の突合を実行し、Ready 状態を更新する。

  - 成功 → `Readiness.mark_ready/0`（halted 中は拒否される）
  - 失敗 → `Readiness.halt/1` と RiskState 永続化。Ready にはしない

  起動時の重い突合は `handle_continue/2` で行い、`init/1` はすぐ返す。
  テストでは `boot?: false` にして明示的に `run_now/0` する
  （SQL Sandbox との所有権衝突を避ける）。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Startup.Reconcile
  alias Bitflyer.Trading.RiskState

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  いま突合を実行する（テスト・手動再突合用）。
  """
  @spec run_now(GenServer.server()) :: :ok | {:error, atom()}
  def run_now(server \\ @name) do
    GenServer.call(server, :run_now, 30_000)
  end

  @doc """
  起動突合が終わっているか（テスト用）。
  """
  @spec booted?(GenServer.server()) :: boolean()
  def booted?(server \\ @name) do
    GenServer.call(server, :booted?)
  end

  @impl true
  def init(opts) do
    env = Application.get_env(:bitflyer, __MODULE__, [])

    state = %{
      boot?: Keyword.get(opts, :boot?, Keyword.get(env, :boot?, true)),
      interval_ms: Keyword.get(opts, :interval_ms, Keyword.get(env, :interval_ms, 60_000)),
      exchange: Keyword.get(opts, :exchange, Bitflyer.Exchange),
      readiness: Keyword.get(opts, :readiness, Bitflyer.Readiness),
      booted?: false,
      timer_ref: nil
    }

    if state.boot? do
      {:ok, state, {:continue, :boot_reconcile}}
    else
      {:ok, schedule_periodic(state)}
    end
  end

  @impl true
  def handle_continue(:boot_reconcile, state) do
    state =
      state
      |> then(&apply_result(run_reconcile(&1), &1))
      |> Map.put(:booted?, true)
      |> schedule_periodic()

    {:noreply, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    result = run_reconcile(state)
    state = result |> apply_result(state) |> Map.put(:booted?, true)

    reply =
      case result do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end

    {:reply, reply, schedule_periodic(state)}
  end

  def handle_call(:booted?, _from, state) do
    {:reply, state.booted?, state}
  end

  @impl true
  def handle_info(:periodic_reconcile, state) do
    state = apply_result(run_reconcile(state), state)
    {:noreply, schedule_periodic(state)}
  end

  defp run_reconcile(state) do
    Reconcile.run(trade_mode: Bitflyer.TradeMode.current(), exchange: state.exchange)
  end

  defp apply_result({:ok, _internal}, state) do
    case state.readiness.get() do
      {:halted, _} ->
        # 手動 clear_halt 待ち。自動では Ready に戻さない。
        state

      :ready ->
        case ensure_risk_cleared() do
          :ok ->
            state

          {:error, error} ->
            Bitflyer.Telemetry.log(
              :error,
              "Failed to ensure risk cleared while ready: #{inspect(error)}",
              %{reason: :risk_persist_failed, trade_mode: Bitflyer.TradeMode.current()}
            )

            state
        end

      :not_ready ->
        case ensure_risk_cleared() do
          :ok ->
            case state.readiness.mark_ready() do
              :ok -> state
              {:error, _} -> state
            end

          {:error, error} ->
            Bitflyer.Telemetry.log(
              :error,
              "Failed to ensure risk cleared, keeping not_ready: #{inspect(error)}",
              %{reason: :risk_persist_failed, trade_mode: Bitflyer.TradeMode.current()}
            )

            state
        end
    end
  end

  defp apply_result({:error, reason, details}, state) do
    Bitflyer.Telemetry.execute(
      :reconcile_mismatch,
      %{count: 1},
      Map.merge(
        %{
          reason: reason,
          trade_mode: Bitflyer.TradeMode.current()
        },
        Map.take(details, [:product_code, :currency, :kind])
      )
    )

    Bitflyer.Telemetry.log(:warning, "boot reconcile halted", %{
      reason: reason,
      trade_mode: Bitflyer.TradeMode.current()
    })

    # 即時にメモリ上を止め、その後 RiskState を永続化する（persist 失敗でも発注は閉じる）
    _ = state.readiness.halt(reason)

    case persist_risk_halt(reason) do
      :ok ->
        :ok

      {:error, error} ->
        Bitflyer.Telemetry.log(
          :error,
          "Failed to persist risk halt after readiness halt: #{inspect(error)}",
          %{reason: reason, trade_mode: Bitflyer.TradeMode.current()}
        )
    end

    state
  end

  defp ensure_risk_cleared do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} ->
        case RiskState
             |> Ash.Changeset.for_create(:create, %{name: "default", halted: false})
             |> Ash.create() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:ok, %RiskState{halted: false}} ->
        :ok

      {:ok, %RiskState{} = risk} ->
        case risk
             |> Ash.Changeset.for_update(:update, %{
               halted: false,
               reason: nil,
               halted_at: nil
             })
             |> Ash.update() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp persist_risk_halt(reason) do
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      name: "default",
      halted: true,
      reason: Reconcile.reason_to_string(reason),
      halted_at: halted_at
    }

    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} ->
        case RiskState
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:ok, %RiskState{} = risk} ->
        case risk
             |> Ash.Changeset.for_update(:update, Map.take(attrs, [:halted, :reason, :halted_at]))
             |> Ash.update() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp schedule_periodic(%{interval_ms: :infinity} = state) do
    cancel_timer(state)
  end

  defp schedule_periodic(%{interval_ms: ms} = state) when is_integer(ms) and ms > 0 do
    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :periodic_reconcile, ms)
    Map.put(state, :timer_ref, timer_ref)
  end

  defp schedule_periodic(state), do: cancel_timer(state)

  defp cancel_timer(%{timer_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp cancel_timer(state), do: state
end
