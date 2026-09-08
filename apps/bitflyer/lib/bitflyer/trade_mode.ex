defmodule Bitflyer.TradeMode do
  @moduledoc """
  取引モードの正本。

  許可値は `dry_run` / `paper` / `live` のみ。不正値は起動時に停止する。
  `live` でも `BITFLYER_LIVE_CONFIRM`（UTC 日付）と Ready が揃うまで
  取引所への発注は許可しない。

  環境変数の初期パースは `config/runtime.exs` 側（stdlib のみ）で行い、
  本モジュールは起動後の判定・述語の正本とする。許可値と confirm 規則を変えるときは両方を更新すること。
  """

  @type t :: :dry_run | :paper | :live

  @allowed ~w(dry_run paper live)

  @doc """
  環境変数などからモードを atom へ正規化する。許可値以外は raise。
  """
  @spec parse!(term()) :: t()
  def parse!(raw) when is_binary(raw) do
    case parse(raw) do
      {:ok, mode} ->
        mode

      {:error, reason} ->
        raise ArgumentError, """
        invalid TRADE_MODE #{inspect(raw)} (#{reason}).
        Allowed values: #{Enum.join(@allowed, ", ")}.
        """
    end
  end

  def parse!(raw) do
    raise ArgumentError, "TRADE_MODE must be a string, got: #{inspect(raw)}"
  end

  @doc """
  許可値なら `{:ok, mode}`、それ以外は `{:error, reason}`。
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(raw) when is_binary(raw) do
    case String.trim(raw) do
      "dry_run" -> {:ok, :dry_run}
      "paper" -> {:ok, :paper}
      "live" -> {:ok, :live}
      "" -> {:error, "empty"}
      _ -> {:error, "not in #{inspect(@allowed)}"}
    end
  end

  def parse(_), do: {:error, "not a string"}

  @doc """
  現在の取引モード（Application env。未設定時は `:dry_run`）。
  """
  @spec current() :: t()
  def current do
    case Application.get_env(:bitflyer, :trade_mode, :dry_run) do
      mode when mode in [:dry_run, :paper, :live] -> mode
      raw when is_binary(raw) -> parse!(raw)
      other -> parse!(Kernel.to_string(other))
    end
  end

  @spec dry_run?(t()) :: boolean()
  def dry_run?(mode \\ current()), do: mode == :dry_run

  @spec paper?(t()) :: boolean()
  def paper?(mode \\ current()), do: mode == :paper

  @spec live?(t()) :: boolean()
  def live?(mode \\ current()), do: mode == :live

  @doc """
  このモードの出口が取引所 REST か（許可状態とは別。live でも未解禁なら送らない）。
  """
  @spec orders_reach_exchange?(t()) :: boolean()
  def orders_reach_exchange?(mode \\ current()), do: mode == :live

  @doc """
  `BITFLYER_LIVE_CONFIRM` が当日 UTC の `YYYY-MM-DD` と一致するか。
  """
  @spec valid_live_confirm?(String.t() | nil, Date.t()) :: boolean()
  def valid_live_confirm?(confirm, today \\ Date.utc_today())

  def valid_live_confirm?(confirm, %Date{} = today) when is_binary(confirm) do
    String.trim(confirm) == Date.to_iso8601(today)
  end

  def valid_live_confirm?(_, _), do: false

  @doc """
  起動時に確定した live 二重確認フラグ。
  """
  @spec live_confirmed?() :: boolean()
  def live_confirmed? do
    Application.get_env(:bitflyer, :live_confirmed, false) == true
  end

  @doc """
  Ready か。正本は `Bitflyer.Readiness`。
  """
  @spec ready?() :: boolean()
  def ready? do
    Bitflyer.Readiness.ready?()
  end

  @doc """
  取引所へ実発注してよいか。live + 二重確認 + Ready のときだけ true。
  """
  @spec exchange_orders_permitted?() :: boolean()
  def exchange_orders_permitted? do
    exchange_order_gate() == :ok
  end

  @doc """
  発注ゲートの結果。将来の executor / UI / health が同じ判定を使う。
  """
  @spec exchange_order_gate() :: :ok | {:halted, atom()}
  def exchange_order_gate do
    cond do
      not live?(current()) ->
        {:halted, :not_live_mode}

      not live_confirmed?() ->
        {:halted, :live_confirm_missing}

      true ->
        case Bitflyer.Readiness.gate() do
          :ok -> :ok
          {:error, :not_ready} -> {:halted, :not_ready}
          {:halted, reason} -> {:halted, reason}
        end
    end
  end

  @doc """
  表示用文字列。
  """
  @spec name(t()) :: String.t()
  def name(mode) when mode in [:dry_run, :paper, :live], do: Atom.to_string(mode)
end
