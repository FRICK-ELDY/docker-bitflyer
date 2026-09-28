defmodule Bitflyer.Risk.PeakWriter do
  @moduledoc """
  認可で上がった当日 equity ピーク（HWM）の write-behind。

  ホットパスは enqueue の受理まで。DB の upsert はこのプロセスが行う。
  同一 `(trade_mode, trading_day)` は高い方だけ残し、成功するまで pending から捨てない。
  成功後に `DailyLoss` の `persisted_peak` を進める。

  本番の enqueue は DB の upsert が成功するまで `:ok` を返さない。
  成功のあとでこのプロセスと DailyLoss が同時に消えても、DB の高値は残る。
  upsert 失敗は unsync にして `{:error, :unsynced}` を返し、pending を残して再送する。
  再送間隔も待ちタイマーも銘柄日ごとで、50ms から倍々で延び、上限は 5 秒。
  他銘柄日の成功では、間隔もタイマーも戻さない。
  同じ失敗の error は初回と、5 秒より空いた再掲だけにする。
  失敗した再送は pending の高い方を残す。drain は退避を待たず、未書きをすぐ流す。
  DailyLoss 再起動で ack / unsync が届かないときも pending を残す。
  自プロセスが落ちても、生存している DailyLoss の未永続高値を `init` で積み直す。

  `Application.prep_stop` の `drain/1` と子停止時の `terminate/2` が未書きを流す。
  テスト用の `suspend/1` だけは受理を先に返す。本番の認可経路では suspend しない。
  """

  use GenServer

  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.DailyEquityPeak

  @name __MODULE__
  @drain_timeout_ms 10_000
  @retry_min_ms 50
  @retry_max_ms 5_000
  @trade_modes [:dry_run, :paper, :live]

  @type trade_mode :: Bitflyer.TradeMode.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)

    GenServer.start_link(__MODULE__, %{daily_loss: Keyword.get(opts, :daily_loss, DailyLoss)},
      name: name
    )
  end

  @doc """
  高いピークを積む。0 以下は無視する。

  suspend 中でなければ upsert 成功と ack まで待って `:ok` を返す。
  失敗は `{:error, :unsynced}`。未書きは pending に残して再送する。
  """
  @spec enqueue(trade_mode(), Date.t(), Decimal.t(), keyword()) :: :ok | {:error, term()}
  def enqueue(trade_mode, %Date{} = day, %Decimal{} = peak, opts \\ [])
      when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    daily_loss = Keyword.get(opts, :daily_loss, DailyLoss)

    try do
      GenServer.call(server, {:enqueue, trade_mode, day, peak, daily_loss}, 5_000)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  未書きのピークが DB に落ちるまで待つ。停止中の保留もここで書く。
  """
  @spec drain(keyword()) :: :ok | {:error, term()}
  def drain(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    timeout_ms = Keyword.get(opts, :timeout_ms, @drain_timeout_ms)

    try do
      GenServer.call(server, :drain, timeout_ms)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, reason -> {:error, reason}
    end
  end

  @doc false
  @spec retry_timer_left(keyword()) :: non_neg_integer() | false | {:error, term()}
  def retry_timer_left(opts \\ []) do
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, {:retry_timer_left, Keyword.get(opts, :key)})
    else
      {:error, :forbidden}
    end
  end

  @doc """
  テスト用。まだ書いていない件数。
  """
  @spec pending_count(keyword()) :: non_neg_integer() | {:error, term()}
  def pending_count(opts \\ []) do
    server = Keyword.get(opts, :server, @name)

    try do
      GenServer.call(server, :pending_count)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  テスト用。enqueue を保留し、DB へ書かない。
  """
  @spec suspend(keyword()) :: :ok | {:error, :forbidden}
  def suspend(opts \\ []) do
    call_if_test(opts, :suspend)
  end

  @doc """
  テスト用。`suspend/1` を外して書き出しを再開する。完了は `drain/1`。
  """
  @spec resume(keyword()) :: :ok | {:error, :forbidden}
  def resume(opts \\ []) do
    call_if_test(opts, :resume)
  end

  @doc """
  テスト用。upsert を差し替える。`reset_upsert/1` で戻す。
  """
  @spec set_upsert((trade_mode(), Date.t(), Decimal.t() -> :ok | {:error, term()}), keyword()) ::
          :ok | {:error, :forbidden}
  def set_upsert(fun, opts \\ []) when is_function(fun, 3) do
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, {:set_upsert, fun})
    else
      {:error, :forbidden}
    end
  end

  @doc """
  テスト用。upsert を `DailyEquityPeak.upsert/3` に戻す。
  """
  @spec reset_upsert(keyword()) :: :ok | {:error, :forbidden}
  def reset_upsert(opts \\ []) do
    call_if_test(opts, :reset_upsert)
  end

  @impl true
  def init(%{daily_loss: daily_loss}) do
    # 親の :shutdown を通常終了にすると terminate/2 まで届かない。
    # 未書きのピークを flush するため、出口を捕まえる。
    Process.flag(:trap_exit, true)

    state =
      Enum.reduce(load_unpersisted(daily_loss), empty_state(), fn {mode, day, peak}, acc ->
        put_pending(acc, mode, day, peak, daily_loss)
      end)

    if map_size(state.pending) == 0 do
      {:ok, state}
    else
      {:ok, %{state | writing?: true}, {:continue, :flush}}
    end
  end

  @impl true
  def handle_continue(:flush, state) do
    {:noreply, flush_ready(state)}
  end

  @impl true
  def handle_call({:enqueue, trade_mode, day, peak, daily_loss}, _from, state)
      when trade_mode in @trade_modes do
    cond do
      Decimal.compare(peak, 0) != :gt ->
        {:reply, :ok, state}

      state.suspended? ->
        {:reply, :ok, put_pending(state, trade_mode, day, peak, daily_loss)}

      true ->
        state = put_pending(state, trade_mode, day, peak, daily_loss)
        queued = pending_peak(state, trade_mode, day)
        key = {trade_mode, day}

        case persist_attempt(state, trade_mode, day, queued, daily_loss) do
          {:done, state} ->
            state = drop_covered(state, trade_mode, day, queued)
            {:reply, :ok, kick(reset_retry(%{state | writing?: false}, key))}

          {:retry, state} ->
            state = requeue(state, trade_mode, day, queued, daily_loss)
            {:reply, {:error, :unsynced}, schedule_retry(state, key)}
        end
    end
  end

  def handle_call(:suspend, _from, state) do
    {:reply, :ok, %{state | suspended?: true}}
  end

  def handle_call(:resume, _from, state) do
    {:reply, :ok, kick(%{state | suspended?: false})}
  end

  def handle_call(:drain, from, state) do
    # 退避の残り時間を待たない。停止の drain は未書きをすぐ流す。
    state =
      state
      |> cancel_all_retry_timers()
      |> Map.merge(%{suspended?: false, writing?: false})
      |> kick()

    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:pending_count, _from, state) do
    {:reply, map_size(state.pending), state}
  end

  def handle_call({:retry_timer_left, key}, _from, state) do
    timer =
      cond do
        key -> Map.get(state.retry_timers, key)
        map_size(state.retry_timers) == 1 -> state.retry_timers |> Map.values() |> hd()
        true -> nil
      end

    left = if is_reference(timer), do: Process.read_timer(timer), else: false
    {:reply, left, state}
  end

  def handle_call({:set_upsert, fun}, _from, state) do
    {:reply, :ok, %{state | upsert: fun}}
  end

  def handle_call(:reset_upsert, _from, state) do
    {:reply, :ok, %{state | upsert: &DailyEquityPeak.upsert/3}}
  end

  @impl true
  def handle_info(:flush_ready, %{suspended?: true, waiters: []} = state) do
    {:noreply, %{state | writing?: false}}
  end

  def handle_info(:flush_ready, %{suspended?: true} = state) do
    # drain が待っている。suspend より未書きの flush を優先する。
    {:noreply, flush_ready(%{state | suspended?: false})}
  end

  def handle_info(:flush_ready, state) do
    {:noreply, flush_ready(state)}
  end

  def handle_info({:flush_key, key}, state) do
    state = %{state | retry_timers: Map.delete(state.retry_timers, key)}
    {:noreply, flush_key(state, key)}
  end

  # テストが待ちを待たずに再送する。どのタイマーが先かは Map の並びに寄らない。
  def handle_info(:flush, state) do
    state = cancel_all_retry_timers(state)
    {:noreply, flush_ready(state)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = flush_pending(%{state | suspended?: false}, 0)
    :ok
  end

  defp flush_ready(state) do
    case ready_key(state) do
      nil ->
        finish_if_idle(state)

      key ->
        flush_key(%{state | writing?: true}, key)
    end
  end

  defp flush_key(state, {mode, day} = key) do
    case Map.fetch(state.pending, key) do
      :error ->
        finish_if_idle(state)

      {:ok, %{peak: peak, daily_loss: daily_loss}} ->
        case persist_attempt(state, mode, day, peak, daily_loss) do
          {:done, state} ->
            state = drop_covered(state, mode, day, peak)

            send(self(), :flush_ready)
            %{reset_retry(state, key) | writing?: true}

          {:retry, state} ->
            state = requeue(state, mode, day, peak, daily_loss)
            state = schedule_retry(state, key)
            finish_if_idle(%{state | writing?: false})
        end
    end
  end

  defp finish_if_idle(state) do
    cond do
      map_size(state.pending) == 0 ->
        reply_waiters(%{state | writing?: false})

      ready_key(state) ->
        send(self(), :flush_ready)
        %{state | writing?: true}

      true ->
        %{state | writing?: false}
    end
  end

  defp flush_pending(state, _rounds) when map_size(state.pending) == 0 do
    reply_waiters(state)
  end

  defp flush_pending(state, rounds) when rounds > 8 do
    Bitflyer.Telemetry.log(:critical, "peak writer terminate left peaks unpersisted", %{
      reason: :terminate_rounds
    })

    state
  end

  defp flush_pending(state, rounds) do
    state =
      Enum.reduce(Map.keys(state.pending), state, fn {mode, day} = key, acc ->
        case Map.fetch(acc.pending, key) do
          :error ->
            acc

          {:ok, %{peak: peak, daily_loss: daily_loss}} ->
            case persist_attempt(acc, mode, day, peak, daily_loss) do
              {:done, acc} -> drop_covered(acc, mode, day, peak)
              {:retry, acc} -> requeue(acc, mode, day, peak, daily_loss)
            end
        end
      end)

    flush_pending(state, rounds + 1)
  end

  defp persist_attempt(state, trade_mode, day, peak, daily_loss) do
    case do_upsert(state, trade_mode, day, peak) do
      :ok ->
        case ack(daily_loss, trade_mode, day, peak) do
          :ok ->
            {:done, forget_failure(state, {trade_mode, day})}

          :stale_day ->
            {:done, forget_failure(state, {trade_mode, day})}

          {:down, exit_reason} ->
            {state, log?} = note_failure(state, {trade_mode, day}, :ack)

            if log? do
              Bitflyer.Telemetry.log(:error, "peak persist ack failed; peak kept for retry", %{
                reason: inspect(exit_reason),
                trade_mode: trade_mode
              })
            end

            {:retry, state}
        end

      {:error, reason} ->
        {state, log?} = note_failure(state, {trade_mode, day}, reason)
        _ = mark_unsynced(daily_loss, trade_mode, day, reason, log?)
        {:retry, state}
    end
  end

  defp do_upsert(state, trade_mode, day, peak) do
    case state.upsert.(trade_mode, day, peak) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ack(daily_loss, trade_mode, day, peak) do
    case GenServer.call(daily_loss, {:commit_peak, trade_mode, day, peak, :persisted}) do
      {:ok, _} -> :ok
      :stale_day -> :stale_day
    end
  catch
    :exit, reason ->
      {:down, reason}
  end

  defp mark_unsynced(daily_loss, trade_mode, day, reason, log?) do
    case GenServer.call(daily_loss, {:peak_persist_failed, trade_mode, day, reason, log?}) do
      :ok -> :ok
      :stale_day -> :stale_day
    end
  catch
    :exit, exit_reason ->
      if log? do
        Bitflyer.Telemetry.log(:error, "peak unsync failed; peak kept for retry", %{
          reason: inspect(exit_reason),
          trade_mode: trade_mode
        })
      end

      :down
  end

  defp load_unpersisted(daily_loss) do
    GenServer.call(daily_loss, :unpersisted_peaks, 1_000)
  catch
    :exit, reason ->
      Bitflyer.Telemetry.log(:error, "peak writer missed unpersisted peaks on start", %{
        reason: inspect(reason)
      })

      []
  end

  defp kick(%{suspended?: true} = state), do: state
  defp kick(%{writing?: true} = state), do: state

  defp kick(state) do
    if ready_key(state) == nil do
      state
    else
      send(self(), :flush_ready)
      %{state | writing?: true}
    end
  end

  defp ready_key(state) do
    Enum.find_value(state.pending, fn {key, _entry} ->
      if Map.has_key?(state.retry_timers, key), do: nil, else: key
    end)
  end

  defp idle?(state) do
    not state.writing? and map_size(state.pending) == 0
  end

  defp put_pending(state, trade_mode, day, peak, daily_loss) do
    key = {trade_mode, day}
    entry = %{peak: peak, daily_loss: daily_loss}

    pending =
      Map.update(state.pending, key, entry, fn current ->
        if Decimal.compare(peak, current.peak) == :gt do
          entry
        else
          current
        end
      end)

    %{state | pending: pending}
  end

  defp pending_peak(state, trade_mode, day) do
    state.pending[{trade_mode, day}].peak
  end

  # 値は pending の高い方を残す。並び替えはしない。
  defp requeue(state, trade_mode, day, peak, daily_loss) do
    key = {trade_mode, day}

    entry =
      case Map.fetch(state.pending, key) do
        {:ok, %{peak: current} = existing} ->
          if Decimal.compare(peak, current) == :gt do
            %{peak: peak, daily_loss: daily_loss}
          else
            existing
          end

        :error ->
          %{peak: peak, daily_loss: daily_loss}
      end

    %{state | pending: Map.put(state.pending, key, entry)}
  end

  defp drop_covered(state, trade_mode, day, written_peak) do
    key = {trade_mode, day}

    case Map.fetch(state.pending, key) do
      :error ->
        state

      {:ok, %{peak: peak}} ->
        if Decimal.compare(peak, written_peak) == :gt do
          state
        else
          %{state | pending: Map.delete(state.pending, key)}
        end
    end
  end

  defp reply_waiters(%{waiters: []} = state), do: state

  defp reply_waiters(%{waiters: waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  defp schedule_retry(state, key) do
    state = cancel_retry_timer(state, key)
    stored = Map.get(state.retry_ms, key, @retry_min_ms)

    # drain が待っているあいだは退避を使わず、保存してある間隔自体は進める。
    delay = if state.waiters == [], do: stored, else: @retry_min_ms
    timer = Process.send_after(self(), {:flush_key, key}, delay)

    %{
      state
      | retry_timers: Map.put(state.retry_timers, key, timer),
        last_retry_ms: delay,
        retry_ms: Map.put(state.retry_ms, key, min(stored * 2, @retry_max_ms))
    }
  end

  defp reset_retry(state, key) do
    %{cancel_retry_timer(state, key) | retry_ms: Map.delete(state.retry_ms, key)}
  end

  defp cancel_retry_timer(state, key) do
    {timer, timers} = Map.pop(state.retry_timers, key)
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | retry_timers: timers}
  end

  defp cancel_all_retry_timers(state) do
    Enum.each(state.retry_timers, fn {_key, timer} ->
      if is_reference(timer), do: Process.cancel_timer(timer)
    end)

    %{state | retry_timers: %{}}
  end

  # 同じ {mode, day, reason} は初回と、上限間隔より空いた再掲だけを error にする。
  defp note_failure(state, key, reason) do
    now = System.monotonic_time(:millisecond)
    token = failure_token(reason)

    log_key = {key, token}

    log? =
      case Map.get(state.failure_logs, log_key) do
        %{at: at} -> now - at >= @retry_max_ms
        _ -> true
      end

    state =
      if log? do
        %{state | failure_logs: Map.put(state.failure_logs, log_key, %{at: now})}
      else
        state
      end

    {state, log?}
  end

  defp failure_token(%struct{}), do: struct
  defp failure_token({kind, _detail}) when is_atom(kind), do: kind
  defp failure_token(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp failure_token(_reason), do: :error

  defp forget_failure(state, key) do
    logs =
      Map.reject(state.failure_logs, fn
        {{^key, _token}, _entry} -> true
        _ -> false
      end)

    %{state | failure_logs: logs}
  end

  defp empty_state do
    %{
      suspended?: false,
      writing?: false,
      pending: %{},
      waiters: [],
      upsert: &DailyEquityPeak.upsert/3,
      retry_ms: %{},
      last_retry_ms: nil,
      retry_timers: %{},
      failure_logs: %{}
    }
  end

  defp call_if_test(opts, message) do
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, message)
    else
      {:error, :forbidden}
    end
  end

  defp test_injections_allowed? do
    :bitflyer
    |> Application.get_env(Bitflyer.Risk, [])
    |> Keyword.get(:allow_test_injections, false) == true
  end
end
