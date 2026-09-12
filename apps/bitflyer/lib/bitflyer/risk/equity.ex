defmodule Bitflyer.Risk.Equity do
  @moduledoc """
  当日 realized net + 建玉含み損益のドローダウン判定。

  `DailyLoss` ETS は実現 net と当日 equity ピーク（HWM）を持つ。
  ピーク上昇の persist は Fill 後 / 突合 / resume。認可は `persist: false` で
  ETS だけ上げ、ホットパスから Ash を呼ばない。再起動後は `DailyLoss.init` /
  `reload` が当日行を読む。
  未実現は判定時に `MarketData.Cache` の LTP と **内部** `Position.average_price`
  から計算する推定値。spot に取引所平均は無く、比較対象にもしない。

  `drawdown = peak − equity_pnl`。日始 peak は 0 なので、一度もプラスにならなければ
  ゼロ基準の損失と同じ。実現益のあと含み損が膨らんでも、ピークからの下落で halt する。

  新規注文は未実現に投影しない。認可時点は既存建玉のみ。同一 LTP なら増分 MTM は
  ほぼ 0 で、閾値超過は約定後の `DailyLossSync` enforce か周期 tick で拾う
  （指値滞留中は建玉にも入らない）。

  ## stale 方針

  建玉があるのに mark（ticker LTP）が欠落／鮮度切れなら **計算不能**。

  - `authorize` / `Startup.Resume` — fail-closed（`:stale` / `:mark_price_unavailable`）
  - 周期 `enforce/1`（boot / `run_now` / periodic / Fill 後）— **halt しない**
    （切断だけで永続 halt にしない）。価格が戻れば次回判定
  - 建玉が無いときは未実現 0（実現のみ。`max_daily_loss` と同値なら冗長）
  - 未知 `side` は含み 0 にせず `:unsynced`（壊れた建玉を無視しない）
  """

  require Ash.Query

  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.Cache
  alias Bitflyer.Risk.{Circuit, DailyLoss, Limits}
  alias Bitflyer.Trading.Position

  @type snapshot :: %{
          realized_net: Decimal.t(),
          unrealized: Decimal.t(),
          equity_pnl: Decimal.t(),
          peak: Decimal.t(),
          drawdown: Decimal.t(),
          max: Decimal.t()
        }

  @type enforce_result ::
          {:ok, snapshot()}
          | {:ok, :already_halted}
          | {:halted, snapshot()}
          | {:error, :stale, map()}
          | {:error, :unsynced, map()}

  @doc """
  realized net と含み損益を合成する。閾値比較はしない。

  既定では当日ピーク（HWM）を更新する。表示専用は `record_peak: false`
  （格納済み peak を読むだけ。authorize / enforce / 周期は既定のまま）。
  """
  @spec snapshot(keyword()) ::
          {:ok, snapshot()} | {:error, :stale, map()} | {:error, :unsynced, map()}
  def snapshot(opts \\ []) do
    trade_mode = Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
    limits = limits(opts)

    with {:ok, %{net: realized_net, peak: stored_peak}} <- daily_net(trade_mode, opts),
         {:ok, positions} <- load_positions(trade_mode, opts),
         {:ok, unrealized} <- mark_unrealized(positions, limits, opts) do
      equity_pnl = Decimal.add(realized_net, unrealized)

      case resolve_peak(trade_mode, equity_pnl, stored_peak, opts) do
        {:ok, peak} ->
          drawdown = peak |> Decimal.sub(equity_pnl) |> Decimal.max(Decimal.new(0))

          {:ok,
           %{
             realized_net: realized_net,
             unrealized: unrealized,
             equity_pnl: equity_pnl,
             peak: peak,
             drawdown: drawdown,
             max: limits.max_daily_drawdown
           }}

        {:error, _, _} = error ->
          error
      end
    end
  end

  @doc """
  建玉 1 本の mark（LTP）と含み。ピーク更新・halt はしない。
  """
  @spec mark_position(map(), keyword()) ::
          {:ok, %{unrealized: Decimal.t(), mark: Decimal.t() | nil}}
          | {:error, :stale, map()}
          | {:error, :unsynced, map()}
  def mark_position(position, opts \\ []) do
    case position_unrealized(position, limits(opts), opts) do
      {:ok, {pnl, ltp}} -> {:ok, %{unrealized: pnl, mark: ltp}}
      {:error, _, _} = error -> error
    end
  end

  @doc """
  ドローダウン超過なら `daily_drawdown_exceeded` で halt する。

  既に halted / mark stale / DailyLoss unsynced では halt しない。
  """
  @spec enforce(keyword()) :: enforce_result()
  def enforce(opts \\ []) do
    readiness = Keyword.get(opts, :readiness, Bitflyer.Readiness)

    case readiness.get() do
      {:halted, _} ->
        {:ok, :already_halted}

      _ ->
        do_enforce(opts)
    end
  end

  defp do_enforce(opts) do
    case snapshot(opts) do
      {:ok, %{drawdown: drawdown, max: max} = snap} ->
        if Decimal.gt?(drawdown, max) do
          _ = Circuit.open(:daily_drawdown_exceeded, Keyword.take(opts, [:readiness]))

          Bitflyer.Telemetry.log(
            :critical,
            "daily drawdown exceeded; circuit opened",
            %{
              drawdown: drawdown,
              max: max,
              realized_net: snap.realized_net,
              unrealized: snap.unrealized,
              trade_mode: Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0)
            }
          )

          {:halted, snap}
        else
          {:ok, snap}
        end

      {:error, :stale, meta} = error ->
        Bitflyer.Telemetry.log(
          :warning,
          "daily drawdown skipped; mark price unavailable",
          meta
        )

        error

      {:error, :unsynced, meta} = error ->
        Bitflyer.Telemetry.log(
          :warning,
          "daily drawdown skipped; equity inputs unsynced",
          meta
        )

        error
    end
  end

  defp daily_net(trade_mode, opts) do
    daily_opts =
      case Keyword.fetch(opts, :daily_loss_server) do
        {:ok, server} -> [server: server]
        :error -> []
      end
      |> Keyword.merge(Keyword.take(opts, [:now_dt]))

    case DailyLoss.snapshot(trade_mode, daily_opts) do
      {:ok, %{net: net, peak: peak}} -> {:ok, %{net: net, peak: peak}}
      {:error, :unsynced} -> {:error, :unsynced, %{reason: :daily_loss_unsynced}}
    end
  end

  defp resolve_peak(trade_mode, equity_pnl, stored_peak, opts) do
    if Keyword.get(opts, :record_peak, true) do
      case record_peak(trade_mode, equity_pnl, opts) do
        {:ok, peak} ->
          {:ok, peak}

        {:error, :unsynced} ->
          {:error, :unsynced, %{reason: :hwm_persist_failed}}
      end
    else
      {:ok, stored_peak}
    end
  end

  # `:positions` があればそのまま使う（authorize は attach_positions 済み、
  # テストは注入）。未指定の周期 / resume / Fill 後だけ DB を読む。
  # 注入の無視は Risk.authorize 側。ここで再ゲートするとホットパスが二重読になる。
  defp load_positions(trade_mode, opts) do
    case Keyword.fetch(opts, :positions) do
      {:ok, positions} ->
        {:ok, positions || []}

      :error ->
        read_positions(trade_mode)
    end
  end

  defp read_positions(trade_mode) do
    case Position
         |> Ash.Query.filter(trade_mode == ^trade_mode)
         |> Ash.read() do
      {:ok, positions} ->
        {:ok, positions}

      {:error, error} ->
        {:error, :unsynced, %{reason: :position_load_failed, error: inspect(error)}}
    end
  end

  defp record_peak(trade_mode, equity_pnl, opts) do
    daily_opts =
      case Keyword.fetch(opts, :daily_loss_server) do
        {:ok, server} -> [server: server]
        :error -> []
      end
      |> Keyword.merge(Keyword.take(opts, [:now_dt, :persist]))

    DailyLoss.record_peak(trade_mode, equity_pnl, daily_opts)
  end

  defp mark_unrealized([], _limits, _opts), do: {:ok, Decimal.new(0)}

  defp mark_unrealized(positions, limits, opts) do
    Enum.reduce_while(positions, {:ok, Decimal.new(0)}, fn position, {:ok, acc} ->
      case position_unrealized(position, limits, opts) do
        {:ok, {pnl, _ltp}} -> {:cont, {:ok, Decimal.add(acc, pnl)}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp position_unrealized(position, limits, opts) do
    size = Map.get(position, :size) || Decimal.new(0)

    if Decimal.compare(size, Decimal.new(0)) != :gt do
      {:ok, {Decimal.new(0), nil}}
    else
      product_code = Map.fetch!(position, :product_code)
      key = MarketData.ticker_key(product_code)
      max_age = limits.market_data_max_age_ms
      fresh_opts = Keyword.take(opts, [:now, :server])

      cond do
        not Cache.fresh?(key, max_age, fresh_opts) ->
          {:error, :stale,
           %{reason: :mark_price_unavailable, market_key: key, product_code: product_code}}

        true ->
          case fetch_ltp(key, opts) do
            {:ok, ltp} ->
              avg = Map.fetch!(position, :average_price)
              side = Map.fetch!(position, :side)

              case mark_side_pnl(side, avg, ltp, size, product_code) do
                {:ok, pnl} -> {:ok, {pnl, ltp}}
                {:error, _, _} = error -> error
              end

            :miss ->
              {:error, :stale,
               %{reason: :mark_price_unavailable, market_key: key, product_code: product_code}}
          end
      end
    end
  end

  defp mark_side_pnl(:buy, avg, ltp, size, _product_code) do
    {:ok, ltp |> Decimal.sub(avg) |> Decimal.mult(size)}
  end

  defp mark_side_pnl(:sell, avg, ltp, size, _product_code) do
    {:ok, avg |> Decimal.sub(ltp) |> Decimal.mult(size)}
  end

  defp mark_side_pnl(side, _avg, _ltp, _size, product_code) do
    {:error, :unsynced, %{reason: :position_side_invalid, product_code: product_code, side: side}}
  end

  defp fetch_ltp(key, opts) do
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

  defp limits(opts) do
    opts
    |> Keyword.get_lazy(:limits, &Limits.current/0)
    |> Limits.normalize()
  end
end
