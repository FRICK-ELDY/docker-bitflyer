defmodule Bitflyer.Strategy.Runner do
  @moduledoc """
  Feed の tick を受け、Strategy → Risk → Executor へ渡す駆動役。

  Ready 前の拒否は再試行する。受理済みは `internal_order_id` 単位で記録し、
  部分成功時も未受理分だけ再送する。銘柄ごとに `throttle_ms` で評価頻度を制限する。
  """

  use GenServer

  alias Bitflyer.Strategy

  @name __MODULE__

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
    state = %{
      module: Keyword.get_lazy(opts, :module, &Strategy.module/0),
      params: Keyword.get_lazy(opts, :params, &Strategy.params/0),
      throttle_ms: Keyword.get(opts, :throttle_ms, Strategy.throttle_ms()),
      submitted: MapSet.new(),
      last_evaluated: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, {:ticker, product_code} = key, value}, state) do
    now = System.monotonic_time(:millisecond)

    state =
      cond do
        not Strategy.enabled?() ->
          state

        throttled?(state, product_code, now) ->
          state

        true ->
          state = %{state | last_evaluated: Map.put(state.last_evaluated, product_code, now)}
          maybe_submit(product_code, key, value, state)
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

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

              case {accepted?(result), command_id(command)} do
                {true, {:ok, id}} -> MapSet.put(acc, id)
                _ -> acc
              end
            end)

          %{state | submitted: submitted}
        end

      :error ->
        state
    end
  end

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
  end

  defp command_id(command) when is_map(command) do
    case Map.get(command, :internal_order_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  defp accepted?({:ok, _order}), do: true
  defp accepted?({:ok, _order, :idempotent}), do: true
  defp accepted?(_), do: false
end
