defmodule Bitflyer.Config.LiveSafetyTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Config.LiveSafety

  @valid_env %{
    "BITFLYER_MAX_ORDER_SIZE" => "0.01",
    "BITFLYER_MAX_POSITION_SIZE" => "0.02",
    "BITFLYER_MAX_DAILY_LOSS" => "10000",
    "BITFLYER_MAX_ORDERS_PER_MINUTE" => "5",
    "BITFLYER_MAX_PRICE_DEVIATION_PCT" => "1"
  }

  defp getenv(env), do: fn key -> Map.get(env, key) end

  test "strategy_enabled_from_env only accepts exact true" do
    refute LiveSafety.strategy_enabled_from_env(nil)
    refute LiveSafety.strategy_enabled_from_env("")
    refute LiveSafety.strategy_enabled_from_env("1")
    refute LiveSafety.strategy_enabled_from_env("TRUE")
    assert LiveSafety.strategy_enabled_from_env("true")
    assert LiveSafety.strategy_enabled_from_env(" true ")
  end

  test "assert_strategy_allowed! rejects FixedOnce when enabled" do
    assert_raise ArgumentError, ~r/FixedOnce cannot be enabled/, fn ->
      LiveSafety.assert_strategy_allowed!(true, Bitflyer.Strategy.FixedOnce)
    end

    assert :ok = LiveSafety.assert_strategy_allowed!(false, Bitflyer.Strategy.FixedOnce)
    assert :ok = LiveSafety.assert_strategy_allowed!(true, Bitflyer.Strategy)
  end

  test "require_risk_limits! demands all live env keys" do
    assert_raise ArgumentError, ~r/BITFLYER_MAX_ORDER_SIZE/, fn ->
      LiveSafety.require_risk_limits!(fn _ -> nil end)
    end

    limits = LiveSafety.require_risk_limits!(getenv(@valid_env))

    assert limits[:max_order_size] == "0.01"
    assert limits[:max_position_size] == "0.02"
    assert limits[:max_daily_loss] == "10000"
    assert limits[:max_orders_per_minute] == 5
    assert limits[:max_price_deviation_pct] == "1"
  end

  test "require_risk_limits! rejects non-decimal and non-positive values" do
    assert_raise ArgumentError, ~r/invalid/, fn ->
      LiveSafety.require_risk_limits!(
        getenv(Map.put(@valid_env, "BITFLYER_MAX_ORDER_SIZE", "abc"))
      )
    end

    assert_raise ArgumentError, ~r/invalid/, fn ->
      LiveSafety.require_risk_limits!(getenv(Map.put(@valid_env, "BITFLYER_MAX_DAILY_LOSS", "0")))
    end

    assert_raise ArgumentError, ~r/invalid/, fn ->
      LiveSafety.require_risk_limits!(
        getenv(Map.put(@valid_env, "BITFLYER_MAX_ORDERS_PER_MINUTE", "1.5"))
      )
    end

    assert_raise ArgumentError, ~r/invalid/, fn ->
      LiveSafety.require_risk_limits!(
        getenv(Map.put(@valid_env, "BITFLYER_MAX_ORDERS_PER_MINUTE", "-1"))
      )
    end
  end

  test "apply_live_overrides! mirrors runtime live boot path" do
    strategy_cfg = [
      enabled: true,
      module: Bitflyer.Strategy.FixedOnce,
      params: [size: "0.01"]
    ]

    risk_cfg = [max_order_size: "1", max_position_size: "5"]

    {strategy, risk} =
      LiveSafety.apply_live_overrides!(strategy_cfg, risk_cfg, getenv(@valid_env))

    assert strategy[:enabled] == false
    assert strategy[:module] == Bitflyer.Strategy.FixedOnce
    assert risk[:max_order_size] == "0.01"
    assert risk[:max_orders_per_minute] == 5
    # 既存キーは残す
    assert risk[:max_position_size] == "0.02"
  end

  test "apply_live_overrides! rejects enabling FixedOnce on live path" do
    assert_raise ArgumentError, ~r/FixedOnce cannot be enabled/, fn ->
      LiveSafety.apply_live_overrides!(
        [enabled: false, module: Bitflyer.Strategy.FixedOnce],
        [],
        getenv(Map.put(@valid_env, "BITFLYER_STRATEGY_ENABLED", "true"))
      )
    end
  end

  test "apply_live_overrides! allows non-FixedOnce when explicitly enabled" do
    {strategy, _risk} =
      LiveSafety.apply_live_overrides!(
        [enabled: false, module: Bitflyer.Strategy],
        [],
        getenv(Map.put(@valid_env, "BITFLYER_STRATEGY_ENABLED", "true"))
      )

    assert strategy[:enabled] == true
    assert strategy[:module] == Bitflyer.Strategy
  end
end
