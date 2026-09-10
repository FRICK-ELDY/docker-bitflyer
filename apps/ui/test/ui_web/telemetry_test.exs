defmodule UiWeb.TelemetryTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:ui, :metrics_console_reporter)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ui, :metrics_console_reporter)
      else
        Application.put_env(:ui, :metrics_console_reporter, previous)
      end
    end)

    :ok
  end

  test "console reporter child is included when enabled" do
    Application.put_env(:ui, :metrics_console_reporter, true)

    assert [{Telemetry.Metrics.ConsoleReporter, opts}] =
             UiWeb.Telemetry.console_reporter_children()

    assert Keyword.has_key?(opts, :metrics)
  end

  test "console reporter child is omitted when disabled" do
    Application.put_env(:ui, :metrics_console_reporter, false)
    assert UiWeb.Telemetry.console_reporter_children() == []
  end

  test "console metrics exclude high-churn tick / phoenix / vm" do
    names =
      UiWeb.Telemetry.console_metrics()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    refute MapSet.member?(names, [:bitflyer, :market_data, :tick, :count])
    refute Enum.any?(names, &List.starts_with?(&1, [:phoenix]))
    refute Enum.any?(names, &List.starts_with?(&1, [:vm]))
    assert MapSet.member?(names, [:bitflyer, :circuit, :opened, :count])
    assert MapSet.member?(names, [:bitflyer, :order, :submitted, :count])
  end

  test "metrics include bitflyer domain counters" do
    names =
      UiWeb.Telemetry.metrics()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert MapSet.member?(names, [:bitflyer, :market_data, :tick, :count])
    assert MapSet.member?(names, [:bitflyer, :circuit, :opened, :count])
    assert MapSet.member?(names, [:bitflyer, :readiness, :changed, :count])
  end
end
