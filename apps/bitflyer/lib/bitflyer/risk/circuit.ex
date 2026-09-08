defmodule Bitflyer.Risk.Circuit do
  @moduledoc """
  リスクサーキットの開閉。

  開くときはメモリ（Readiness）を先に halt し、RiskState に永続化する。
  再起動後も Boot reconcile が永続 halt を見て Ready にしない。
  """

  require Ash.Query

  alias Bitflyer.Trading.RiskState

  @default_name "default"

  @doc """
  サーキットが開いているか（Readiness halted または永続 RiskState）。
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

  defp persisted_halted? do
    case RiskState
         |> Ash.Query.filter(name == ^@default_name)
         |> Ash.read_one() do
      {:ok, %RiskState{halted: true}} -> true
      _ -> false
    end
  end

  defp persist_halt(reason) do
    halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reason_str = Atom.to_string(reason)

    attrs = %{
      name: @default_name,
      halted: true,
      reason: reason_str,
      halted_at: halted_at
    }

    case RiskState
         |> Ash.Query.filter(name == ^@default_name)
         |> Ash.read_one() do
      {:ok, nil} ->
        case RiskState |> Ash.Changeset.for_create(:create, attrs) |> Ash.create() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:ok, %RiskState{} = risk} ->
        case risk
             |> Ash.Changeset.for_update(:update, Map.take(attrs, [:halted, :reason, :halted_at]))
             |> Ash.update() do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
