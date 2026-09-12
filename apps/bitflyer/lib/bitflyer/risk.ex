defmodule Bitflyer.Risk do
  @moduledoc """
  risk-manager の公開境界。

  strategy からの発注意図は必ず `authorize/2` を通す（fail-closed）。
  上限超過・stale・未同期は必ず拒否する。
  サーキットは `open_circuit/1` / `clear_circuit/1`。

  検査: 同期 → FailureRate 同期 → Feed 接続（`market_feed_gate`）→ 鮮度 →
  時計ずれ → 注文サイズ → 建玉 →
  live spot 売りカバー（買い建玉 − 未約定売り） → 価格逸脱 →
  発注頻度予約 → 日次損失 → 日次ドローダウン（realized+unrealized） → 残高。
  live は先に銘柄種別を検査し、spot 以外（FX/CFD）を拒否する。
  live spot の売りは Position なしのベースライン在庫を対象にしない。

  MarketData 有効時は Status / `/health/ready` と同じ
  `OperationalStatus.market_feed_gate/2` を鮮度の前に見る。接続入力は
  `Feed.connection_snapshot/0`（Health / Status の `feed_snapshot` も同じ）。
  無効時はスキップ。`:market_data` / `:feed` 注入は `allow_test_injections` のみ。

  ゲート拒否は `{:error, :stale, %{reason: ...}}`。`reason` が
  `feed_disconnected` / `feed_unavailable` / `stale_market_data`。
  コードは鮮度と切断を分けない（市場データが使えない＝発注しない）。

  発注ホットパスでは RiskState・発注頻度・日次損失・残高・HWM 永続化のために DB 往復しない。
  頻度は `Risk.OrderRate.reserve/3`（authorize 時に原子的予約）、取引所エラー連続は `Risk.FailureRate`
  （起動 warm 失敗時は unsynced で認可拒否）、日次損失は `Risk.DailyLoss`、残高は `Risk.BalanceCache`（ETS）。
  ドローダウン HWM の上昇は認可では ETS のみ。`DailyEquityPeak` への upsert は Fill 後 /
  突合 / resume の `Equity.enforce`。
  """

  require Ash.Query

  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.{Cache, Feed}
  alias Bitflyer.OperationalStatus

  alias Bitflyer.Risk.{
    AuthorizedOrder,
    BalanceCache,
    Circuit,
    DailyLoss,
    Equity,
    FailureRate,
    Limits,
    OrderRate
  }

  alias Bitflyer.Trading.{Order, Position, Product, SpotInventory}

  @type rejection_code ::
          :invalid_command
          | :unsynced
          | :circuit_open
          | :stale
          | :clock_skew
          | :limit_exceeded
          | :invalid_fill_pricing

  @type result :: {:ok, AuthorizedOrder.t()} | {:error, rejection_code(), map()}

  @doc """
  発注意図を認可する。成功時は `AuthorizedOrder`、失敗時は `{:error, code, meta}`。

  ## Options
  - `:readiness` — 既定 `Bitflyer.Readiness`
  - `:limits` — 上限上書き（`Limits.normalize/1` される）
  - `:positions` — 建玉リスト（テスト注入。`allow_test_injections: true` のときのみ。
    未指定／本番は trade_mode 全建玉を **1 回** 読み、建玉上限と Equity で共有する）
  - `:open_orders` — 未約定リスト（テスト注入。live spot 売りカバー用。未指定時は DB）
  - `:now` / `:server` — Cache.fresh?/3・LTP 取得へ転送
  - `:market_data` / `:feed` — `market_feed_gate` 用スナップショット
    （テスト注入。`allow_test_injections: true` のときのみ）
  - `:authorized_order_server` — `AuthorizedOrder` GenServer（Cache の `:server` とは別）
  - `:failure_rate` / `:failure_rate_server` — FailureRate モジュールと GenServer 名（テスト注入）
  - `:now_utc` — 時計ずれ検査用の壁時計（既定 `DateTime.utc_now/0`）
  - `:check_persisted_circuit` — 既定 **false**（ホットパスで RiskState を読まない）。
    別 BEAM の `mix bitflyer.halt` は `Risk.CircuitSync` が DB→ETS 同期する。
    テストや即時検査で DB を直接見るときだけ `true`
  - `:recent_order_count` — 直近 1 分の発注件数（テスト注入。`allow_test_injections: true` のときのみ。未指定時は OrderRate.reserve）
  - `:daily_loss` — 当日損失額（テスト注入。`allow_test_injections: true` のときのみ。未指定時は DailyLoss ETS）
  - `:balances` — 残高マップまたはリスト（テスト注入。未指定時は BalanceCache ETS。paper/live 必須）
  - `:now` — Cache / OrderRate 用 monotonic ms（テスト注入）
  """
  @spec authorize(map(), keyword()) :: result()
  def authorize(command, opts \\ []) when is_map(command) do
    limits =
      opts
      |> Keyword.get_lazy(:limits, &Limits.current/0)
      |> Limits.normalize()

    result =
      with :ok <- validate_command(command),
           {:ok, opts} <- attach_positions(opts),
           :ok <- check_live_product(command, opts),
           :ok <- check_sync(opts),
           :ok <- check_failure_rate(opts),
           :ok <- check_market_feed(limits, opts),
           :ok <- check_freshness(command, limits, opts),
           :ok <- check_clock_skew(command, limits, opts),
           :ok <- check_order_size(command, limits),
           :ok <- check_position_size(command, limits, opts),
           :ok <- check_spot_sell_cover(command, opts),
           :ok <- check_price_deviation(command, limits, opts),
           {:ok, reservation} <- reserve_order_rate(limits, opts),
           :ok <- finish_authorize_after_rate(command, limits, opts, reservation) do
        {:ok, mint_authorized_order(command, reservation, opts)}
      end

    case result do
      {:ok, authorized} ->
        {:ok, authorized}

      {:error, code, meta} = error ->
        emit_rejected(command, code, meta)
        error
    end
  end

  defp finish_authorize_after_rate(command, limits, opts, reservation) do
    case check_daily_loss(limits, opts) do
      :ok ->
        case check_daily_drawdown(limits, opts) do
          :ok ->
            case check_available_balance(command, opts) do
              :ok ->
                :ok

              {:error, _, _} = error ->
                _ = OrderRate.release(reservation)
                error
            end

          {:error, _, _} = error ->
            _ = OrderRate.release(reservation)
            error
        end

      {:error, _, _} = error ->
        _ = OrderRate.release(reservation)
        error
    end
  end

  defp mint_authorized_order(command, reservation, opts) do
    server = Keyword.get(opts, :authorized_order_server, AuthorizedOrder)
    mint_opts = Keyword.take(opts, [:now_ms])
    GenServer.call(server, {:mint, command, reservation, mint_opts})
  end

  @doc """
  発注が拘束する通貨と額。`BalanceCache.reserve/4` 用。

  dry_run は残高モデル無しのため `{:ok, :skip}`。
  """
  @spec balance_hold(map(), keyword()) ::
          {:ok, :skip}
          | {:ok, %{currency: String.t(), amount: Decimal.t()}}
          | {:error, rejection_code(), map()}
  def balance_hold(command, opts \\ []) when is_map(command) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    if trade_mode == :dry_run do
      {:ok, :skip}
    else
      side = Map.fetch!(command, :side)
      size = Map.fetch!(command, :size)
      product_code = Map.fetch!(command, :product_code)

      case side do
        :buy ->
          case quote_notional(command, opts) do
            {:ok, notional} ->
              {:ok, %{currency: quote_currency(product_code), amount: notional}}

            other ->
              other
          end

        :sell ->
          {:ok, %{currency: base_currency(product_code), amount: size}}
      end
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

  # live は spot のみ（getbalance モデル）。FX は証拠金未実装のため拒否。
  defp check_live_product(command, opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    product_code = Map.get(command, :product_code)

    cond do
      trade_mode != :live ->
        :ok

      Product.spot?(product_code) ->
        :ok

      true ->
        {:error, :invalid_command,
         %{
           reason: :unsupported_product_for_live,
           product_code: product_code,
           market_type: Product.market_type(product_code)
         }}
    end
  end

  defp check_sync(opts) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    case readiness.gate() do
      :ok ->
        # 実行時の正本は Readiness（ETS）。サーキット開は先に halt する設計のため
        # 既定では RiskState を読まない（発注ホットパスの DB 往復を避ける）。
        # 別 BEAM の mix halt は CircuitSync が ETS へ反映する。
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

  defp check_failure_rate(opts) do
    failure_rate = Keyword.get(opts, :failure_rate, FailureRate)

    # `:server` は MarketData.Cache 用のため転送しない（OrderRate の歴史的衝突を増やさない）
    failure_rate_opts =
      case Keyword.fetch(opts, :failure_rate_server) do
        {:ok, server} -> [server: server]
        :error -> []
      end

    if failure_rate.synced?(failure_rate_opts) do
      :ok
    else
      {:error, :unsynced, %{reason: :failure_rate_unsynced}}
    end
  end

  defp check_market_feed(limits, opts) do
    market_data = resolve_market_data(limits, opts)
    feed = resolve_feed(opts)

    case OperationalStatus.market_feed_gate(market_data, feed) do
      :ok ->
        :ok

      {:halted, reason} ->
        {:error, :stale, %{reason: reason}}
    end
  end

  defp resolve_market_data(limits, opts) do
    case injected_map(opts, :market_data) do
      %{} = snapshot ->
        snapshot

      nil ->
        OperationalStatus.market_data_snapshot(
          [
            max_age_ms: limits.market_data_max_age_ms,
            enabled?: MarketData.enabled?()
          ] ++ Keyword.take(opts, [:now, :server])
        )
    end
  end

  defp resolve_feed(opts) do
    case injected_map(opts, :feed) do
      %{} = snapshot ->
        snapshot

      nil ->
        if MarketData.enabled?() do
          Feed.connection_snapshot()
          |> Map.put(:enabled?, true)
        else
          %{enabled?: false, available?: false, connected?: false}
        end
    end
  end

  defp injected_map(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_map(value) ->
        if test_injections_allowed?(), do: value, else: nil

      _ ->
        nil
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

  defp check_clock_skew(command, limits, opts) do
    key = Map.fetch!(command, :market_key)
    server = Keyword.get(opts, :server, Cache)

    case Cache.get(key, server) do
      {:ok, value, _received_at} ->
        check_source_timestamp(value, limits.max_clock_skew_ms, opts)

      :miss ->
        {:error, :stale, %{market_key: key, max_age_ms: limits.market_data_max_age_ms}}
    end
  end

  @doc """
  ticker 値の取引所時刻とホスト壁時計のずれを検査する。

  `source_timestamp` 欠落は常に fail-closed（リプレイ耐性）。
  """
  @spec check_source_timestamp(map() | term(), non_neg_integer(), keyword()) ::
          :ok | {:error, :clock_skew, map()}
  def check_source_timestamp(value, max_skew_ms, opts \\ [])

  def check_source_timestamp(%{source_timestamp: %DateTime{} = source}, max_skew_ms, opts)
      when is_integer(max_skew_ms) and max_skew_ms >= 0 do
    now = Keyword.get_lazy(opts, :now_utc, &DateTime.utc_now/0)
    skew_ms = abs(DateTime.diff(now, source, :millisecond))

    if skew_ms > max_skew_ms do
      {:error, :clock_skew,
       %{
         skew_ms: skew_ms,
         max_ms: max_skew_ms,
         source_timestamp: source
       }}
    else
      :ok
    end
  end

  def check_source_timestamp(_value, max_skew_ms, _opts)
      when is_integer(max_skew_ms) and max_skew_ms >= 0 do
    {:error, :clock_skew, %{reason: :missing_source_timestamp, max_ms: max_skew_ms}}
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

  # live spot: 売れるのは買い建玉 − 未約定売りまで。ベースライン専用在庫は売らない。
  defp check_spot_sell_cover(command, opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    side = Map.fetch!(command, :side)
    product_code = Map.fetch!(command, :product_code)

    cond do
      trade_mode != :live ->
        :ok

      side != :sell ->
        :ok

      not Product.spot?(product_code) ->
        :ok

      true ->
        enforce_spot_sell_cover(command, opts)
    end
  end

  defp enforce_spot_sell_cover(command, opts) do
    size = Map.fetch!(command, :size)
    product_code = Map.fetch!(command, :product_code)

    with {:ok, positions} <- fetch_positions(product_code, opts),
         {:ok, open_orders} <- resolve_open_orders(opts) do
      if SpotInventory.sell_covered?(positions, open_orders, product_code, size) do
        :ok
      else
        {:error, :limit_exceeded,
         %{
           limit: :spot_sell_exceeds_position,
           product_code: product_code,
           size: size
         }}
      end
    end
  end

  defp check_price_deviation(command, limits, opts) do
    order_type = Map.get(command, :order_type, :market)
    price = Map.get(command, :price)

    cond do
      order_type != :limit ->
        :ok

      not match?(%Decimal{}, price) ->
        {:error, :invalid_command, %{field: :price}}

      true ->
        case fetch_ltp(command, opts) do
          {:ok, ltp} ->
            deviation_pct = price_deviation_pct(price, ltp)

            if Decimal.gt?(deviation_pct, limits.max_price_deviation_pct) do
              {:error, :limit_exceeded,
               %{
                 limit: :max_price_deviation_pct,
                 deviation_pct: deviation_pct,
                 max: limits.max_price_deviation_pct,
                 price: price,
                 ltp: ltp
               }}
            else
              :ok
            end

          :miss ->
            # freshness 通過後でも値欠落は fail-closed
            {:error, :stale,
             %{market_key: Map.fetch!(command, :market_key), reason: :ltp_missing}}
        end
    end
  end

  defp reserve_order_rate(limits, opts) do
    max = limits.max_orders_per_minute

    case Keyword.fetch(opts, :recent_order_count) do
      {:ok, count} when is_integer(count) and count >= 0 ->
        if test_injections_allowed?() do
          if count >= max do
            {:error, :limit_exceeded, %{limit: :max_orders_per_minute, count: count, max: max}}
          else
            {:ok, :skip}
          end
        else
          # 本番経路では注入を無視し実予約する（原子性迂回を防ぐ）
          reserve_order_rate(limits, Keyword.delete(opts, :recent_order_count))
        end

      {:ok, _} ->
        if test_injections_allowed?() do
          {:error, :unsynced, %{reason: :invalid_recent_order_count}}
        else
          reserve_order_rate(limits, Keyword.delete(opts, :recent_order_count))
        end

      :error ->
        trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
        reserve_opts = Keyword.take(opts, [:now, :server, :window_ms])

        case OrderRate.reserve(trade_mode, max, reserve_opts) do
          {:ok, reservation} ->
            {:ok, reservation}

          {:error, :limit_exceeded, %{count: count, max: ^max}} ->
            {:error, :limit_exceeded, %{limit: :max_orders_per_minute, count: count, max: max}}

          {:error, :unsynced} ->
            {:error, :unsynced, %{reason: :order_rate_unsynced}}
        end
    end
  end

  defp check_daily_loss(limits, opts) do
    case resolve_daily_loss(opts) do
      {:ok, loss} ->
        if Decimal.gt?(loss, limits.max_daily_loss) do
          _ = open_circuit(:daily_loss_exceeded, Keyword.take(opts, [:readiness]))

          {:error, :limit_exceeded,
           %{
             limit: :max_daily_loss,
             daily_loss: loss,
             max: limits.max_daily_loss
           }}
        else
          :ok
        end

      {:error, _error} ->
        {:error, :unsynced, %{reason: :daily_loss_unsynced}}
    end
  end

  defp check_daily_drawdown(limits, opts) do
    enforce_opts =
      opts
      |> Keyword.put(:limits, limits)
      |> Keyword.put_new(:persist, false)

    case Equity.enforce(enforce_opts) do
      {:ok, _} ->
        :ok

      {:halted, snap} ->
        {:error, :limit_exceeded,
         %{
           limit: :max_daily_drawdown,
           drawdown: snap.drawdown,
           max: snap.max,
           realized_net: snap.realized_net,
           unrealized: snap.unrealized
         }}

      {:error, :stale, meta} ->
        {:error, :stale, meta}

      {:error, :unsynced, meta} ->
        {:error, :unsynced, meta}
    end
  end

  defp check_available_balance(command, opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    # dry_run は残高モデルを持たない（送らない・動かさない）
    if trade_mode == :dry_run do
      :ok
    else
      case resolve_balances(opts, trade_mode) do
        {:ok, balances} ->
          verify_available_balance(command, balances, opts)

        {:error, :unsynced} ->
          {:error, :unsynced, %{reason: :balance_unsynced}}
      end
    end
  end

  defp verify_available_balance(command, balances, opts) do
    side = Map.fetch!(command, :side)
    size = Map.fetch!(command, :size)
    product_code = Map.fetch!(command, :product_code)
    balance_map = balance_map(balances)

    case side do
      :buy ->
        case quote_notional(command, opts) do
          {:ok, notional} ->
            currency = quote_currency(product_code)
            available = Map.get(balance_map, currency)

            cond do
              is_nil(available) ->
                {:error, :unsynced, %{reason: :balance_currency_missing, currency: currency}}

              Decimal.lt?(available, notional) ->
                {:error, :limit_exceeded,
                 %{
                   limit: :insufficient_balance,
                   currency: currency,
                   available: available,
                   required: notional
                 }}

              true ->
                :ok
            end

          other ->
            other
        end

      :sell ->
        currency = base_currency(product_code)
        available = Map.get(balance_map, currency)

        cond do
          is_nil(available) ->
            {:error, :unsynced, %{reason: :balance_currency_missing, currency: currency}}

          Decimal.lt?(available, size) ->
            {:error, :limit_exceeded,
             %{
               limit: :insufficient_balance,
               currency: currency,
               available: available,
               required: size
             }}

          true ->
            :ok
        end
    end
  end

  defp quote_notional(command, opts) do
    size = Map.fetch!(command, :size)
    side = Map.fetch!(command, :side)
    order_type = Map.get(command, :order_type, :market)
    price = Map.get(command, :price)
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    with {:ok, unit_price} <- base_unit_price(order_type, price, command, opts),
         {:ok, priced} <- paper_unit_price(trade_mode, side, order_type, unit_price) do
      {:ok, Decimal.mult(priced, size)}
    end
  end

  defp base_unit_price(:limit, %Decimal{} = price, _command, _opts), do: {:ok, price}

  defp base_unit_price(_order_type, _price, command, opts) do
    case fetch_ltp(command, opts) do
      {:ok, ltp} ->
        {:ok, ltp}

      :miss ->
        {:error, :stale, %{market_key: Map.fetch!(command, :market_key), reason: :ltp_missing}}
    end
  end

  # paper 買いの拘束額を不利化後価格に合わせ、reserve < 実効コストを防ぐ
  defp paper_unit_price(:paper, :buy, :market, unit_price) do
    Bitflyer.OrderExecutor.Paper.FillPricing.effective_price(:buy, unit_price)
  end

  defp paper_unit_price(:paper, :buy, :limit, unit_price) do
    Bitflyer.OrderExecutor.Paper.FillPricing.limit_fill_price(:buy, unit_price)
  end

  defp paper_unit_price(_trade_mode, _side, _order_type, unit_price), do: {:ok, unit_price}

  defp fetch_ltp(command, opts) do
    key = Map.fetch!(command, :market_key)
    server = Keyword.get(opts, :server, Cache)

    case Cache.get(key, server) do
      {:ok, value, _received_at} ->
        case extract_ltp(value) do
          %Decimal{} = ltp -> {:ok, ltp}
          _ -> :miss
        end

      :miss ->
        :miss
    end
  end

  defp extract_ltp(%{ltp: %Decimal{} = ltp}) do
    if Decimal.positive?(ltp), do: ltp, else: nil
  end

  defp extract_ltp(%{"ltp" => %Decimal{} = ltp}) do
    if Decimal.positive?(ltp), do: ltp, else: nil
  end

  defp extract_ltp(_), do: nil

  defp price_deviation_pct(%Decimal{} = price, %Decimal{} = ltp) do
    price
    |> Decimal.sub(ltp)
    |> Decimal.abs()
    |> Decimal.div(ltp)
    |> Decimal.mult(Decimal.new(100))
  end

  defp resolve_daily_loss(opts) do
    case Keyword.fetch(opts, :daily_loss) do
      {:ok, raw_loss} ->
        if test_injections_allowed?() do
          case to_decimal(raw_loss) do
            %Decimal{} = loss ->
              if Decimal.compare(loss, Decimal.new(0)) == :lt do
                {:error, :invalid_daily_loss}
              else
                {:ok, loss}
              end

            nil ->
              {:error, :invalid_daily_loss}
          end
        else
          # 本番経路では注入を無視し ETS 正本を使う（0 注入による迂回を防ぐ）
          resolve_daily_loss(Keyword.delete(opts, :daily_loss))
        end

      :error ->
        trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

        daily_loss_opts =
          case Keyword.fetch(opts, :daily_loss_server) do
            {:ok, server} -> [server: server]
            :error -> []
          end
          |> Keyword.merge(Keyword.take(opts, [:now_dt]))

        case DailyLoss.get(trade_mode, daily_loss_opts) do
          {:ok, %Decimal{} = loss} ->
            {:ok, loss}

          {:error, :unsynced} ->
            {:error, :unsynced}
        end
    end
  end

  defp test_injections_allowed? do
    :bitflyer
    |> Application.get_env(Bitflyer.Risk, [])
    |> Keyword.get(:allow_test_injections, false) == true
  end

  defp resolve_balances(opts, trade_mode) do
    case Keyword.fetch(opts, :balances) do
      {:ok, balances} ->
        if test_injections_allowed?() do
          {:ok, balances || []}
        else
          resolve_balances(Keyword.delete(opts, :balances), trade_mode)
        end

      :error ->
        balance_opts =
          case Keyword.fetch(opts, :balance_cache_server) do
            {:ok, server} -> [server: server]
            :error -> []
          end

        BalanceCache.get(trade_mode, balance_opts)
    end
  end

  defp balance_map(balances) when is_map(balances) do
    balances
    |> Enum.map(fn {currency, value} ->
      available =
        case value do
          %{available: val} -> to_decimal(val)
          %{"available" => val} -> to_decimal(val)
          val -> to_decimal(val)
        end

      {normalize_currency_key(currency), available}
    end)
    |> Enum.reject(fn {currency, available} -> is_nil(currency) or is_nil(available) end)
    |> Map.new()
  end

  defp balance_map(balances) when is_list(balances) do
    balances
    |> Enum.map(fn balance ->
      currency = Map.get(balance, :currency) || Map.get(balance, "currency")
      available = Map.get(balance, :available) || Map.get(balance, "available")
      {normalize_currency_key(currency), to_decimal(available)}
    end)
    |> Enum.reject(fn {currency, available} -> is_nil(currency) or is_nil(available) end)
    |> Map.new()
  end

  defp normalize_currency_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_currency_key(key) when is_binary(key), do: key
  defp normalize_currency_key(_), do: nil

  defp to_decimal(%Decimal{} = d), do: d

  defp to_decimal(raw) when is_binary(raw) do
    case Decimal.parse(raw) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp to_decimal(raw) when is_integer(raw), do: Decimal.new(raw)
  defp to_decimal(raw) when is_float(raw), do: Decimal.from_float(raw)
  defp to_decimal(_), do: nil

  defp quote_currency(product_code), do: Product.quote_currency(product_code)
  defp base_currency(product_code), do: Product.base_currency(product_code)

  defp attach_positions(opts) do
    case resolve_positions(opts) do
      {:ok, positions} ->
        {:ok, Keyword.put(opts, :positions, positions)}

      {:error, error} ->
        {:error, :unsynced, %{reason: :position_load_failed, error: inspect(error)}}
    end
  end

  defp resolve_positions(opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    case Keyword.fetch(opts, :positions) do
      {:ok, positions} ->
        if test_injections_allowed?() do
          {:ok, positions || []}
        else
          load_all_positions(trade_mode)
        end

      :error ->
        load_all_positions(trade_mode)
    end
  end

  defp fetch_positions(_product_code, opts) do
    case Keyword.fetch(opts, :positions) do
      {:ok, positions} -> {:ok, positions || []}
      :error -> resolve_positions(opts)
    end
  end

  defp resolve_open_orders(opts) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)

    case Keyword.fetch(opts, :open_orders) do
      {:ok, orders} ->
        if test_injections_allowed?() do
          {:ok, orders || []}
        else
          load_open_orders(trade_mode)
        end

      :error ->
        load_open_orders(trade_mode)
    end
  end

  defp load_open_orders(trade_mode) do
    case Order
         |> Ash.Query.filter(
           trade_mode == ^trade_mode and status in [:pending, :partially_filled]
         )
         |> Ash.read() do
      {:ok, orders} ->
        {:ok, orders}

      {:error, error} ->
        {:error, :unsynced, %{reason: :open_order_load_failed, error: inspect(error)}}
    end
  end

  defp load_all_positions(trade_mode) do
    Position
    |> Ash.Query.filter(trade_mode == ^trade_mode)
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
      Map.merge(
        %{
          rejection_code: code,
          reason: code,
          trade_mode: Bitflyer.TradeMode.current(),
          product_code: Map.get(command, :product_code) || Map.get(meta, :product_code),
          side: Map.get(command, :side)
        },
        Map.take(meta, [:limit, :currency, :kind, :skew_ms, :max_ms])
      )
    )
  end
end
