defmodule Bitflyer.Startup.Reconcile do
  @moduledoc """
  起動・定期突合の純論理。

  1. datastore から内部状態を復元する
  2. モード別に突合する（dry_run/paper は内部正、live は取引所）
  3. 不整合なら `{:error, reason}` — Ready にはしない

  live では `required_balance_currencies`（既定: JPY / BTC）の
  BalanceSnapshot が無ければ `balance_baseline_missing` で失敗する。
  空の内部残高リストだけでは compare 成功にしない。

  取引所建玉は `{product_code, side}` で両建て並存しうるが、内部 Position は
  銘柄×モードのネット1行。突合前に外部を net（buy−sell）へ正規化する。
  不正な side / 平均単価は mismatch。両建て net 時は side+size を必須比較し、
  平均は単一路線のみ厳密比較（ドテン fill 単価との偽差異を避ける）。

  Ready / RiskState への書き込みは `Bitflyer.Startup.Reconciler` 側。
  """

  require Ash.Query

  alias Bitflyer.Trading.{BalanceSnapshot, Order, Position, Product, RiskState}
  alias Bitflyer.Exchange.Permissions
  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.Normalize
  alias Bitflyer.Risk
  alias Bitflyer.Risk.{HaltReason, Limits}

  @type reason ::
          :reconcile_mismatch
          | :restore_failed
          | :exchange_unavailable
          | :invalid_exchange_payload
          | :risk_halted
          | :unsafe_api_permissions
          | :clock_skew
          | atom()

  @type internal_state :: %{
          trade_mode: Bitflyer.TradeMode.t(),
          risk_state: struct() | nil,
          positions: [struct()],
          balance_snapshots: [struct()],
          open_orders: [struct()]
        }

  @type result :: {:ok, internal_state()} | {:error, reason(), map()}

  @doc """
  復元 → 突合。成功時は内部スナップショット、失敗時は reason。

  ## Options
  - `:trade_mode` — 既定は `TradeMode.current/0`
  - `:exchange` — 既定は `Bitflyer.Exchange`
  - `:required_balance_currencies` — live 必須通貨（既定は Application env）
  - `:skip_persisted_risk?` — true なら永続 RiskState halt を無視（手動 resume 用）
  - `:market_data_rest` — live 時計検査用 ticker REST（既定は MarketData 設定）
  - `:now_utc` — 時計検査の壁時計注入
  - `:skip_permissions?` / `:skip_clock_skew?` — テスト用スキップ
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    exchange = Keyword.get(opts, :exchange, Bitflyer.Exchange)

    required =
      Keyword.get_lazy(opts, :required_balance_currencies, &required_balance_currencies/0)

    with {:ok, internal} <- restore(trade_mode),
         :ok <- maybe_check_persisted_risk(internal, opts),
         result <- reconcile_mode(internal, exchange, required, opts) do
      case result do
        :ok -> {:ok, internal}
        {:ok, enriched} when is_map(enriched) -> {:ok, enriched}
        {:error, _, _} = error -> error
      end
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
  正本は `Bitflyer.Risk.HaltReason`。
  """
  @spec reason_from_string(String.t() | nil) :: reason()
  defdelegate reason_from_string(reason), to: HaltReason, as: :from_string

  @doc """
  Readiness halt 理由を RiskState 用文字列にする。
  正本は `Bitflyer.Risk.HaltReason`。
  """
  @spec reason_to_string(reason()) :: String.t()
  defdelegate reason_to_string(reason), to: HaltReason, as: :to_string

  defp required_balance_currencies do
    Application.get_env(:bitflyer, __MODULE__, [])
    |> Keyword.get(:required_balance_currencies, ["JPY", "BTC"])
  end

  defp check_persisted_risk(%{risk_state: nil}), do: :ok

  defp check_persisted_risk(%{risk_state: %RiskState{halted: false}}), do: :ok

  defp check_persisted_risk(%{risk_state: %RiskState{halted: true, reason: reason}}) do
    {:error, reason_from_string(reason), %{source: :risk_state}}
  end

  defp maybe_check_persisted_risk(internal, opts) do
    if Keyword.get(opts, :skip_persisted_risk?, false) do
      :ok
    else
      check_persisted_risk(internal)
    end
  end

  defp reconcile_mode(%{trade_mode: mode} = internal, exchange, _required, _opts)
       when mode in [:dry_run, :paper] do
    # 内部仮想状態が正。取引所とは突合せず、建玉も書き換えない。
    _ = internal
    _ = exchange
    :ok
  end

  defp reconcile_mode(%{trade_mode: :live} = _internal, exchange, required, opts) do
    # 突合前に権限・時計 → 約定を建玉へ反映（残高は getbalance 突合の正本。fill では書き換えない）
    with :ok <- assert_safe_permissions(exchange, opts),
         :ok <- assert_clock_skew(opts),
         :ok <- sync_live_fills(exchange),
         {:ok, internal} <- restore(:live),
         {:ok, snapshot} <- fetch_live_snapshot(exchange),
         :ok <- compare_with_exchange(internal, snapshot, required) do
      {:ok, Map.put(internal, :exchange_balances, exchange_balance_map(snapshot))}
    end
  end

  defp assert_safe_permissions(exchange, opts) do
    if Keyword.get(opts, :skip_permissions?, false) do
      :ok
    else
      case exchange.get_permissions() do
        {:ok, permissions} ->
          Permissions.assert_safe(permissions)

        {:error, :exchange_unavailable} ->
          {:error, :exchange_unavailable, %{trade_mode: :live, step: :get_permissions}}

        {:error, :auth_failed} ->
          {:error, :auth_failed, %{trade_mode: :live, step: :get_permissions}}

        {:error, detail} ->
          {:error, :exchange_unavailable,
           %{detail: detail, trade_mode: :live, step: :get_permissions}}
      end
    end
  end

  defp assert_clock_skew(opts) do
    if Keyword.get(opts, :skip_clock_skew?, false) do
      :ok
    else
      rest =
        Keyword.get_lazy(opts, :market_data_rest, fn ->
          Keyword.get(MarketData.config(), :rest_client, Bitflyer.MarketData.Rest)
        end)

      product_codes = MarketData.product_codes()
      max_skew_ms = Limits.current().max_clock_skew_ms
      skew_opts = Keyword.take(opts, [:now_utc])

      if product_codes == [] do
        {:error, :clock_skew, %{reason: :no_product_codes, trade_mode: :live}}
      else
        Enum.reduce_while(product_codes, :ok, fn product_code, :ok ->
          case check_product_clock_skew(rest, product_code, max_skew_ms, skew_opts) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp check_product_clock_skew(rest, product_code, max_skew_ms, skew_opts) do
    with {:ok, body} <- fetch_ticker_for_skew(rest, product_code),
         {:ok, _key, value} <- normalize_ticker_for_skew(body),
         :ok <- Risk.check_source_timestamp(value, max_skew_ms, skew_opts) do
      :ok
    else
      {:error, :clock_skew, meta} ->
        {:error, :clock_skew, Map.merge(%{trade_mode: :live, product_code: product_code}, meta)}

      {:error, reason, meta} when is_map(meta) ->
        {:error, reason, Map.merge(%{trade_mode: :live, product_code: product_code}, meta)}

      {:error, detail} ->
        {:error, :exchange_unavailable,
         %{
           detail: detail,
           trade_mode: :live,
           step: :clock_skew_ticker,
           product_code: product_code
         }}
    end
  end

  defp fetch_ticker_for_skew(rest, product_code) when is_binary(product_code) do
    case rest.fetch_ticker(product_code) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_ticker_response, other}}
    end
  end

  defp normalize_ticker_for_skew(body) do
    case Normalize.from_ticker(body) do
      {:ok, key, value} -> {:ok, key, value}
      :error -> {:error, :invalid_exchange_payload, %{kind: :invalid_ticker, step: :clock_skew}}
    end
  end

  defp sync_live_fills(exchange) do
    case Bitflyer.OrderExecutor.LiveFills.sync_open_orders(exchange: exchange) do
      :ok -> :ok
      {:error, reason, meta} -> {:error, reason, meta}
    end
  end

  defp fetch_live_snapshot(exchange) do
    case exchange.fetch_reconcile_snapshot() do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :exchange_unavailable} ->
        {:error, :exchange_unavailable, %{trade_mode: :live}}

      # 通信障害と区別する（停止は同等、運用ログ・RiskState 理由は別）
      {:error, kind} when is_atom(kind) ->
        if Bitflyer.Exchange.Rest.Decode.payload_error?(kind) do
          {:error, :invalid_exchange_payload, %{kind: kind, trade_mode: :live}}
        else
          {:error, :exchange_unavailable, %{detail: kind, trade_mode: :live}}
        end

      {:error, detail} ->
        {:error, :exchange_unavailable, %{detail: detail, trade_mode: :live}}
    end
  end

  defp compare_with_exchange(internal, snapshot, required) do
    with :ok <- compare_positions(internal.positions, Map.get(snapshot, :positions, [])),
         :ok <-
           compare_balances(
             internal.balance_snapshots,
             Map.get(snapshot, :balances, []),
             required
           ),
         :ok <- compare_open_orders(internal.open_orders, Map.get(snapshot, :open_orders, [])) do
      :ok
    end
  end

  defp compare_positions(internal, external) do
    # spot は getpositions 対象外。内部 Position は Risk 用の補助で、突合正本は getbalance。
    # したがって product_codes が spot のみのとき、同一 API キー口座の手動 FX/CFD 建玉は
    # 取得も比較もしない（案 B の射程外。live 解禁前提は README / overview）。
    internal = Enum.reject(internal, &spot_position_row?/1)
    external = Enum.reject(external, &spot_position_row?/1)

    # size<=0 は「建玉なし」と同等（誤検知防止）。Resource 制約でも弾くが防御的に残す。
    # 外部は両建て（同一銘柄 buy+sell）を net してから product_code キーで比較する。
    with {:ok, netted_external} <- net_positions(external) do
      internal_map = Map.new(active_positions(internal), &{position_code(&1), &1})
      external_map = Map.new(active_positions(netted_external), &{position_code(&1), &1})

      codes = MapSet.union(MapSet.new(Map.keys(internal_map)), MapSet.new(Map.keys(external_map)))

      Enum.reduce_while(codes, :ok, fn code, :ok ->
        case {Map.get(internal_map, code), Map.get(external_map, code)} do
          {nil, _} ->
            {:halt,
             {:error, :reconcile_mismatch,
              %{kind: :position_missing_internal, product_code: code}}}

          {_, nil} ->
            {:halt,
             {:error, :reconcile_mismatch,
              %{kind: :position_missing_exchange, product_code: code}}}

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
  end

  defp spot_position_row?(row) do
    code = position_code(row)
    is_binary(code) and Product.spot?(code)
  end

  # bitFlyer は同一銘柄の buy/sell を別行で返しうる。内部ネット建玉へ寄せる。
  # 不正 side / 非 Decimal 平均は黙って捨てず fail-closed。
  defp net_positions(positions) do
    positions
    |> Enum.group_by(&position_code/1)
    |> Enum.reduce_while({:ok, []}, fn {product_code, rows}, {:ok, acc} ->
      case net_product_positions(product_code, rows) do
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, [netted]} -> {:cont, {:ok, [netted | acc]}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp net_product_positions(product_code, rows) do
    case Enum.reduce_while(
           rows,
           {:ok, {Decimal.new(0), Decimal.new(0), Decimal.new(0), Decimal.new(0)}},
           fn row, {:ok, acc} ->
             case accumulate_side(row, acc) do
               {:ok, next} -> {:cont, {:ok, next}}
               {:error, _, _} = error -> {:halt, error}
             end
           end
         ) do
      {:error, _, _} = error ->
        error

      {:ok, {buy_size, buy_notional, sell_size, sell_notional}} ->
        hedged? =
          Decimal.compare(buy_size, 0) == :gt and Decimal.compare(sell_size, 0) == :gt

        net = Decimal.sub(buy_size, sell_size)

        cond do
          Decimal.compare(net, 0) == :gt ->
            {:ok,
             [
               netted_position(
                 product_code,
                 :buy,
                 net,
                 Decimal.div(buy_notional, buy_size),
                 hedged?
               )
             ]}

          Decimal.compare(net, 0) == :lt ->
            {:ok,
             [
               netted_position(
                 product_code,
                 :sell,
                 Decimal.abs(net),
                 Decimal.div(sell_notional, sell_size),
                 hedged?
               )
             ]}

          true ->
            {:ok, []}
        end
    end
  end

  defp accumulate_side(row, {buy_sz, buy_n, sell_sz, sell_n}) do
    size = Map.get(row, :size)
    avg = Map.get(row, :average_price)
    side = Map.get(row, :side)

    cond do
      not match?(%Decimal{}, size) or Decimal.compare(size, 0) != :gt ->
        # ゼロ・不正サイズは建玉なし扱い（active_positions と同趣旨）
        {:ok, {buy_sz, buy_n, sell_sz, sell_n}}

      side not in [:buy, :sell] or not match?(%Decimal{}, avg) ->
        Bitflyer.Telemetry.log(
          :warning,
          "reconcile rejected invalid exchange position row",
          %{
            product_code: Map.get(row, :product_code),
            side: side,
            size: size,
            average_price: avg,
            kind: :position_invalid_exchange
          }
        )

        {:error, :reconcile_mismatch,
         %{
           kind: :position_invalid_exchange,
           product_code: Map.get(row, :product_code),
           side: side
         }}

      side == :buy ->
        {:ok,
         {Decimal.add(buy_sz, size), Decimal.add(buy_n, Decimal.mult(size, avg)), sell_sz, sell_n}}

      side == :sell ->
        {:ok,
         {buy_sz, buy_n, Decimal.add(sell_sz, size), Decimal.add(sell_n, Decimal.mult(size, avg))}}
    end
  end

  defp netted_position(product_code, side, size, average_price, hedged?) do
    %{
      product_code: product_code,
      side: side,
      size: size,
      average_price: average_price,
      # 両建て net 後の勝ちサイド全量 VWAP は、内部の部分決済据え置き／ドテン fill 単価とズレうる。
      # エクスポージャ（side+size）は必ず突合し、平均は単一路線のみ厳密比較する。
      compare_average_price?: not hedged?
    }
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
    compare_avg? = Map.get(right, :compare_average_price?, true)

    side_size_ok =
      Map.get(left, :side) == Map.get(right, :side) and
        match?(%Decimal{}, left_size) and
        match?(%Decimal{}, right_size) and
        Decimal.eq?(left_size, right_size)

    cond do
      not side_size_ok ->
        false

      compare_avg? ->
        match?(%Decimal{}, left_avg) and
          match?(%Decimal{}, right_avg) and
          Decimal.eq?(left_avg, right_avg)

      true ->
        # hedged net: 平均は参考値のみ。内部に平均があることだけ確認する。
        match?(%Decimal{}, left_avg)
    end
  end

  defp compare_balances(internal_snaps, external, required) do
    # 追跡中の通貨だけ突合する（取引所側のダスト通貨で誤停止しない）。
    # ただし必須通貨の内部 baseline が無ければ空リストでも成功にしない。
    internal_map = Map.new(internal_snaps, &{balance_currency(&1), &1})
    external_map = Map.new(external, &{balance_currency(&1), &1})

    with :ok <- ensure_balance_baseline(internal_map, required) do
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
              {:halt,
               {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}}}
            end
        end
      end)
    end
  end

  defp ensure_balance_baseline(internal_map, required) when is_list(required) do
    case Enum.find(required, fn currency -> not Map.has_key?(internal_map, currency) end) do
      nil ->
        :ok

      currency ->
        {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing, currency: currency}}
    end
  end

  defp balance_currency(balance), do: Map.fetch!(balance, :currency)

  defp exchange_balance_map(%{balances: balances}) when is_list(balances) do
    Map.new(balances, fn balance ->
      currency = balance_currency(balance)
      available = Map.get(balance, :available) || Map.get(balance, :amount)
      {currency, available}
    end)
  end

  defp exchange_balance_map(_), do: %{}

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
    import Ecto.Query

    query =
      from(b in BalanceSnapshot,
        where: b.trade_mode == ^trade_mode,
        distinct: b.currency,
        order_by: [asc: b.currency, desc: b.captured_at]
      )

    {:ok, Bitflyer.Repo.all(query)}
  rescue
    error -> {:error, error}
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
