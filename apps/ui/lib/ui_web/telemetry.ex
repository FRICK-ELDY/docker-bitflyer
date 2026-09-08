defmodule UiWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # bitFlyer domain vocabulary（正本は Bitflyer.Telemetry）
      counter("bitflyer.market_data.tick.count"),
      counter("bitflyer.market_data.disconnected.count"),
      counter("bitflyer.risk.rejected.count"),
      counter("bitflyer.order.submitted.count"),
      counter("bitflyer.order.filled.count"),
      counter("bitflyer.reconcile.mismatch.count"),
      counter("bitflyer.circuit.opened.count"),
      counter("bitflyer.readiness.changed.count",
        tags: [:to, :trade_mode],
        tag_values: &bitflyer_tag_values/1
      ),
      counter("bitflyer.health.unhealthy.count",
        tags: [:status, :reason],
        tag_values: &bitflyer_tag_values/1
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp bitflyer_tag_values(metadata) do
    Map.new(metadata, fn
      {key, nil} -> {key, ""}
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      {key, value} when is_binary(value) -> {key, value}
      {key, value} -> {key, inspect(value)}
    end)
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {UiWeb, :count_users, []}
    ]
  end
end
