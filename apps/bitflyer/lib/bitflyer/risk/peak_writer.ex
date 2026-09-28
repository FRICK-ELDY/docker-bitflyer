defmodule Bitflyer.Risk.PeakWriter do
  @moduledoc """
  認可で上がった当日 equity ピーク（HWM）の write-behind。

  ホットパスは enqueue の受理まで。DB の upsert はこのプロセスが行う。
  同一 `(trade_mode, trading_day)` は高い方だけ残し、成功するまで pending から捨てない。
  成功後に `DailyLoss` の `persisted_peak` を進める。

  本番の enqueue は DB の upsert が成功するまで `:ok` を返さない。
  成功のあとでこのプロセスと DailyLoss が同時に消えても、DB の高値は残る。
  upsert 失敗は unsync にして `{:error, :unsynced}` を返し、pending を残して再送する。
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
  @retry_ms 50
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
    {:noreply, flush_one(state)}
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

        case persist_attempt(state, trade_mode, day, peak, daily_loss) do
          :done ->
            state = drop_covered(state, trade_mode, day, peak)
            {:reply, :ok, kick(%{state | writing?: false})}

          :retry ->
            state = requeue(state, trade_mode, day, peak, daily_loss)
            Process.send_after(self(), :flush, @retry_ms)
            {:reply, {:error, :unsynced}, %{state | writing?: true}}
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
    state = kick(%{state | suspended?: false})

    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:pending_count, _from, state) do
    {:reply, map_size(state.pending), state}
  end

  def handle_call({:set_upsert, fun}, _from, state) do
    {:reply, :ok, %{state | upsert: fun}}
  end

  def handle_call(:reset_upsert, _from, state) do
    {:reply, :ok, %{state | upsert: &DailyEquityPeak.upsert/3}}
  end

  @impl true
  def handle_info(:flush, %{suspended?: true, waiters: []} = state) do
    {:noreply, %{state | writing?: false}}
  end

  def handle_info(:flush, %{suspended?: true} = state) do
    # drain が待っている。suspend より未書きの flush を優先する。
    {:noreply, flush_one(%{state | suspended?: false})}
  end

  def handle_info(:flush, state) do
    {:noreply, flush_one(state)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = flush_pending(%{state | suspended?: false}, 0)
    :ok
  end

  defp flush_one(state) do
    case peek_pending(state) do
      :empty ->
        finish_if_idle(state)

      {mode, day, peak, daily_loss} ->
        case persist_attempt(state, mode, day, peak, daily_loss) do
          :done ->
            state = drop_covered(state, mode, day, peak)

            send(self(), :flush)
            %{state | writing?: true}

          :retry ->
            state = requeue(state, mode, day, peak, daily_loss)
            Process.send_after(self(), :flush, @retry_ms)
            %{state | writing?: true}
        end
    end
  end

  defp finish_if_idle(state) do
    case peek_pending(state) do
      :empty ->
        reply_waiters(%{state | writing?: false})

      _ ->
        send(self(), :flush)
        %{state | writing?: true}
    end
  end

  defp flush_pending(state, rounds) when rounds > 8 do
    Bitflyer.Telemetry.log(:critical, "peak writer terminate left peaks unpersisted", %{
      reason: :terminate_rounds
    })

    state
  end

  defp flush_pending(state, rounds) do
    case peek_pending(state) do
      :empty ->
        reply_waiters(state)

      {mode, day, peak, daily_loss} ->
        case persist_attempt(state, mode, day, peak, daily_loss) do
          :done ->
            state = drop_covered(state, mode, day, peak)

            flush_pending(state, rounds + 1)

          :retry ->
            flush_pending(requeue(state, mode, day, peak, daily_loss), rounds + 1)
        end
    end
  end

  defp persist_attempt(state, trade_mode, day, peak, daily_loss) do
    case do_upsert(state, trade_mode, day, peak) do
      :ok ->
        case ack(daily_loss, trade_mode, day, peak) do
          :ok -> :done
          :stale_day -> :done
          :down -> :retry
        end

      {:error, reason} ->
        _ = mark_unsynced(daily_loss, trade_mode, day, reason)
        :retry
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
      Bitflyer.Telemetry.log(:error, "peak persist ack failed; peak kept for retry", %{
        reason: inspect(reason),
        trade_mode: trade_mode
      })

      :down
  end

  defp mark_unsynced(daily_loss, trade_mode, day, reason) do
    case GenServer.call(daily_loss, {:peak_persist_failed, trade_mode, day, reason}) do
      :ok -> :ok
      :stale_day -> :stale_day
    end
  catch
    :exit, exit_reason ->
      Bitflyer.Telemetry.log(:error, "peak unsync failed; peak kept for retry", %{
        reason: inspect(exit_reason),
        trade_mode: trade_mode
      })

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
    if map_size(state.pending) == 0 do
      state
    else
      send(self(), :flush)
      %{state | writing?: true}
    end
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

  defp peek_pending(%{pending: pending}) when map_size(pending) == 0, do: :empty

  defp peek_pending(%{pending: pending}) do
    [{key, entry}] = Enum.take(pending, 1)
    {mode, day} = key
    {mode, day, entry.peak, entry.daily_loss}
  end

  defp requeue(state, trade_mode, day, peak, daily_loss) do
    key = {trade_mode, day}
    pending = Map.delete(state.pending, key)
    %{state | pending: Map.put(pending, key, %{peak: peak, daily_loss: daily_loss})}
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

  defp empty_state do
    %{
      suspended?: false,
      writing?: false,
      pending: %{},
      waiters: [],
      upsert: &DailyEquityPeak.upsert/3
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
