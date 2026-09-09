defmodule Bitflyer.Strategy.Runner do
  @moduledoc """
  Feed の tick を受け、Strategy → Risk → Executor へ渡す駆動役。

  Ready 前の拒否は再試行する。submit 成功（または冪等）後は銘柄ごとに止める。
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
      submitted: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, {:ticker, product_code} = key, value}, state) do
    state =
      cond do
        not Strategy.enabled?() ->
          state

        MapSet.member?(state.submitted, product_code) ->
          state

        true ->
          maybe_submit(product_code, key, value, state)
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_submit(product_code, key, value, state) do
    case build_market(product_code, key, value) do
      {:ok, market} ->
        commands = state.module.evaluate(market, [], state.params)

        Bitflyer.Telemetry.log(
          :info,
          "strategy evaluated",
          %{
            product_code: product_code,
            strategy: state.module,
            command_count: length(commands),
            trade_mode: Bitflyer.TradeMode.current()
          }
        )

        if commands == [] do
          state
        else
          results = Enum.map(commands, &submit_command/1)

          if Enum.any?(results, &accepted?/1) do
            %{state | submitted: MapSet.put(state.submitted, product_code)}
          else
            state
          end
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

  defp accepted?({:ok, _order}), do: true
  defp accepted?({:ok, _order, :idempotent}), do: true
  defp accepted?(_), do: false
end
