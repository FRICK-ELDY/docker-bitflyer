defmodule Bitflyer.Risk.Circuit do
  @moduledoc """
  リスクサーキットの開閉。

  開くときはメモリ（Readiness）を先に halt し、RiskState に永続化する。
  閉じるときは RiskState を先に解除し、その後 Readiness.clear_halt する。
  再起動後も Boot reconcile が永続 halt を見て Ready にしない。
  """

  require Ash.Query

  alias Bitflyer.Trading.RiskState

  @default_name "default"

  @doc """
  サーキットが開いているか（Readiness halted または永続 RiskState）。

  RiskState 読取失敗時は true（fail-closed）。
  """
  @spec open?(keyword()) :: boolean()
  def open?(opts \\ []) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    case readiness.get() do
      {:halted, _} -> true
      _ -> persisted_halted?()
    end
  end

  @doc """
  永続 RiskState の halt 理由。未 halt は `:clear`、読取失敗は `:unsynced`（fail-closed）。
  """
  @spec persisted_halt_reason() :: {:halted, atom()} | :clear | :unsynced
  def persisted_halt_reason do
    case RiskState
         |> Ash.Query.filter(name == ^@default_name)
         |> Ash.read_one() do
      {:ok, %RiskState{halted: true, reason: reason}} ->
        {:halted, Bitflyer.Risk.HaltReason.from_string(reason)}

      {:ok, _} ->
        :clear

      {:error, _} ->
        :unsynced
    end
  end

  @doc """
  サーキットを開く。発注経路を閉じ、状態を永続化する。
  """
  @spec open(atom(), keyword()) :: :ok | {:error, term()}
  def open(reason, opts \\ []) when is_atom(reason) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    Bitflyer.Telemetry.execute(
      :circuit_opened,
      %{count: 1},
      %{
        circuit_reason: reason,
        reason: reason,
        trade_mode: Bitflyer.TradeMode.current()
      }
    )

    _ = readiness.halt(reason)

    case persist_halt(reason) do
      :ok ->
        :ok

      {:error, error} ->
        Bitflyer.Telemetry.log(
          :error,
          "Failed to persist risk circuit: #{inspect(error)}",
          %{reason: reason, trade_mode: Bitflyer.TradeMode.current()}
        )

        {:error, error}
    end
  end

  @doc """
  サーキットを閉じる。RiskState を先に解除し、その後 Readiness の halt を外す。
  """
  @spec close(keyword()) :: :ok | {:error, term()}
  def close(opts \\ []) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    case persist_clear() do
      :ok ->
        case readiness.clear_halt() do
          :ok -> :ok
          {:error, :not_halted} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        Bitflyer.Telemetry.log(
          :error,
          "Failed to clear persisted risk circuit: #{inspect(error)}",
          %{trade_mode: Bitflyer.TradeMode.current()}
        )

        {:error, error}
    end
  end

  defp persisted_halted? do
    case RiskState
         |> Ash.Query.filter(name == ^@default_name)
         |> Ash.read_one() do
      {:ok, %RiskState{halted: true}} -> true
      {:ok, _} -> false
      {:error, _error} -> true
    end
  end

  defp persist_halt(reason) do
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      name: @default_name,
      halted: true,
      reason: Atom.to_string(reason),
      halted_at: halted_at
    }

    upsert_risk_state(attrs)
  end

  defp persist_clear do
    attrs = %{
      name: @default_name,
      halted: false,
      reason: nil,
      halted_at: nil
    }

    upsert_risk_state(attrs)
  end

  defp upsert_risk_state(attrs) do
    case RiskState
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(
           upsert?: true,
           upsert_identity: :unique_name,
           upsert_fields: [:halted, :reason, :halted_at, :updated_at]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
