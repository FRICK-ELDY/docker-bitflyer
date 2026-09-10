defmodule Bitflyer.Telemetry do
  @moduledoc """
  取引ドメインの telemetry / 構造化ログ語彙の正本。

  エンジン実装より先にイベント名を固定する。改名すると過去ログと
  LiveDashboard が繋がらなくなるため、追加はあってもリネームは避ける。

  メタデータは allowlist のみ通す（秘密キーを allowlist に入れないこと）。
  """

  require Logger

  @type event_key ::
          :market_data_tick
          | :market_data_disconnected
          | :risk_rejected
          | :order_submitted
          | :order_filled
          | :reconcile_mismatch
          | :circuit_opened
          | :readiness_changed
          | :health_unhealthy

  @events %{
    market_data_tick: [:bitflyer, :market_data, :tick],
    market_data_disconnected: [:bitflyer, :market_data, :disconnected],
    risk_rejected: [:bitflyer, :risk, :rejected],
    order_submitted: [:bitflyer, :order, :submitted],
    order_filled: [:bitflyer, :order, :filled],
    reconcile_mismatch: [:bitflyer, :reconcile, :mismatch],
    circuit_opened: [:bitflyer, :circuit, :opened],
    readiness_changed: [:bitflyer, :readiness, :changed],
    health_unhealthy: [:bitflyer, :health, :unhealthy]
  }

  @metadata_allowlist MapSet.new([
                        :trade_mode,
                        :readiness,
                        :reason,
                        :status,
                        :from,
                        :to,
                        :internal_order_id,
                        :exchange_order_id,
                        :product_code,
                        :side,
                        :rejection_code,
                        :circuit_reason,
                        :db,
                        :healthy,
                        :count,
                        :kind,
                        :currency,
                        :limit,
                        :operator,
                        :snapshot_hash,
                        :timeout_ms,
                        :skew_ms,
                        :max_ms
                      ])

  @doc """
  定義済みイベント（キー → telemetry イベント名）。
  """
  @spec events() :: %{event_key() => [atom()]}
  def events, do: @events

  @doc """
  イベントキーに対応する telemetry イベント名。
  """
  @spec event(event_key()) :: [atom()]
  def event(key) when is_map_key(@events, key), do: Map.fetch!(@events, key)

  @doc """
  LiveDashboard 用のメトリクス名（`bitflyer.readiness.changed.count` 形式）。
  """
  @spec metric_names() :: [String.t()]
  def metric_names do
    @events
    |> Map.values()
    |> Enum.map(fn event -> Enum.map_join(event, ".", &Atom.to_string/1) <> ".count" end)
    |> Enum.sort()
  end

  @doc """
  構造化メタデータの許可キー。
  """
  @spec metadata_allowlist() :: MapSet.t(atom())
  def metadata_allowlist, do: @metadata_allowlist

  @doc """
  telemetry を発行する。metadata は allowlist で濾過する。
  """
  @spec execute(event_key(), map(), map() | keyword()) :: :ok
  def execute(key, measurements \\ %{}, metadata \\ %{})

  def execute(key, measurements, metadata) when is_map(measurements) do
    :telemetry.execute(event(key), measurements, sanitize_metadata(metadata))
  end

  @doc """
  構造化ログ。metadata は allowlist のみ Logger に載せる。
  """
  @spec log(Logger.level(), String.t(), keyword() | map()) :: :ok
  def log(level, message, metadata \\ []) when is_binary(message) do
    Logger.log(level, message, Map.to_list(sanitize_metadata(metadata)))
  end

  @doc """
  プロセスの Logger.metadata に許可キーだけを載せる。
  """
  @spec put_logger_metadata(keyword() | map()) :: :ok
  def put_logger_metadata(metadata) do
    Logger.metadata(Map.to_list(sanitize_metadata(metadata)))
    :ok
  end

  @doc """
  秘密を含みうるメタデータを allowlist で落とす。
  """
  @spec sanitize_metadata(map() | keyword()) :: map()
  def sanitize_metadata(metadata) when is_list(metadata) do
    sanitize_metadata(Map.new(metadata))
  end

  def sanitize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case normalize_key(key) do
        {:ok, atom_key} ->
          if allowed_metadata_key?(atom_key) do
            Map.put(acc, atom_key, value)
          else
            acc
          end

        :error ->
          acc
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, key}

  defp normalize_key(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp normalize_key(_), do: :error

  defp allowed_metadata_key?(key), do: MapSet.member?(@metadata_allowlist, key)
end
