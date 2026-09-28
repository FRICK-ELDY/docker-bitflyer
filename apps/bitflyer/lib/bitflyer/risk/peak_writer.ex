defmodule Bitflyer.Risk.PeakWriter do
  @moduledoc """
  認可で上がった当日 equity ピーク（HWM）の write-behind。

  ホットパスは `GenServer.cast` のみ。このプロセスが `DailyEquityPeak.upsert/3`
  を単調に書き、成功後に `DailyLoss` の `persisted_peak` を進める。
  同一 `(trade_mode, trading_day)` は高い方だけ残す。

  `Application.prep_stop` の `drain/1` と子停止時の `terminate/2` が未書きを
  DB まで流す。認可プロセスが先に落ちても、この監督下プロセスが書き終える。
  upsert 失敗は当該モードを unsynced（fail-closed）。
  """

  use GenServer

  alias Bitflyer.Risk.DailyLoss
  alias Bitflyer.Trading.DailyEquityPeak

  @name __MODULE__
  @drain_timeout_ms 10_000
  @trade_modes [:dry_run, :paper, :live]

  @type trade_mode :: Bitflyer.TradeMode.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{name: name}, name: name)
  end

  @doc """
  高いピークを非同期に積む。0 以下は無視する。
  """
  @spec enqueue(trade_mode(), Date.t(), Decimal.t(), keyword()) :: :ok
  def enqueue(trade_mode, %Date{} = day, %Decimal{} = peak, opts \\ [])
      when trade_mode in @trade_modes do
    server = Keyword.get(opts, :server, @name)
    daily_loss = Keyword.get(opts, :daily_loss, DailyLoss)
    GenServer.cast(server, {:enqueue, trade_mode, day, peak, daily_loss})
  end

  @doc """
  未書きのピークが DB に落ちるまで待つ。停止中の保留もここで書く。
  """
  @spec drain(keyword()) :: :ok | {:error, :timeout}
  def drain(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    timeout_ms = Keyword.get(opts, :timeout_ms, @drain_timeout_ms)

    try do
      GenServer.call(server, :drain, timeout_ms)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  テスト用。enqueue を保留し、DB へ書かない。
  """
  @spec suspend(keyword()) :: :ok | {:error, :forbidden}
  def suspend(opts \\ []) do
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, :suspend)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  テスト用。`suspend/1` を外して書き出しを再開する。完了は `drain/1`。
  """
  @spec resume(keyword()) :: :ok | {:error, :forbidden}
  def resume(opts \\ []) do
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, :resume)
    else
      {:error, :forbidden}
    end
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
    server = Keyword.get(opts, :server, @name)

    if test_injections_allowed?() do
      GenServer.call(server, :reset_upsert)
    else
      {:error, :forbidden}
    end
  end

  @impl true
  def init(%{name: _name}) do
    {:ok,
     %{
       suspended?: false,
       writing?: false,
       pending: %{},
       waiters: [],
       upsert: &DailyEquityPeak.upsert/3
     }}
  end

  @impl true
  def handle_cast({:enqueue, trade_mode, day, peak, daily_loss}, state)
      when trade_mode in @trade_modes do
    state =
      if Decimal.compare(peak, 0) == :gt do
        state
        |> put_pending(trade_mode, day, peak, daily_loss)
        |> kick()
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:suspend, _from, state) do
    {:reply, :ok, %{state | suspended?: true}}
  end

  def handle_call(:resume, _from, state) do
    {:reply, :ok, kick(%{state | suspended?: false})}
  end

  def handle_call(:drain, from, state) do
    state = absorb_casts(%{state | suspended?: false})
    state = kick(state)

    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call({:set_upsert, fun}, _from, state) do
    {:reply, :ok, %{state | upsert: fun}}
  end

  def handle_call(:reset_upsert, _from, state) do
    {:reply, :ok, %{state | upsert: &DailyEquityPeak.upsert/3}}
  end

  @impl true
  def handle_info(:flush, %{suspended?: true} = state) do
    # テストの suspend 中は予約済み flush を進めない。drain / resume が kick する。
    {:noreply, %{state | writing?: false}}
  end

  def handle_info(:flush, state) do
    {:noreply, flush_one(state)}
  end

  @impl true
  def terminate(_reason, state) do
    state = absorb_casts(%{state | suspended?: false})
    _ = flush_pending(state)
    :ok
  end

  defp flush_one(state) do
    state = absorb_casts(state)

    case pop_pending(state) do
      {:empty, state} ->
        state = absorb_casts(state)

        case pop_pending(state) do
          {:empty, state} ->
            reply_waiters(%{state | writing?: false})

          {{mode, day, peak, daily_loss}, state} ->
            write_and_continue(state, mode, day, peak, daily_loss)
        end

      {{mode, day, peak, daily_loss}, state} ->
        write_and_continue(state, mode, day, peak, daily_loss)
    end
  end

  defp write_and_continue(state, mode, day, peak, daily_loss) do
    _ = persist_one(state, mode, day, peak, daily_loss)
    send(self(), :flush)
    %{state | writing?: true}
  end

  defp persist_one(state, trade_mode, day, peak, daily_loss) do
    result =
      try do
        state.upsert.(trade_mode, day, peak)
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        ack(daily_loss, trade_mode, day, peak)

      {:error, reason} ->
        mark_unsynced(daily_loss, trade_mode, day, reason)

      other ->
        mark_unsynced(daily_loss, trade_mode, day, other)
    end
  end

  defp flush_pending(state) do
    case pop_pending(state) do
      {:empty, _state} ->
        :ok

      {{mode, day, peak, daily_loss}, state} ->
        _ = persist_one(state, mode, day, peak, daily_loss)
        flush_pending(state)
    end
  end

  defp ack(daily_loss, trade_mode, day, peak) do
    case GenServer.call(daily_loss, {:commit_peak, trade_mode, day, peak, :persisted}) do
      {:ok, _} -> :ok
      :stale_day -> :stale_day
    end
  catch
    :exit, _ -> :down
  end

  defp mark_unsynced(daily_loss, trade_mode, day, reason) do
    GenServer.call(daily_loss, {:peak_persist_failed, trade_mode, day, reason})
  catch
    :exit, _ -> :down
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

  defp pop_pending(%{pending: pending} = state) when map_size(pending) == 0 do
    {:empty, state}
  end

  defp pop_pending(%{pending: pending} = state) do
    [{key, entry}] = Enum.take(pending, 1)
    {mode, day} = key

    {{mode, day, entry.peak, entry.daily_loss}, %{state | pending: Map.delete(pending, key)}}
  end

  defp reply_waiters(%{waiters: []} = state), do: state

  defp reply_waiters(%{waiters: waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  # drain 判定の直前に届いた cast を pending に取り込む。
  # 取り込み前に idle と返すと、停止側が未処理メッセージを捨てる。
  defp absorb_casts(state) do
    receive do
      {:"$gen_cast", {:enqueue, trade_mode, day, peak, daily_loss}} ->
        state
        |> put_pending(trade_mode, day, peak, daily_loss)
        |> absorb_casts()
    after
      0 -> state
    end
  end

  defp test_injections_allowed? do
    :bitflyer
    |> Application.get_env(Bitflyer.Risk, [])
    |> Keyword.get(:allow_test_injections, false) == true
  end
end
