defmodule Bitflyer.OrderExecutor do
  @moduledoc """
  order-executor の公開境界。

  `Risk.authorize/2` を通った意図だけを、取引モード別の出口へ送る。
  冪等キーは `internal_order_id`（Order の unique）。

  - `dry_run` — 送らず記録のみ（建玉は動かさない）
  - `paper` — 擬似約定 → datastore（取引所 REST は呼ばない）
  - `live` — `exchange_order_gate` 通過時のみ REST
  """

  require Ash.Query

  alias Bitflyer.OrderExecutor.{DryRun, Live, Paper}
  alias Bitflyer.Risk
  alias Bitflyer.TradeMode
  alias Bitflyer.Trading.Order

  @type result ::
          {:ok, Order.t()}
          | {:ok, Order.t(), :idempotent}
          | {:error, atom(), map()}

  @doc """
  注文を実行する。先に risk 認可し、既存 `internal_order_id` があれば再送しない。

  ## Options
  - Risk.authorize/2 と同じオプション（`:positions`, `:limits`, `:now`, `:server` 等）
  - `:trade_mode` — 出口上書き（既定は `TradeMode.current/0`）
  - `:persist_exchange_order_id` — live のみ。受注 ID 永続化の差し替え（テスト用）

  risk 認可は常に必須。公開 API からスキップできない。
  """
  @spec submit(map(), keyword()) :: result()
  def submit(command, opts \\ []) when is_map(command) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &TradeMode.current/0)

    with :ok <- validate_command(command),
         :ok <- authorize(command, opts),
         {:new, command} <- idempotent_lookup(command),
         {:ok, order} <- create_pending(command, trade_mode),
         {:ok, order} <- dispatch(order, command, trade_mode, opts) do
      emit_submitted(order)
      {:ok, order}
    else
      {:idempotent, %Order{} = order} ->
        {:ok, order, :idempotent}

      other ->
        other
    end
  end

  defp validate_command(command) do
    id = Map.get(command, :internal_order_id)
    product_code = Map.get(command, :product_code)
    side = Map.get(command, :side)
    size = Map.get(command, :size)
    order_type = Map.get(command, :order_type, :market)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :invalid_command, %{field: :internal_order_id}}

      not is_binary(product_code) or product_code == "" ->
        {:error, :invalid_command, %{field: :product_code}}

      side not in [:buy, :sell] ->
        {:error, :invalid_command, %{field: :side}}

      not match?(%Decimal{}, size) or not Decimal.positive?(size) ->
        {:error, :invalid_command, %{field: :size}}

      order_type not in [:limit, :market] ->
        {:error, :invalid_command, %{field: :order_type}}

      order_type == :limit and not valid_limit_price?(Map.get(command, :price)) ->
        {:error, :invalid_command, %{field: :price}}

      true ->
        :ok
    end
  end

  defp valid_limit_price?(%Decimal{} = price), do: Decimal.positive?(price)
  defp valid_limit_price?(_), do: false

  defp authorize(command, opts) do
    case Risk.authorize(command, opts) do
      :ok -> :ok
      {:error, code, meta} -> {:error, code, meta}
    end
  end

  defp idempotent_lookup(command) do
    id = Map.fetch!(command, :internal_order_id)

    case fetch_order(id) do
      {:ok, %Order{} = order} -> {:idempotent, order}
      {:ok, nil} -> {:new, command}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp create_pending(command, trade_mode) do
    order_type = Map.get(command, :order_type, :market)

    attrs = %{
      internal_order_id: Map.fetch!(command, :internal_order_id),
      product_code: Map.fetch!(command, :product_code),
      side: Map.fetch!(command, :side),
      size: Map.fetch!(command, :size),
      order_type: order_type,
      price: Map.get(command, :price),
      status: :pending,
      trade_mode: trade_mode
    }

    case Order |> Ash.Changeset.for_create(:create, attrs) |> Ash.create() do
      {:ok, order} ->
        {:ok, order}

      {:error, error} ->
        # 競合時は既存行を返す（二重 REST を防ぐ）
        case fetch_order(attrs.internal_order_id) do
          {:ok, %Order{} = order} -> {:idempotent, order}
          _ -> {:error, :persist_failed, %{error: error}}
        end
    end
  end

  defp dispatch(order, command, :dry_run, opts), do: DryRun.execute(order, command, opts)
  defp dispatch(order, command, :paper, opts), do: Paper.execute(order, command, opts)
  defp dispatch(order, command, :live, opts), do: Live.execute(order, command, opts)

  defp fetch_order(internal_order_id) do
    Order
    |> Ash.Query.filter(internal_order_id == ^internal_order_id)
    |> Ash.read_one()
  end

  defp emit_submitted(%Order{} = order) do
    Bitflyer.Telemetry.execute(
      :order_submitted,
      %{count: 1},
      %{
        internal_order_id: order.internal_order_id,
        exchange_order_id: order.exchange_order_id,
        product_code: order.product_code,
        side: order.side,
        trade_mode: order.trade_mode,
        status: order.status
      }
    )
  end
end
