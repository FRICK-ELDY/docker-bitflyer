defmodule Bitflyer.Risk do
  @moduledoc """
  risk-manager の公開境界。

  strategy からの発注意図は必ず `authorize/2` を通す（fail-closed）。
  上限超過・stale・未同期は必ず拒否する。
  サーキットは `open_circuit/1` / `clear_circuit/1`。
  """

  require Ash.Query

  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Risk.{Circuit, Limits}
  alias Bitflyer.Trading.Position

  @type rejection_code ::
          :invalid_command
          | :unsynced
          | :circuit_open
          | :stale
          | :limit_exceeded

  @type result :: :ok | {:error, rejection_code(), map()}

  @doc """
  発注意図を認可する。失敗時は `{:error, code, meta}`。

  ## Options
  - `:readiness` — 既定 `Bitflyer.Readiness`
  - `:limits` — 上限上書き（`Limits.normalize/1` される）
  - `:positions` — 建玉リスト（未指定時は DB から当該銘柄を読む）
  - `:now` / `:server` — Cache.fresh?/3 へ転送
  - `:check_persisted_circuit` — 既定 false。true のとき Ready でも RiskState を見る（診断用。ホットパスでは使わない）
  """
  @spec authorize(map(), keyword()) :: result()
  def authorize(command, opts \\ []) when is_map(command) do
    limits =
      opts
      |> Keyword.get_lazy(:limits, &Limits.current/0)
      |> Limits.normalize()

    result =
      with :ok <- validate_command(command),
           :ok <- check_sync(opts),
           :ok <- check_freshness(command, limits, opts),
           :ok <- check_order_size(command, limits),
           :ok <- check_position_size(command, limits, opts) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, code, meta} = error ->
        emit_rejected(command, code, meta)
        error
    end
  end

  @doc """
  サーキットを開いて発注経路を閉じる。
  """
  @spec open_circuit(atom(), keyword()) :: :ok | {:error, term()}
  def open_circuit(reason, opts \\ []) when is_atom(reason) do
    Circuit.open(reason, opts)
  end

  @doc """
  サーキットを閉じる（RiskState 解除のあと Readiness.clear_halt）。
  """
  @spec clear_circuit(keyword()) :: :ok | {:error, term()}
  def clear_circuit(opts \\ []), do: Circuit.close(opts)

  @doc """
  サーキットが開いているか。
  """
  @spec circuit_open?(keyword()) :: boolean()
  def circuit_open?(opts \\ []), do: Circuit.open?(opts)

  defp validate_command(command) do
    product_code = Map.get(command, :product_code)
    side = Map.get(command, :side)
    size = Map.get(command, :size)
    market_key = Map.get(command, :market_key)

    cond do
      not is_binary(product_code) or product_code == "" ->
        {:error, :invalid_command, %{field: :product_code}}

      side not in [:buy, :sell] ->
        {:error, :invalid_command, %{field: :side}}

      not match?(%Decimal{}, size) ->
        {:error, :invalid_command, %{field: :size}}

      not Decimal.positive?(size) ->
        {:error, :invalid_command, %{field: :size}}

      is_nil(market_key) ->
        {:error, :invalid_command, %{field: :market_key}}

      true ->
        :ok
    end
  end

  defp check_sync(opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    case readiness.gate() do
      :ok ->
        # 実行時の正本は Readiness（ETS）。サーキット開は先に halt する設計のため
        # 既定では RiskState を読まない（発注ホットパスの DB 往復を避ける）。
        if Keyword.get(opts, :check_persisted_circuit, false) and
             Circuit.open?(readiness: readiness) do
          {:error, :circuit_open, %{source: :risk_state}}
        else
          :ok
        end

      {:error, :not_ready} ->
        {:error, :unsynced, %{readiness: :not_ready}}

      {:halted, reason} ->
        {:error, :circuit_open, %{readiness: reason}}
    end
  end

  defp check_freshness(command, limits, opts) do
    key = Map.fetch!(command, :market_key)
    max_age = limits.market_data_max_age_ms
    fresh_opts = Keyword.take(opts, [:now, :server])

    if Cache.fresh?(key, max_age, fresh_opts) do
      :ok
    else
      {:error, :stale, %{market_key: key, max_age_ms: max_age}}
    end
  end

  defp check_order_size(command, limits) do
    size = Map.fetch!(command, :size)

    if Decimal.gt?(size, limits.max_order_size) do
      {:error, :limit_exceeded,
       %{
         limit: :max_order_size,
         size: size,
         max: limits.max_order_size
       }}
    else
      :ok
    end
  end

  defp check_position_size(command, limits, opts) do
    size = Map.fetch!(command, :size)
    side = Map.fetch!(command, :side)
    product_code = Map.fetch!(command, :product_code)

    case fetch_positions(product_code, opts) do
      {:ok, positions} ->
        projected = projected_position_size(positions, product_code, side, size)

        if Decimal.gt?(projected, limits.max_position_size) do
          {:error, :limit_exceeded,
           %{
             limit: :max_position_size,
             projected: projected,
             max: limits.max_position_size,
             product_code: product_code
           }}
        else
          :ok
        end

      {:error, _error} ->
        # 建玉が読めないときは空とみなさない（fail-closed）
        {:error, :unsynced, %{reason: :position_load_failed, product_code: product_code}}
    end
  end

  defp fetch_positions(product_code, opts) do
    case Keyword.fetch(opts, :positions) do
      {:ok, positions} -> {:ok, positions || []}
      :error -> load_positions(product_code, opts)
    end
  end

  defp load_positions(product_code, opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    Position
    |> Ash.Query.filter(product_code == ^product_code and trade_mode == ^trade_mode)
    |> Ash.read()
  end

  defp projected_position_size(positions, product_code, side, size) do
    current =
      positions
      |> Enum.filter(&(Map.get(&1, :product_code) == product_code))
      |> Enum.reduce(Decimal.new(0), fn pos, acc ->
        pos_size = Map.get(pos, :size) || Decimal.new(0)

        signed =
          case Map.get(pos, :side) do
            :buy -> pos_size
            :sell -> Decimal.negate(pos_size)
            _ -> Decimal.new(0)
          end

        Decimal.add(acc, signed)
      end)

    delta =
      case side do
        :buy -> size
        :sell -> Decimal.negate(size)
      end

    current
    |> Decimal.add(delta)
    |> Decimal.abs()
  end

  defp emit_rejected(command, code, meta) do
    Bitflyer.Telemetry.execute(
      :risk_rejected,
      %{count: 1},
      %{
        rejection_code: code,
        reason: code,
        trade_mode: Bitflyer.TradeMode.current(),
        product_code: Map.get(command, :product_code) || Map.get(meta, :product_code),
        side: Map.get(command, :side)
      }
    )
  end
end
