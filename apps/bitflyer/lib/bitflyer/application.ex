defmodule Bitflyer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Supervisor は子を直列停止する。1 子あたりの上限を短くし、
  # Compose stop_grace_period（45s）内に Repo 等の後続クリーンアップ余地を残す。
  # 発注停止と in-flight drain は prep_stop で行う（子 shutdown より前）。
  @child_shutdown_ms 5_000

  @impl true
  def start(_type, _args) do
    children =
      [
        Bitflyer.Repo,
        Bitflyer.Readiness,
        Bitflyer.MarketData.Cache,
        Bitflyer.Risk.OrderRate,
        Bitflyer.Risk.FailureRate,
        Bitflyer.Risk.AuthorizedOrder,
        Bitflyer.OrderExecutor.InFlight,
        Bitflyer.Risk.DailyLoss,
        Bitflyer.Risk.BalanceCache,
        Supervisor.child_spec(
          {Task.Supervisor, name: Bitflyer.MarketData.TaskSupervisor},
          shutdown: @child_shutdown_ms
        ),
        Supervisor.child_spec(Bitflyer.Startup.Reconciler, shutdown: @child_shutdown_ms),
        # 発注経路の兄弟。通知失敗・クラッシュで取引木を巻き込まない。
        Supervisor.child_spec(Bitflyer.Observe.Discord, shutdown: @child_shutdown_ms)
      ] ++ market_data_feed()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitflyer.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # GenServer 再起動のたびに attach/detach しない（静的 ID で一度だけ）。
        :ok = Bitflyer.Observe.Discord.install_telemetry()
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  アプリケーション停止前に発注ゲートを閉じ、進行中 submit/cancel を drain する。

  OTP コールバックは `prep_stop/1`。順序:
  1. Discord telemetry 解除
  2. `Readiness.mark_not_ready_safe/0`（新規 submit 拒否。halted は維持）
  3. `InFlight.drain/1`（進行中完了待ち。timeout 時は pending を submission_unknown 化）
  """
  @impl true
  def prep_stop(state) do
    _ = Bitflyer.Observe.Discord.uninstall_telemetry()

    previous =
      try do
        Bitflyer.Readiness.get()
      catch
        :exit, _ -> :not_ready
      end

    Bitflyer.Telemetry.log(:info, "prep_stop: closing order gate", %{
      readiness: Bitflyer.Readiness.format(previous),
      reason: :application_stop
    })

    _ = Bitflyer.Readiness.mark_not_ready_safe()

    drain_timeout_ms = Bitflyer.OrderExecutor.InFlight.drain_timeout_ms()

    Bitflyer.Telemetry.log(:info, "prep_stop: draining in-flight submissions", %{
      reason: :application_stop,
      timeout_ms: drain_timeout_ms
    })

    case Bitflyer.OrderExecutor.InFlight.drain(timeout_ms: drain_timeout_ms) do
      :ok ->
        Bitflyer.Telemetry.log(:info, "prep_stop: in-flight drain complete", %{
          reason: :application_stop
        })

      {:error, :timeout, leftovers} ->
        Bitflyer.Telemetry.log(
          :critical,
          "prep_stop: in-flight drain timed out",
          %{
            reason: :application_stop,
            count: length(leftovers)
          }
        )

        _ = finalize_drain_timeout(leftovers)
    end

    state
  end

  defp finalize_drain_timeout(leftovers) when is_list(leftovers) do
    marked? =
      Enum.reduce(leftovers, false, fn entry, acc ->
        case maybe_mark_submission_unknown(entry) do
          :marked -> true
          _ -> acc
        end
      end)

    # submit mark が無く cancel のみでも、途中打ち切りは不明扱いしてゲートを閉じる
    if marked? or leftovers != [] do
      _ = Bitflyer.Risk.open_circuit(:submission_unknown)
    end

    :ok
  end

  defp maybe_mark_submission_unknown(%{kind: :submit, internal_order_id: id})
       when is_binary(id) and id != "" do
    require Ash.Query
    alias Bitflyer.Trading.Order

    case Order
         |> Ash.Query.filter(internal_order_id == ^id)
         |> Ash.read_one() do
      {:ok, %Order{status: :pending, exchange_order_id: nil} = order} ->
        case order
             |> Ash.Changeset.for_update(:update, %{status: :submission_unknown})
             |> Ash.update() do
          {:ok, _} -> :marked
          {:error, _} -> :error
        end

      _ ->
        :skipped
    end
  end

  defp maybe_mark_submission_unknown(_entry), do: :skipped

  defp market_data_feed do
    if Bitflyer.MarketData.enabled?() do
      [
        Supervisor.child_spec({Bitflyer.MarketData.Feed, []}, shutdown: @child_shutdown_ms)
      ] ++ strategy_runner()
    else
      []
    end
  end

  defp strategy_runner do
    if Bitflyer.Strategy.enabled?() do
      [
        Supervisor.child_spec({Bitflyer.Strategy.Runner, []}, shutdown: @child_shutdown_ms)
      ]
    else
      []
    end
  end
end
