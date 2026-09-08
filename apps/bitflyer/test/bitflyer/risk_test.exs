defmodule Bitflyer.RiskTest do
  use Bitflyer.DataCase, async: false

  require Ash.Query

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Readiness
  alias Bitflyer.Risk
  alias Bitflyer.Trading.RiskState

  @market_key {:ticker, "FX_BTC_JPY"}

  setup do
    reset_readiness()
    reset_market_data_cache()
    clear_default_risk_state()

    on_exit(fn ->
      reset_readiness()
      reset_market_data_cache()
    end)

    :ok
  end

  test "authorize rejects unsynced when not ready" do
    assert Readiness.get() == :not_ready
    put_fresh_market()

    assert {:error, :unsynced, _} = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects stale market data" do
    assert Readiness.mark_ready() == :ok

    assert {:error, :stale, %{market_key: @market_key}} =
             Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects order size over limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_order_size: Decimal.new("0.01"),
      max_position_size: Decimal.new("5"),
      market_data_max_age_ms: 5_000
    }

    assert {:error, :limit_exceeded, %{limit: :max_order_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("0.02")}),
               positions: [],
               limits: limits
             )
  end

  test "authorize rejects projected position over limit" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    limits = %{
      max_order_size: Decimal.new("1"),
      max_position_size: Decimal.new("0.05"),
      market_data_max_age_ms: 5_000
    }

    positions = [
      %{product_code: "FX_BTC_JPY", side: :buy, size: Decimal.new("0.04")}
    ]

    assert {:error, :limit_exceeded, %{limit: :max_position_size}} =
             Risk.authorize(
               valid_command(%{size: Decimal.new("0.02")}),
               positions: positions,
               limits: limits
             )
  end

  test "authorize accepts a valid command when ready and fresh" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Risk.authorize(valid_command(), positions: [])
  end

  test "authorize rejects when circuit is open and open_circuit persists RiskState" do
    assert Readiness.mark_ready() == :ok
    put_fresh_market()

    assert :ok = Risk.open_circuit(:limit_exceeded)
    assert Readiness.get() == {:halted, :limit_exceeded}
    assert Risk.circuit_open?()

    assert {:error, :circuit_open, _} =
             Risk.authorize(valid_command(), positions: [])

    assert {:ok, %RiskState{halted: true, reason: "limit_exceeded"}} =
             RiskState
             |> Ash.Query.filter(name == "default")
             |> Ash.read_one()
  end

  test "authorize emits risk_rejected telemetry" do
    parent = self()
    handler_id = "risk-rejected-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :risk, :rejected],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :unsynced, _} = Risk.authorize(valid_command(), positions: [])

    assert_receive {:telemetry, [:bitflyer, :risk, :rejected], %{count: 1}, metadata}
    assert metadata.rejection_code == :unsynced
  end

  defp valid_command(overrides \\ %{}) do
    Map.merge(
      %{
        product_code: "FX_BTC_JPY",
        side: :buy,
        size: Decimal.new("0.01"),
        market_key: @market_key,
        intent_id: "intent-1"
      },
      overrides
    )
  end

  defp put_fresh_market do
    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}) == :ok
  end

  defp clear_default_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, nil} -> :ok
      {:ok, risk} -> Ash.destroy!(risk)
      {:error, _} -> :ok
    end
  end
end
