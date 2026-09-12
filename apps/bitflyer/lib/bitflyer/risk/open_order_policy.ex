defmodule Bitflyer.Risk.OpenOrderPolicy do
  @moduledoc """
  未約定（open）注文の期限と halt 時 cancel-all 方針。

  ## 方針（正本は prod.md も参照）

  - **自前 TIF は未実装。** 取引所の既定（実質 GTC）に任せ、内部の期限は
    `max_open_age_ms`（`inserted_at` 基準）で表す。
  - **halt 時:** 理由ごとに未約定 live を `OrderExecutor.cancel/2` で逐次取消するか選ぶ。
    証拠保全・recover が必要な理由は既定で取消しない。
  - 取消失敗でも halt 自体は維持する（best-effort）。
  - **再起動耐性:** `Circuit.open` だけでなく、永続 halt の ETS 再適用
    （`CircuitSync` / boot Reconciler / `halt_trading` 同期）でも
    `ensure_halt_cancels/2` を走らせる。同一稼働の一回限りではない。
  - **再試行背圧:** open が残っていても in-flight 中はスキップし、失敗／残留後は
    `halt_cancel_retry_backoff_ms` まで次の cancel 起動を抑える（CircuitSync 2s 連打防止）。
    状態は `HaltCancelGate` GenServer 所有の ETS（短命呼び出し元に紐づけない）。

  ## Config（`:bitflyer, Bitflyer.Risk.OpenOrderPolicy`）

  - `:max_open_age_ms` — `:infinity`（既定）または正の整数 ms
  - `:cancel_on_halt` — `%{halt_reason => boolean()}`。未記載理由は `false`
  - `:async_default` — `ensure` の `:async` 省略時（本番 true、test false）
  - `:halt_cancel_retry_backoff_ms` — 取消失敗／open 残留後の再試行間隔（既定 30_000）
  - `:halt_cancel_in_flight_stale_ms` — in-flight ロックの失効（既定 600_000）
  """

  require Ash.Query

  alias Bitflyer.Risk.OpenOrderPolicy.HaltCancelGate
  alias Bitflyer.Trading.Order

  @config_key __MODULE__
  @task_supervisor Bitflyer.MarketData.TaskSupervisor
  @default_retry_backoff_ms 30_000
  @default_in_flight_stale_ms 600_000

  @doc """
  halt 理由に対し未約定 live を取消するか。
  """
  @spec cancel_on_halt?(atom()) :: boolean()
  def cancel_on_halt?(reason) when is_atom(reason) do
    config()
    |> Keyword.get(:cancel_on_halt, %{})
    |> Map.get(reason, false) == true
  end

  @doc """
  未約定の最大滞留。`:infinity` のとき定期 TTL 取消はしない。
  """
  @spec max_open_age_ms() :: pos_integer() | :infinity
  def max_open_age_ms do
    case Keyword.get(config(), :max_open_age_ms, :infinity) do
      :infinity ->
        :infinity

      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        Bitflyer.Telemetry.log(
          :warning,
          "invalid OpenOrderPolicy max_open_age_ms; treating as infinity",
          %{value: other}
        )

        :infinity
    end
  end

  @doc """
  halt 直後のポリシー適用（`Circuit.open` 成功時）。

  内部は `ensure_halt_cancels/2`（`:force` でバックオフ解除）。再開経路からも同関数を呼ぶ。
  """
  @spec after_halt(atom(), keyword()) :: :ok
  def after_halt(reason, opts \\ []) when is_atom(reason) do
    ensure_halt_cancels(reason, Keyword.put_new(opts, :force, true))
  end

  @doc """
  永続／メモリ halt 中に、ポリシー対象なら未約定 live が無くなるまで best-effort 取消する。

  open が既に無ければ DB 読取のみで no-op（CircuitSync 周期呼び出し向け）。
  再起動後・非同期 cancel 未完了後の板残りをここで回収する。

  ## Options
  - `:async` — 省略時は config `:async_default`（本番 true、test false）。明示指定が優先。
  - `:force` — true なら失敗バックオフを無視して起動を試みる（in-flight 中は依然スキップ）。
  - `:exchange` — `OrderExecutor.cancel/2` へ転送
  """
  @spec ensure_halt_cancels(atom(), keyword()) :: :ok
  def ensure_halt_cancels(reason, opts \\ []) when is_atom(reason) do
    if cancel_on_halt?(reason) do
      case list_open_orders(trade_modes: [:live]) do
        {:ok, []} ->
          :ok

        {:ok, _opens} ->
          case try_begin_halt_cancel(opts) do
            :go ->
              schedule_cancel(reason, opts)

            :busy ->
              :ok

            :backoff ->
              :ok
          end

        {:error, error} ->
          Bitflyer.Telemetry.log(
            :error,
            "OpenOrderPolicy.ensure_halt_cancels list failed",
            %{halt_reason: reason, error: inspect(error)}
          )

          :ok
      end
    else
      :ok
    end
  end

  @doc """
  `max_open_age_ms` 超過の live open を取消する（起動・定期突合向け）。
  """
  @spec cancel_aged_opens(keyword()) :: :ok | {:ok, list()} | {:error, atom(), map()}
  def cancel_aged_opens(opts \\ []) do
    case max_open_age_ms() do
      :infinity ->
        :ok

      ms ->
        older_than =
          DateTime.utc_now()
          |> DateTime.add(-ms, :millisecond)
          |> DateTime.truncate(:microsecond)

        Bitflyer.OrderExecutor.cancel_open_orders(
          Keyword.merge(opts,
            trade_modes: [:live],
            older_than: older_than,
            cause: :open_age
          )
        )
    end
  end

  @doc false
  @spec list_open_orders(keyword()) :: {:ok, [Order.t()]} | {:error, term()}
  def list_open_orders(opts \\ []) do
    trade_modes = Keyword.get(opts, :trade_modes, [:live])
    older_than = Keyword.get(opts, :older_than)

    query =
      Order
      |> Ash.Query.filter(status in [:pending, :partially_filled] and trade_mode in ^trade_modes)

    query =
      if match?(%DateTime{}, older_than) do
        Ash.Query.filter(query, inserted_at <= ^older_than)
      else
        query
      end

    Ash.read(query)
  end

  @doc false
  @spec reset_halt_cancel_gate!() :: :ok
  def reset_halt_cancel_gate! do
    HaltCancelGate.reset!()
  end

  defp schedule_cancel(reason, opts) do
    async? =
      Keyword.get(
        opts,
        :async,
        Keyword.get(config(), :async_default, true)
      )

    run = fn ->
      outcome = run_cancel_open_orders(reason, opts)
      finish_halt_cancel(outcome, opts)
    end

    if async? do
      case start_cancel_task(run) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        {:error, reason_start} ->
          finish_halt_cancel(:retry, opts)

          Bitflyer.Telemetry.log(
            :error,
            "OpenOrderPolicy halt cancel task start failed",
            %{halt_reason: reason, error: inspect(reason_start)}
          )

          :ok
      end
    else
      run.()
    end
  end

  defp run_cancel_open_orders(reason, opts) do
    try do
      result =
        Bitflyer.OrderExecutor.cancel_open_orders(
          Keyword.merge(opts,
            trade_modes: [:live],
            cause: :halt_policy,
            halt_reason: reason
          )
        )

      cancel_outcome(result)
    rescue
      error ->
        Bitflyer.Telemetry.log(
          :error,
          "OpenOrderPolicy halt cancel failed",
          %{halt_reason: reason, error: Exception.message(error)}
        )

        :retry
    catch
      kind, reason_caught ->
        Bitflyer.Telemetry.log(
          :error,
          "OpenOrderPolicy halt cancel crashed",
          %{halt_reason: reason, kind: kind, error: inspect(reason_caught)}
        )

        :retry
    end
  end

  defp cancel_outcome({:ok, results}) do
    failed? =
      Enum.any?(results, fn
        {_, {:ok, _}} -> false
        {_, {:ok, _, :idempotent}} -> false
        _ -> true
      end)

    case list_open_orders(trade_modes: [:live]) do
      {:ok, []} when not failed? ->
        :cleared

      _ ->
        :retry
    end
  end

  defp cancel_outcome({:error, _, _}), do: :retry
  defp cancel_outcome(_), do: :retry

  defp try_begin_halt_cancel(opts) do
    gate_opts =
      opts
      |> Keyword.take([:force, :server])
      |> Keyword.put(:stale_ms, in_flight_stale_ms())

    case safe_gate_call(fn -> HaltCancelGate.try_begin(gate_opts) end) do
      {:ok, result} -> result
      :unavailable -> :busy
    end
  end

  defp finish_halt_cancel(outcome, opts) do
    gate_opts =
      opts
      |> Keyword.take([:server])
      |> Keyword.put(:backoff_ms, retry_backoff_ms())

    _ = safe_gate_call(fn -> HaltCancelGate.finish(outcome, gate_opts) end)
    :ok
  end

  defp safe_gate_call(fun) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason ->
        Bitflyer.Telemetry.log(
          :error,
          "OpenOrderPolicy HaltCancelGate unavailable",
          %{error: inspect(reason)}
        )

        :unavailable
    end
  end

  defp retry_backoff_ms do
    case Keyword.get(config(), :halt_cancel_retry_backoff_ms, @default_retry_backoff_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_retry_backoff_ms
    end
  end

  defp in_flight_stale_ms do
    case Keyword.get(config(), :halt_cancel_in_flight_stale_ms, @default_in_flight_stale_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_in_flight_stale_ms
    end
  end

  defp start_cancel_task(run) do
    case Process.whereis(@task_supervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(@task_supervisor, run)

      _ ->
        Task.start(run)
    end
  end

  defp config, do: Application.get_env(:bitflyer, @config_key, [])
end
