defmodule Bitflyer.Risk.CircuitSync do
  @moduledoc """
  永続 RiskState の halt を常駐 BEAM の Readiness（ETS）へ同期する。

  発注ホットパス（`Risk.authorize`）は ETS のみを見る。別 BEAM の
  `mix bitflyer.halt` で DB だけ更新された場合、本プロセスが周期的に
  ETS を halt し fail-closed にする（即停止の正本は StatusLive / Release rpc）。

  永続側が clear でも ETS halt は自動解除しない（resume 手順を要する）。

  永続 halt を ETS に載せた／既に halted のとき、`OpenOrderPolicy.ensure_halt_cancels/2`
  で理由別 cancel-all を再実行する（再起動耐性）。周期 tick の再試行は
  OpenOrderPolicy 側の in-flight／バックオフで背圧する。
  """

  use GenServer

  alias Bitflyer.Risk.Circuit
  alias Bitflyer.Readiness

  @default_interval_ms 2_000

  @doc """
  今すぐ 1 回だけ DB→ETS 同期する（テスト／運用診断用）。
  """
  @spec sync_now(GenServer.server()) :: :ok | {:ok, :synced} | {:error, term()}
  def sync_now(server \\ __MODULE__) do
    GenServer.call(server, :sync_now)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:bitflyer, __MODULE__, [])
        |> Keyword.get(:interval_ms, @default_interval_ms)
      end)

    state = %{interval_ms: interval}
    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {:reply, do_sync(), state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = do_sync()
    {:noreply, schedule_tick(state)}
  end

  defp schedule_tick(%{interval_ms: :disabled} = state), do: state

  defp schedule_tick(%{interval_ms: ms} = state) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
    state
  end

  defp schedule_tick(state), do: state

  defp do_sync do
    case Circuit.persisted_halt_reason() do
      {:halted, reason} ->
        case Readiness.get() do
          {:halted, _} ->
            # 未完了 cancel の再試行（in-flight / backoff は OpenOrderPolicy 側）
            _ = Bitflyer.Risk.OpenOrderPolicy.ensure_halt_cancels(reason)
            :ok

          _ ->
            case Readiness.halt(reason) do
              :ok ->
                Bitflyer.Telemetry.log(
                  :warning,
                  "circuit sync: halted from persisted RiskState",
                  %{
                    reason: reason,
                    trade_mode: Bitflyer.TradeMode.current()
                  }
                )

                _ =
                  Bitflyer.Risk.OpenOrderPolicy.ensure_halt_cancels(reason, force: true)

                {:ok, :synced}

              other ->
                other
            end
        end

      :clear ->
        :ok

      :unsynced ->
        Bitflyer.Telemetry.log(
          :error,
          "circuit sync: failed to read persisted RiskState (unsynced)",
          %{trade_mode: Bitflyer.TradeMode.current()}
        )

        {:error, :unsynced}
    end
  end
end
