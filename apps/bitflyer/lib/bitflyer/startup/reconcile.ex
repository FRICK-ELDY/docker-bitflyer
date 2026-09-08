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
    # size<=0 は「建玉なし」と同等（誤検知防止）。Resource 制約でも弾くが防御的に残す。
    internal_map = Map.new(active_positions(internal), &{position_code(&1), &1})
    external_map = Map.new(active_positions(external), &{position_code(&1), &1})

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

  defp active_positions(positions) do
    Enum.filter(positions, fn position ->
      case Map.get(position, :size) do
        %Decimal{} = size -> Decimal.compare(size, 0) == :gt
        _ -> false
      end
    end)
  end

  defp position_code(position), do: Map.fetch!(position, :product_code)

  defp position_match?(left, right) do
    left_size = Map.get(left, :size)
    right_size = Map.get(right, :size)
    left_avg = Map.get(left, :average_price)
    right_avg = Map.get(right, :average_price)

    Map.get(left, :side) == Map.get(right, :side) and
      match?(%Decimal{}, left_size) and
      match?(%Decimal{}, right_size) and
      match?(%Decimal{}, left_avg) and
      match?(%Decimal{}, right_avg) and
      Decimal.eq?(left_size, right_size) and
      Decimal.eq?(left_avg, right_avg)
  end

  defp compare_balances(internal_snaps, external) do
    # 追跡中の通貨だけ突合する（取引所側のダスト通貨で誤停止しない）
    internal_map = Map.new(internal_snaps, &{balance_currency(&1), &1})
    external_map = Map.new(external, &{balance_currency(&1), &1})

    Enum.reduce_while(Map.keys(internal_map), :ok, fn currency, :ok ->
      case Map.fetch(external_map, currency) do
        :error ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :balance_missing_exchange, currency: currency}}}

        {:ok, right} ->
          left = Map.fetch!(internal_map, currency)

          if balance_match?(left, right) do
            {:cont, :ok}
          else
            {:halt, {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}}}
          end
      end
    end)
  end

  defp balance_currency(balance), do: Map.fetch!(balance, :currency)

  defp balance_match?(left, right) do
    left_amount = Map.get(left, :amount)
    right_amount = Map.get(right, :amount)
    left_available = Map.get(left, :available)
    right_available = Map.get(right, :available)

    match?(%Decimal{}, left_amount) and
      match?(%Decimal{}, right_amount) and
      match?(%Decimal{}, left_available) and
      match?(%Decimal{}, right_available) and
      Decimal.eq?(left_amount, right_amount) and
      Decimal.eq?(left_available, right_available)
  end

  defp compare_open_orders(internal, external) do
    internal_without_id = Enum.filter(internal, &is_nil(order_exchange_id(&1)))

    if internal_without_id != [] do
      {:error, :reconcile_mismatch, %{kind: :open_order_missing_exchange_id}}
    else
      internal_map = Map.new(internal, &{order_exchange_id(&1), &1})
      external_map = Map.new(external, &{order_exchange_id(&1), &1})

      ids = MapSet.union(MapSet.new(Map.keys(internal_map)), MapSet.new(Map.keys(external_map)))

      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case {Map.get(internal_map, id), Map.get(external_map, id)} do
          {nil, _} ->
            {:halt,
             {:error, :reconcile_mismatch,
              %{kind: :open_order_missing_internal, exchange_order_id: id}}}

          {_, nil} ->
            {:halt,
             {:error, :reconcile_mismatch,
              %{kind: :open_order_missing_exchange, exchange_order_id: id}}}

          {left, right} ->
            if open_order_match?(left, right) do
              {:cont, :ok}
            else
              {:halt,
               {:error, :reconcile_mismatch, %{kind: :open_order_mismatch, exchange_order_id: id}}}
            end
        end
      end)
    end
  end

  defp order_exchange_id(order), do: Map.get(order, :exchange_order_id)

  defp open_order_match?(left, right) do
    left_size = Map.get(left, :size)
    right_size = Map.get(right, :size)
    left_filled = Map.get(left, :filled_size)
    right_filled = Map.get(right, :filled_size)

    Map.get(left, :product_code) == Map.get(right, :product_code) and
      Map.get(left, :side) == Map.get(right, :side) and
      match?(%Decimal{}, left_size) and
      match?(%Decimal{}, right_size) and
      match?(%Decimal{}, left_filled) and
      match?(%Decimal{}, right_filled) and
      Decimal.eq?(left_size, right_size) and
      Decimal.eq?(left_filled, right_filled)
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
    mode = Atom.to_string(trade_mode)

    sql = """
    SELECT DISTINCT ON (currency) id
    FROM balance_snapshots
    WHERE trade_mode = $1
    ORDER BY currency ASC, captured_at DESC
    """

    case Ecto.Adapters.SQL.query(Bitflyer.Repo, sql, [mode]) do
      {:ok, %{rows: []}} ->
        {:ok, []}

      {:ok, %{rows: rows}} ->
        ids = Enum.map(rows, fn [id] -> id end)

        case BalanceSnapshot
             |> Ash.Query.filter(id in ^ids)
             |> Ash.read() do
          {:ok, snapshots} -> {:ok, snapshots}
          {:error, error} -> {:error, error}
        end

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
