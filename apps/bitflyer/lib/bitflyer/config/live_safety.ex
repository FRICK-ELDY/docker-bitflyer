defmodule Bitflyer.Config.LiveSafety do
  @moduledoc """
  live 起動時の安全既定。

  - Strategy は明示 `BITFLYER_STRATEGY_ENABLED=true` 以外では無効
  - `FixedOnce`（開発用自動成行）は live で有効化不可
  - Risk 上限は開発既定を使わず環境変数で明示必須（形式も起動時検証）

  `config/runtime.exs` から呼ぶ（Application 起動前でもモジュールは利用可）。
  """

  @risk_env_keys [
    {"BITFLYER_MAX_ORDER_SIZE", :max_order_size, :positive_decimal},
    {"BITFLYER_MAX_POSITION_SIZE", :max_position_size, :positive_decimal},
    {"BITFLYER_MAX_DAILY_LOSS", :max_daily_loss, :positive_decimal},
    {"BITFLYER_MAX_ORDERS_PER_MINUTE", :max_orders_per_minute, :non_neg_integer},
    {"BITFLYER_MAX_PRICE_DEVIATION_PCT", :max_price_deviation_pct, :positive_decimal}
  ]

  @doc """
  live 向けに Strategy / Risk を上書きする（runtime 結合の入口）。

  成功時は `{strategy_cfg, risk_cfg}`。不正時は `ArgumentError`。
  """
  @spec apply_live_overrides!(keyword(), keyword(), (String.t() -> String.t() | nil)) ::
          {keyword(), keyword()}
  def apply_live_overrides!(strategy_cfg, risk_cfg, getenv)
      when is_list(strategy_cfg) and is_list(risk_cfg) and is_function(getenv, 1) do
    strategy_module = Keyword.get(strategy_cfg, :module, Bitflyer.Strategy.FixedOnce)

    strategy_enabled = strategy_enabled_from_env(getenv.("BITFLYER_STRATEGY_ENABLED"))
    assert_strategy_allowed!(strategy_enabled, strategy_module)

    live_limits = require_risk_limits!(getenv)

    {Keyword.put(strategy_cfg, :enabled, strategy_enabled), Keyword.merge(risk_cfg, live_limits)}
  end

  @doc """
  `BITFLYER_STRATEGY_ENABLED`。`"true"` のみ有効。未設定・他値は無効。
  """
  @spec strategy_enabled_from_env(String.t() | nil) :: boolean()
  def strategy_enabled_from_env(nil), do: false

  def strategy_enabled_from_env(raw) when is_binary(raw), do: String.trim(raw) == "true"

  def strategy_enabled_from_env(_), do: false

  @doc """
  live で Strategy を有効にするとき、FixedOnce を拒否する。
  """
  @spec assert_strategy_allowed!(boolean(), module()) :: :ok
  def assert_strategy_allowed!(true, Bitflyer.Strategy.FixedOnce) do
    raise ArgumentError, """
    Bitflyer.Strategy.FixedOnce cannot be enabled when TRADE_MODE=live.

    Leave BITFLYER_STRATEGY_ENABLED unset (strategy stays disabled) for observe-only live,
    or deploy a live-approved strategy module in config before enabling.
    """
  end

  def assert_strategy_allowed!(true, module) when is_atom(module), do: :ok
  def assert_strategy_allowed!(false, _module), do: :ok

  @doc """
  live 必須の Risk 上限を環境変数から読む。欠落・空・不正形式は起動停止。

  `getenv` は `System.get_env/1` 互換（テスト注入用）。
  戻り値の型は `Limits.normalize/1` がそのまま受け取れる文字列／整数。
  """
  @spec require_risk_limits!((String.t() -> String.t() | nil)) :: keyword()
  def require_risk_limits!(getenv) when is_function(getenv, 1) do
    Enum.map(@risk_env_keys, fn {env_key, config_key, kind} ->
      raw = getenv.(env_key)
      {config_key, parse_risk_value!(env_key, kind, raw)}
    end)
  end

  defp parse_risk_value!(env_key, _kind, nil), do: raise_missing_risk_env!(env_key)

  defp parse_risk_value!(env_key, kind, raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      raise_missing_risk_env!(env_key)
    else
      parse_risk_trimmed!(env_key, kind, trimmed)
    end
  end

  defp parse_risk_value!(env_key, _kind, _), do: raise_missing_risk_env!(env_key)

  defp parse_risk_trimmed!(env_key, :positive_decimal, trimmed) do
    decimal =
      try do
        Decimal.new(trimmed)
      rescue
        Decimal.Error ->
          raise_invalid_risk_env!(env_key, trimmed, "positive decimal")
      end

    if Decimal.compare(decimal, 0) == :gt do
      trimmed
    else
      raise_invalid_risk_env!(env_key, trimmed, "positive decimal")
    end
  end

  defp parse_risk_trimmed!(env_key, :non_neg_integer, trimmed) do
    int =
      try do
        String.to_integer(trimmed)
      rescue
        ArgumentError ->
          raise_invalid_risk_env!(env_key, trimmed, "non-negative integer")
      end

    if int >= 0 do
      int
    else
      raise_invalid_risk_env!(env_key, trimmed, "non-negative integer")
    end
  end

  defp raise_missing_risk_env!(env_key) do
    raise ArgumentError, """
    #{env_key} is required when TRADE_MODE=live.

    Development Risk defaults (e.g. 1 BTC order / 5 BTC position / 100000 JPY daily loss)
    must not be used for live. Set live-specific limits explicitly.
    """
  end

  defp raise_invalid_risk_env!(env_key, value, expected) do
    raise ArgumentError, """
    #{env_key}=#{inspect(value)} is invalid when TRADE_MODE=live.

    Expected #{expected}.
    """
  end

  @doc false
  def risk_env_keys, do: Enum.map(@risk_env_keys, fn {env, key, _} -> {env, key} end)
end
