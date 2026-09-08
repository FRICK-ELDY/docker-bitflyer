defmodule Bitflyer.Startup.Reconcile do
  @moduledoc """
  起動・定期突合の純論理。

  1. datastore から内部状態を復元する
  2. モード別に突合する（dry_run/paper は内部正、live は取引所）
  3. 不整合なら `{:error, reason}` — Ready にはしない

  Ready / RiskState への書き込みは `Bitflyer.Startup.Reconciler` 側。
  """

  require Ash.Query

  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position, RiskState}

  @type reason ::
          :reconcile_mismatch
          | :restore_failed
          | :exchange_unavailable
          | :risk_halted
          | atom()

  @type internal_state :: %{
          trade_mode: Bitflyer.TradeMode.t(),
          risk_state: struct() | nil,
          positions: [struct()],
          balance_snapshots: [struct()],
          open_orders: [struct()]
        }

  @type result :: {:ok, internal_state()} | {:error, reason(), map()}

  @known_reasons MapSet.new([
                   :reconcile_mismatch,
                   :restore_failed,
                   :exchange_unavailable,
                   :risk_halted
                 ])

  @doc """
  復元 → 突合。成功時は内部スナップショット、失敗時は reason。
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    with {:ok, internal} <- restore(trade_mode),
         :ok <- check_persisted_risk(internal),
         :ok <- reconcile_mode(internal, exchange) do
      {:ok, internal}
    end
  end

  @doc """
  現モードの永続状態を読み出す。
  """
  @spec restore(Bitflyer.TradeMode.t()) ::
          {:ok, internal_state()} | {:error, :restore_failed, map()}
  def restore(trade_mode) do
    with {:ok, risk_state} <- read_risk_state(),
         {:ok, positions} <- read_positions(trade_mode),
         {:ok, balance_snapshots} <- read_latest_balances(trade_mode),
         {:ok, open_orders} <- read_open_orders(trade_mode) do
      {:ok,
       %{
         trade_mode: trade_mode,
         risk_state: risk_state,
         positions: positions,
         balance_snapshots: balance_snapshots,
         open_orders: open_orders
       }}
    else
      {:error, detail} ->
        {:error, :restore_failed, %{detail: detail, trade_mode: trade_mode}}
    end
  end

  @doc """
  永続化された停止理由文字列を Readiness 用 atom にする。
  """
  @spec reason_from_string(String.t() | nil) :: reason()
  def reason_from_string(nil), do: :risk_halted

  def reason_from_string(reason) when is_binary(reason) do
    case reason do
      "reconcile_mismatch" -> :reconcile_mismatch
      "restore_failed" -> :restore_failed
      "exchange_unavailable" -> :exchange_unavailable
      "risk_halted" -> :risk_halted
      _ -> :risk_halted
    end
  end

  @doc """
  Readiness halt 理由を RiskState 用文字列にする。
  """
  @spec reason_to_string(reason()) :: String.t()
  def reason_to_string(reason) when is_atom(reason) do
    if MapSet.member?(@known_reasons, reason) do
      Atom.to_string(reason)
    else
      "reconcile_mismatch"
    end
  end

  defp check_persisted_risk(%{risk_state: nil}), do: :ok

  defp check_persisted_risk(%{risk_state: %RiskState{halted: false}}), do: :ok

  defp check_persisted_risk(%{risk_state: %RiskState{halted: true, reason: reason}}) do
    {:error, reason_from_string(reason), %{source: :risk_state}}
  end

  defp reconcile_mode(%{trade_mode: mode} = internal, exchange)
       when mode in [:dry_run, :paper] do
    # 内部仮想状態が正。取引所とは突合せず、建玉も書き換えない。
    _ = internal
    _ = exchange
    :ok
  end

  defp reconcile_mode(%{trade_mode: :live} = internal, exchange) do
    case exchange.fetch_reconcile_snapshot() do
      {:ok, snapshot} ->
        compare_with_exchange(internal, snapshot)

      {:error, :exchange_unavailable} ->
        {:error, :exchange_unavailable, %{trade_mode: :live}}

      {:error, detail} ->
        {:error, :exchange_unavailable, %{detail: detail, trade_mode: :live}}
    end
  end

  defp compare_with_exchange(internal, snapshot) do
    with :ok <- compare_positions(internal.positions, Map.get(snapshot, :positions, [])),
         :ok <- compare_balances(internal.balance_snapshots, Map.get(snapshot, :balances, [])),
         :ok <- compare_open_orders(internal.open_orders, Map.get(snapshot, :open_orders, [])) do
      :ok
    end
  end

  defp compare_positions(internal, external) do
    internal_map = Map.new(internal, &{&1.product_code, &1})
    external_map = Map.new(external, &{&1.product_code, &1})

    codes = MapSet.union(MapSet.new(Map.keys(internal_map)), MapSet.new(Map.keys(external_map)))

    Enum.reduce_while(codes, :ok, fn code, :ok ->
      case {Map.get(internal_map, code), Map.get(external_map, code)} do
        {nil, _} ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :position_missing_internal, product_code: code}}}

        {_, nil} ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :position_missing_exchange, product_code: code}}}

        {left, right} ->
          if position_match?(left, right) do
            {:cont, :ok}
          else
            {:halt,
             {:error, :reconcile_mismatch, %{kind: :position_mismatch, product_code: code}}}
          end
      end
    end)
  end

  defp position_match?(left, right) do
    left.side == right.side and
      Decimal.eq?(left.size, right.size) and
      Decimal.eq?(left.average_price, right.average_price)
  end

  defp compare_balances(internal_snaps, external) do
    internal_map = Map.new(internal_snaps, &{&1.currency, &1})
    external_map = Map.new(external, &{&1.currency, &1})

    currencies =
      MapSet.union(MapSet.new(Map.keys(internal_map)), MapSet.new(Map.keys(external_map)))

    Enum.reduce_while(currencies, :ok, fn currency, :ok ->
      case {Map.get(internal_map, currency), Map.get(external_map, currency)} do
        {nil, _} ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :balance_missing_internal, currency: currency}}}

        {_, nil} ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :balance_missing_exchange, currency: currency}}}

        {left, right} ->
          if balance_match?(left, right) do
            {:cont, :ok}
          else
            {:halt, {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}}}
          end
      end
    end)
  end

  defp balance_match?(left, right) do
    Decimal.eq?(left.amount, right.amount) and Decimal.eq?(left.available, right.available)
  end

  defp compare_open_orders(internal, external) do
    internal_ids =
      internal
      |> Enum.map(& &1.exchange_order_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    external_ids =
      external
      |> Enum.map(& &1.exchange_order_id)
      |> MapSet.new()

    if MapSet.equal?(internal_ids, external_ids) do
      :ok
    else
      {:error, :reconcile_mismatch,
       %{
         kind: :open_orders_mismatch,
         only_internal: MapSet.difference(internal_ids, external_ids) |> MapSet.to_list(),
         only_exchange: MapSet.difference(external_ids, internal_ids) |> MapSet.to_list()
       }}
    end
  end

  defp read_risk_state do
    case RiskState
         |> Ash.Query.filter(name == "default")
         |> Ash.read_one() do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, error}
    end
  end

  defp read_positions(trade_mode) do
    case Position
         |> Ash.Query.filter(trade_mode == ^trade_mode)
         |> Ash.read() do
      {:ok, positions} -> {:ok, positions}
      {:error, error} -> {:error, error}
    end
  end

  defp read_latest_balances(trade_mode) do
    case BalanceSnapshot
         |> Ash.Query.filter(trade_mode == ^trade_mode)
         |> Ash.Query.sort(captured_at: :desc)
         |> Ash.read() do
      {:ok, snapshots} ->
        latest =
          snapshots
          |> Enum.group_by(& &1.currency)
          |> Enum.map(fn {_currency, rows} -> hd(rows) end)

        {:ok, latest}

      {:error, error} ->
        {:error, error}
    end
  end

  defp read_open_orders(trade_mode) do
    case Order
         |> Ash.Query.filter(
           trade_mode == ^trade_mode and status in [:pending, :partially_filled]
         )
         |> Ash.read() do
      {:ok, orders} -> {:ok, orders}
      {:error, error} -> {:error, error}
    end
  end
end
