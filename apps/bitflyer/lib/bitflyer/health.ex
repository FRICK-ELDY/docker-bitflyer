defmodule Bitflyer.Health do
  @moduledoc """
  稼働判定の集約。UI の `/health`・将来の監視が同じ結果を読む。

  HTTP の目安:

  - DB 不可または readiness が halted → 非健全（503）
  - DB 可かつ `:not_ready` / `:ready` → 健全（200）。起動途中の `:not_ready` でも
    Compose healthcheck は通す（Ready 化は boot reconcile の責務）
  """

  @type status :: :ready | :not_ready | :halted | :unavailable

  @type t :: %{
          status: status(),
          healthy?: boolean(),
          db: boolean(),
          db_error: String.t() | nil,
          readiness: Bitflyer.Readiness.state(),
          trade_mode: Bitflyer.TradeMode.t(),
          reason: atom() | nil
        }

  @doc """
  現時点のヘルススナップショット。
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    database = Keyword.get(opts, :database, &Bitflyer.System.check_database/0)
    readiness = Keyword.get(opts, :readiness, &Bitflyer.Readiness.get/0)
    trade_mode = Keyword.get(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    build(database.(), readiness.(), trade_mode.())
  end

  @doc """
  DB 結果と readiness からスナップショットを組み立てる（単体テスト用）。
  """
  @spec build(
          :ok | {:error, String.t()},
          Bitflyer.Readiness.state(),
          Bitflyer.TradeMode.t()
        ) :: t()
  def build(db_result, readiness, trade_mode) do
    {db_ok?, db_error} =
      case db_result do
        :ok -> {true, nil}
        {:error, message} when is_binary(message) -> {false, message}
      end

    {status, reason} = classify(db_ok?, readiness)

    %{
      status: status,
      healthy?: healthy?(status),
      db: db_ok?,
      db_error: db_error,
      readiness: readiness,
      trade_mode: trade_mode,
      reason: reason
    }
  end

  @doc """
  JSON 向けの平らなマップ。
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%{} = health) do
    %{
      "status" => Atom.to_string(health.status),
      "db" => health.db,
      "trade_mode" => Bitflyer.TradeMode.name(health.trade_mode),
      "readiness" => Bitflyer.Readiness.format(health.readiness),
      "reason" =>
        case health.reason do
          nil -> nil
          reason when is_atom(reason) -> Atom.to_string(reason)
        end
    }
    |> maybe_put_db_error(health.db_error)
  end

  defp classify(false, _readiness), do: {:unavailable, :database_unavailable}

  defp classify(true, :ready), do: {:ready, nil}
  defp classify(true, :not_ready), do: {:not_ready, nil}
  defp classify(true, {:halted, reason}), do: {:halted, reason}

  defp healthy?(:unavailable), do: false
  defp healthy?(:halted), do: false
  defp healthy?(:ready), do: true
  defp healthy?(:not_ready), do: true

  defp maybe_put_db_error(map, nil), do: map
  defp maybe_put_db_error(map, message), do: Map.put(map, "db_error", message)
end
