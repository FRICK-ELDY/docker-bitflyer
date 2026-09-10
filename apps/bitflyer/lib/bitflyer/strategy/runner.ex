defmodule Bitflyer.Strategy.Runner do
  @moduledoc """
  Feed の tick を受け、Strategy → Risk → Executor へ渡す駆動役。

  Ready 前など一時失敗は再試行する。受理済み・永続失敗は `internal_order_id`
  単位で settled とし再送しない。

  起動時は Order から ID を復元するまで tick を無視する。
  ロード完了時刻より前に送られた tick（メールボックス滞留分）は破棄する。
  復元は lookback＋戦略 ID 接頭辞で絞り、古い行の二重 REST は Executor 冪等に委ねる。
  銘柄ごとに `throttle_ms` で評価頻度を制限する。
  """

  use GenServer

  require Ash.Query

  alias Bitflyer.Strategy
  alias Bitflyer.Strategy.Revision
  alias Bitflyer.Trading.Order
  alias Bitflyer.Trading.StrategyParameterRevision

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

  送信時刻（monotonic ms）を付与し、起動ロード完了前の滞留 tick を破棄できるようにする。
  """
  @spec notify_tick({:ticker, String.t()}, map()) :: :ok
  def notify_tick({:ticker, _product_code} = key, value) when is_map(value) do
    case Process.whereis(@name) do
      nil ->
        :ok

      pid ->
        send(pid, {:tick, key, value, System.monotonic_time(:millisecond)})
    end

    :ok
  end

  def notify_tick(_key, _value), do: :ok

  @impl true
  def init(opts) do
    {submitted, schedule_load?, ticks_ready_at} =
      submitted_boot(Keyword.get(opts, :load_submitted?, true))

    module = Keyword.get_lazy(opts, :module, &Strategy.module/0)
    params = normalize_params(Keyword.get_lazy(opts, :params, &Strategy.params/0))
    throttle_ms = Keyword.get(opts, :throttle_ms, Strategy.throttle_ms())

    revision_id =
      case Keyword.fetch(opts, :revision_id) do
        # 明示 UUID のみ上書き可。nil では provenance 無し起動にしない
        {:ok, id} when is_binary(id) and id != "" ->
          id

        {:ok, _invalid} ->
          raise ArgumentError,
                "revision_id must be a non-empty UUID string; omit the key to ensure from DB"

        :error ->
          case ensure_revision(module, params, throttle_ms, opts) do
            {:ok, %StrategyParameterRevision{id: id}} ->
              id

            {:error, error} ->
              raise "failed to ensure strategy parameter revision: #{inspect(error)}"
          end
      end

    state = %{
      module: module,
      params: params,
      throttle_ms: throttle_ms,
      revision_id: revision_id,
      # ロード完了まで nil。tick を無視して起動レースでの二重評価を防ぐ
      submitted: submitted,
      # この時刻より前に送られた tick はブート滞留とみなして破棄
      ticks_ready_at: ticks_ready_at,
      last_evaluated: %{}
    }

    if schedule_load? do
      send(self(), :load_submitted)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:load_submitted, state) do
    {:noreply,
     %{
       state
       | submitted: load_submitted_ids(),
         ticks_ready_at: System.monotonic_time(:millisecond)
     }}
  end

  def handle_info({:tick, {:ticker, product_code} = key, value, sent_at}, state)
      when is_integer(sent_at) do
    now = System.monotonic_time(:millisecond)

    state =
      cond do
        is_nil(state.submitted) or is_nil(state.ticks_ready_at) ->
          state

        # ロード完了前にキューされた tick（固定 100ms TTL より意図が明確）
        sent_at < state.ticks_ready_at ->
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
  defp submitted_boot(true), do: {nil, true, nil}
  defp submitted_boot(false), do: {MapSet.new(), false, System.monotonic_time(:millisecond)}
  defp submitted_boot(:pending), do: {nil, false, nil}

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(params) when is_list(params), do: Map.new(params)

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
        commands = evaluate_commands(state.module, market, state.params, product_code)

        pending_commands =
          Enum.filter(commands, fn command ->
            case command_id(command) do
              {:ok, id} ->
                not MapSet.member?(state.submitted, id)

              :error ->
                Bitflyer.Telemetry.log(
                  :error,
                  "strategy evaluated command without a valid internal_order_id",
                  %{command: inspect(command)}
                )

                false
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
              result = submit_command(command, state)
              maybe_settle(acc, command, result)
            end)

          %{state | submitted: submitted}
        end

      :error ->
        state
    end
  end

  defp evaluate_commands(module, market, params, product_code) do
    case module.evaluate(market, [], params) do
      commands when is_list(commands) ->
        commands

      other ->
        Bitflyer.Telemetry.log(
          :error,
          "strategy evaluate returned non-list",
          %{product_code: product_code, strategy: module, result: inspect(other)}
        )

        []
    end
  rescue
    error ->
      Bitflyer.Telemetry.log(
        :error,
        "strategy evaluate crashed: #{Exception.message(error)}",
        %{product_code: product_code, strategy: module}
      )

      []
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

  defp terminal_rejection?({:error, reason, meta}) do
    cond do
      reason in @retryable_errors ->
        false

      reason == :limit_exceeded and is_map(meta) and
          Map.get(meta, :limit) in @retryable_limit_kinds ->
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
  defp terminal_rejection?({:error, :limit_exceeded}), do: true
  defp terminal_rejection?({:error, %_{}}), do: true
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

  defp submit_command(command, state) when is_map(command) do
    command = attach_provenance(command, state)

    Bitflyer.Telemetry.log(
      :info,
      "strategy intent",
      %{
        internal_order_id: Map.get(command, :internal_order_id),
        product_code: Map.get(command, :product_code),
        side: Map.get(command, :side),
        strategy_parameter_revision_id: Map.get(command, :strategy_parameter_revision_id),
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

  defp attach_provenance(command, state) do
    command
    |> Map.put(:strategy_parameter_revision_id, state.revision_id)
    |> Map.put(:strategy_module, Atom.to_string(state.module))
    |> Map.put(:command_hash, Revision.command_hash(command))
  end

  defp ensure_revision(module, params, throttle_ms, opts) do
    Revision.ensure_current(
      module: module,
      params: params,
      throttle_ms: throttle_ms,
      source: Keyword.get(opts, :revision_source, :boot),
      operator: Keyword.get(opts, :revision_operator, "system")
    )
  end

  defp command_id(command) when is_map(command) do
    case Map.get(command, :internal_order_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  defp load_submitted_ids do
    since = submitted_lookback_since()
    prefix = Strategy.submitted_id_prefix()

    Order
    |> Ash.Query.select([:internal_order_id])
    |> Ash.Query.filter(inserted_at >= ^since)
    |> Ash.read()
    |> case do
      {:ok, orders} ->
        orders
        |> Enum.map(& &1.internal_order_id)
        |> Enum.filter(&(is_binary(&1) and &1 != "" and String.starts_with?(&1, prefix)))
        |> MapSet.new()

      {:error, error} ->
        raise "failed to load submitted order ids: #{inspect(error)}"
    end
  end

  defp submitted_lookback_since do
    days = Strategy.submitted_lookback_days()
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:microsecond)
  end
end
