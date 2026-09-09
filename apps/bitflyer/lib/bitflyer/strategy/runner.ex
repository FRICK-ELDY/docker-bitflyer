defmodule Bitflyer.Strategy.Runner do
  @moduledoc """
  Feed の tick を受け、Strategy → Risk → Executor へ渡す駆動役。

  Ready 前など一時失敗は再試行する。受理済み・永続失敗は `internal_order_id`
  単位で settled とし再送しない。  起動時は Order から ID を復元するまで tick を無視する（起動レース回避）。
  銘柄ごとに `throttle_ms` で評価頻度を制限する。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Strategy
  alias Bitflyer.Trading.Order

  @name __MODULE__

  # 一時的（再試行可）。それ以外の明確な永続失敗は settled に入れる。
  @retryable_errors [
    :unsynced,
    :stale,
    :circuit_open,
    :persist_failed,
    :strategy_submit_crashed,
    :strategy_submit_exit
  ]

  @retryable_limit_kinds [
    :max_orders_per_minute,
    :max_daily_loss,
    :insufficient_balance
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Feed から tick を通知する。Runner 未起動なら no-op。
  """
  @spec notify_tick({:ticker, String.t()}, map()) :: :ok
  def notify_tick({:ticker, _product_code} = key, value) when is_map(value) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> send(pid, {:tick, key, value})
    end

    :ok
  end

  def notify_tick(_key, _value), do: :ok

  @impl true
  def init(opts) do
    {submitted, schedule_load?} = submitted_boot(Keyword.get(opts, :load_submitted?, true))

    state = %{
      module: Keyword.get_lazy(opts, :module, &Strategy.module/0),
      params: Keyword.get_lazy(opts, :params, &Strategy.params/0),
      throttle_ms: Keyword.get(opts, :throttle_ms, Strategy.throttle_ms()),
      # ロード完了まで nil。tick を無視して起動レースでの二重評価を防ぐ
      submitted: submitted,
      last_evaluated: %{}
    }

    if schedule_load? do
      send(self(), :load_submitted)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:load_submitted, state) do
    {:noreply, %{state | submitted: load_submitted_ids()}}
  end

  def handle_info({:tick, {:ticker, product_code} = key, value}, state) do
    now = System.monotonic_time(:millisecond)

    state =
      cond do
        is_nil(state.submitted) ->
          state

        # 高頻度 tick では Application env より先に throttle 判定する
        throttled?(state, product_code, now) ->
          state

        not Strategy.enabled?() ->
          state

        true ->
          state = %{state | last_evaluated: Map.put(state.last_evaluated, product_code, now)}
          maybe_submit(product_code, key, value, state)
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # true — 起動時に DB ロードをスケジュール（完了まで submitted は nil）
  # false — 空の MapSet で即受付（テスト用）
  # :pending — nil のままロードしない（起動レース検証用）
  defp submitted_boot(true), do: {nil, true}
  defp submitted_boot(false), do: {MapSet.new(), false}
  defp submitted_boot(:pending), do: {nil, false}

  # monotonic 時刻は負になり得るため、未評価は 0 ではなくキー欠如で表す
  defp throttled?(%{throttle_ms: throttle_ms, last_evaluated: last_evaluated}, product_code, now) do
    case Map.fetch(last_evaluated, product_code) do
      :error -> false
      {:ok, last_time} -> now - last_time < throttle_ms
    end
  end

  defp maybe_submit(product_code, key, value, state) do
    case build_market(product_code, key, value) do
      {:ok, market} ->
        commands = state.module.evaluate(market, [], state.params)

        pending_commands =
          Enum.reject(commands, fn command ->
            case command_id(command) do
              {:ok, id} -> MapSet.member?(state.submitted, id)
              :error -> false
            end
          end)

        if pending_commands == [] do
          state
        else
          Bitflyer.Telemetry.log(
            :info,
            "strategy evaluated",
            %{
              product_code: product_code,
              strategy: state.module,
              command_count: length(commands),
              pending_count: length(pending_commands),
              trade_mode: Bitflyer.TradeMode.current()
            }
          )

          submitted =
            Enum.reduce(pending_commands, state.submitted, fn command, acc ->
              result = submit_command(command)
              maybe_settle(acc, command, result)
            end)

          %{state | submitted: submitted}
        end

      :error ->
        state
    end
  end

  defp maybe_settle(acc, command, result) do
    case command_id(command) do
      {:ok, id} ->
        if settle?(result) do
          unless accepted?(result) do
            Bitflyer.Telemetry.log(
              :warning,
              "strategy intent settled without accept (no further retry)",
              %{
                internal_order_id: id,
                product_code: Map.get(command, :product_code),
                result: inspect(result),
                trade_mode: Bitflyer.TradeMode.current()
              }
            )
          end

          MapSet.put(acc, id)
        else
          acc
        end

      :error ->
        acc
    end
  end

  defp settle?(result) do
    accepted?(result) or terminal_rejection?(result)
  end

  defp accepted?({:ok, _order}), do: true
  defp accepted?({:ok, _order, :idempotent}), do: true
  defp accepted?(_), do: false

  defp terminal_rejection?({:error, reason, meta}) when is_map(meta) do
    cond do
      reason in @retryable_errors ->
        false

      reason == :limit_exceeded and Map.get(meta, :limit) in @retryable_limit_kinds ->
        false

      reason == :limit_exceeded ->
        true

      reason == :invalid_command ->
        true

      true ->
        # 未知理由は throttle 付き再試行（誤って永続停止しない）
        false
    end
  end

  defp terminal_rejection?({:error, reason}) when reason in @retryable_errors, do: false
  defp terminal_rejection?({:error, :invalid_command}), do: true
  defp terminal_rejection?({:error, _}), do: false
  defp terminal_rejection?(_), do: false

  defp build_market(product_code, key, value) do
    case Map.get(value, :ltp) || Map.get(value, "ltp") do
      %Decimal{} = ltp ->
        if Decimal.positive?(ltp) do
          {:ok,
           %{
             product_code: product_code,
             market_key: key,
             ltp: ltp
           }}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp submit_command(command) when is_map(command) do
    Bitflyer.Telemetry.log(
      :info,
      "strategy intent",
      %{
        internal_order_id: Map.get(command, :internal_order_id),
        product_code: Map.get(command, :product_code),
        side: Map.get(command, :side),
        trade_mode: Bitflyer.TradeMode.current()
      }
    )

    Bitflyer.System.submit_order(command)
  rescue
    error ->
      Bitflyer.Telemetry.log(
        :error,
        "strategy submit crashed: #{Exception.message(error)}",
        %{product_code: Map.get(command, :product_code)}
      )

      {:error, :strategy_submit_crashed, %{error: error}}
  catch
    :exit, reason ->
      Bitflyer.Telemetry.log(
        :error,
        "strategy submit exited",
        %{product_code: Map.get(command, :product_code), reason: inspect(reason)}
      )

      {:error, :strategy_submit_exit, %{reason: reason}}
  end

  defp command_id(command) when is_map(command) do
    case Map.get(command, :internal_order_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  defp load_submitted_ids do
    Order
    |> Ash.Query.select([:internal_order_id])
    |> Ash.read()
    |> case do
      {:ok, orders} ->
        orders
        |> Enum.map(& &1.internal_order_id)
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> MapSet.new()

      {:error, error} ->
        Bitflyer.Telemetry.log(
          :warning,
          "strategy runner failed to load submitted order ids",
          %{error: inspect(error)}
        )

        MapSet.new()
    end
  rescue
    error ->
      Bitflyer.Telemetry.log(
        :warning,
        "strategy runner failed to load submitted order ids",
        %{error: Exception.message(error)}
      )

      MapSet.new()
  catch
    :exit, reason ->
      Bitflyer.Telemetry.log(
        :warning,
        "strategy runner failed to load submitted order ids",
        %{error: inspect(reason)}
      )

      MapSet.new()
  end
end
