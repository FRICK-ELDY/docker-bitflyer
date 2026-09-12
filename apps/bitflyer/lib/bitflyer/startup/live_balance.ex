defmodule Bitflyer.Startup.LiveBalance do
  @moduledoc """
  live 残高の説明可能な前進。

  取引所 `getbalance` を正本にする。内部 tip からの **amount** 変化が、
  直近 tip 以降の spot Fill 合計と **支払超過側** の手数料許容で説明できるときだけ
  新しい `BalanceSnapshot` を append し、次回比較の基準を進める。

  `available` は未約定拘束で変わりうるため、tip との厳密一致は要求しない
  （amount が説明でき、`available <= amount` なら取引所値を新 tip にする）。

  手数料許容は **支払超過（actual < expected）だけ**。増加は入金として即
  `balance_mismatch`（20bps 以内でも前進しない）。Fill が無い通貨の絶対床は 0。
  減る側の床は Fill があるときの丸め専用。20bps は実手数料の上限見積りであり、
  大口直後の帯域内出金は実手数料と区別できない（P1 #4 で execution fee を記帳するまで）。
  取引所 amount が tip のままで Fill が減額を予測しているときは `balance_exchange_lag`
  （突合側が getbalance を 1 回再取得する）。

  Fill 経路では残高を書き換えない（`LiveFills`）。初期 tip は `Baseline.import/1`、
  人手での強制上書きは承認付き `Baseline.import(rebaseline?: true)`。
  """

  require Ash.Query

  alias Bitflyer.Startup.Reconcile
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Product}

  # Balances=1 / Baseline import=2 と衝突させない
  @advance_lock_namespace 3

  @type snapshot_like :: %{
          optional(:currency) => String.t(),
          optional(:amount) => Decimal.t(),
          optional(:available) => Decimal.t(),
          optional(:captured_at) => DateTime.t(),
          optional(:inserted_at) => DateTime.t(),
          atom() => term()
        }

  @type plan_row :: %{
          currency: String.t(),
          amount: Decimal.t(),
          available: Decimal.t(),
          changed?: boolean()
        }

  @type plan :: %{
          trade_mode: Bitflyer.TradeMode.t(),
          rows: [plan_row()],
          captured_at: DateTime.t(),
          baselines: %{optional(String.t()) => DateTime.t()}
        }

  @doc """
  内部 tip と取引所残高を照合し、前進プランを返す（DB には書かない）。

  ## Options
  - `:trade_mode` — 既定 `:live`
  - `:fills` — Fill リスト注入（省略時は tip 以降を読む）
  - `:now` — `captured_at` の壁時計
  - `:fee_tolerance_bps` / `:fee_tolerance_abs` — 省略時は Application env
  """
  @spec explain([snapshot_like()], [snapshot_like()], [String.t()], keyword()) ::
          {:ok, plan()} | {:error, atom(), map()}
  def explain(internal_snaps, external, required, opts \\ [])
      when is_list(internal_snaps) and is_list(external) and is_list(required) do
    trade_mode = Keyword.get(opts, :trade_mode, :live)
    internal_map = Map.new(internal_snaps, &{currency(&1), &1})
    external_map = Map.new(external, &{currency(&1), &1})

    with :ok <- ensure_required(internal_map, required),
         {:ok, fills} <- resolve_fills(internal_snaps, trade_mode, opts),
         {:ok, rows} <-
           explain_currencies(internal_map, external_map, fills, opts) do
      {:ok,
       %{
         trade_mode: trade_mode,
         rows: rows,
         captured_at: captured_at_for(fills, opts),
         baselines: baseline_watermarks(internal_snaps)
       }}
    end
  end

  @doc """
  説明済みプランのうち、tip から変わった通貨だけ append する。
  """
  @spec advance(plan(), keyword()) :: :ok | {:error, atom(), map()}
  def advance(%{rows: rows} = plan, _opts \\ []) do
    changed = Enum.filter(rows, & &1.changed?)

    if changed == [] do
      :ok
    else
      persist_changed(plan, changed)
    end
  end

  @doc """
  突合成功時の explain → advance。
  """
  @spec explain_and_advance([snapshot_like()], [snapshot_like()], [String.t()], keyword()) ::
          :ok | {:error, atom(), map()}
  def explain_and_advance(internal_snaps, external, required, opts \\ []) do
    with {:ok, plan} <- explain(internal_snaps, external, required, opts) do
      advance(plan, opts)
    end
  end

  defp ensure_required(internal_map, required) do
    case Enum.find(required, fn currency -> not Map.has_key?(internal_map, currency) end) do
      nil ->
        :ok

      currency ->
        {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing, currency: currency}}
    end
  end

  defp explain_currencies(internal_map, external_map, fills, opts) do
    Enum.reduce_while(Map.keys(internal_map), {:ok, []}, fn currency, {:ok, acc} ->
      case Map.fetch(external_map, currency) do
        :error ->
          {:halt,
           {:error, :reconcile_mismatch, %{kind: :balance_missing_exchange, currency: currency}}}

        {:ok, right} ->
          left = Map.fetch!(internal_map, currency)

          case explain_currency(currency, left, right, fills, opts) do
            {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
            {:error, _, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp explain_currency(currency, left, right, fills, opts) do
    left_amount = Map.get(left, :amount)
    right_amount = Map.get(right, :amount)
    right_available = Map.get(right, :available) || right_amount
    left_available = Map.get(left, :available)

    cond do
      not match?(%Decimal{}, left_amount) or not match?(%Decimal{}, right_amount) or
          not match?(%Decimal{}, right_available) ->
        {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}}

      Decimal.compare(right_available, right_amount) == :gt ->
        {:error, :reconcile_mismatch, %{kind: :balance_mismatch, currency: currency}}

      true ->
        relevant = fills_for_currency(fills, currency, left)
        expected = Decimal.add(left_amount, fill_amount_delta(relevant, currency))
        unexplained = Decimal.sub(right_amount, expected)
        allowance = fee_allowance(currency, relevant, opts)

        cond do
          fee_explained?(unexplained, allowance) ->
            changed? =
              not Decimal.eq?(left_amount, right_amount) or
                not (match?(%Decimal{}, left_available) and
                       Decimal.eq?(left_available, right_available))

            {:ok,
             %{
               currency: currency,
               amount: right_amount,
               available: right_available,
               changed?: changed?
             }}

          exchange_lag?(left_amount, right_amount, expected, relevant) ->
            {:error, :reconcile_mismatch,
             mismatch_meta(
               :balance_exchange_lag,
               currency,
               expected,
               right_amount,
               unexplained,
               allowance
             )}

          true ->
            {:error, :reconcile_mismatch,
             mismatch_meta(
               :balance_mismatch,
               currency,
               expected,
               right_amount,
               unexplained,
               allowance
             )}
        end
    end
  end

  defp fills_for_currency(fills, currency, tip) do
    since = watermark(tip)

    Enum.filter(fills, fn fill ->
      Product.spot?(fill.product_code) and
        affects_currency?(fill, currency) and
        not_before?(fill_watermark(fill), since)
    end)
  end

  defp watermark(tip) do
    Map.get(tip, :captured_at) || Map.get(tip, :inserted_at)
  end

  defp fill_watermark(fill) do
    Map.get(fill, :inserted_at) || Map.get(fill, :filled_at)
  end

  # tip と同時刻の Fill を落とさない。前進側で captured_at を Fill より後にする。
  defp not_before?(%DateTime{} = at, %DateTime{} = since) do
    DateTime.compare(at, since) != :lt
  end

  defp not_before?(_, _), do: false

  defp affects_currency?(fill, currency) do
    Product.base_currency(fill.product_code) == currency or
      Product.quote_currency(fill.product_code) == currency
  end

  # Fill はあるが取引所 amount が tip のまま → getbalance 未反映の可能性。
  defp exchange_lag?(left_amount, right_amount, expected, fills) do
    fills != [] and
      Decimal.eq?(right_amount, left_amount) and
      not Decimal.eq?(expected, left_amount)
  end

  defp mismatch_meta(kind, currency, expected, actual, unexplained, allowance) do
    %{
      kind: kind,
      currency: currency,
      expected: decimal_meta(expected),
      actual: decimal_meta(actual),
      unexplained: decimal_meta(unexplained),
      allowance: decimal_meta(allowance)
    }
  end

  # 手数料は残高を減らす側にしか出ない。増加（入金）は許容幅内でも拒否する。
  defp fee_explained?(unexplained, allowance) do
    cond do
      Decimal.compare(unexplained, 0) == :gt ->
        false

      Decimal.compare(Decimal.negate(unexplained), allowance) == :gt ->
        false

      true ->
        true
    end
  end

  defp fill_amount_delta(fills, currency) do
    Enum.reduce(fills, Decimal.new(0), fn fill, acc ->
      Decimal.add(acc, fill_delta(fill, currency))
    end)
  end

  defp fill_delta(fill, currency) do
    base = Product.base_currency(fill.product_code)
    quote = Product.quote_currency(fill.product_code)
    size = fill.size
    notional = Decimal.mult(size, fill.price)

    case fill.side do
      :buy when currency == quote -> Decimal.negate(notional)
      :buy when currency == base -> size
      :sell when currency == base -> Decimal.negate(size)
      :sell when currency == quote -> notional
      _ -> Decimal.new(0)
    end
  end

  # 減る側のみ。from_bps は実手数料の見積り上限（P1 #4 まで出金と区別できない）。
  defp fee_allowance(currency, fills, opts) do
    if fills == [] do
      Decimal.new(0)
    else
      abs_floor = tolerance_abs(currency, opts)
      bps = tolerance_bps(opts)
      notionals = quote_notional_abs(fills, currency)
      sizes = base_size_abs(fills, currency)

      # 同一通貨が quote（ETH_BTC の BTC）と base（BTC_JPY の BTC）の両方になりうる。
      # どちらも当該通貨建なので、bps を掛けたあと合算する（notional と size を足さない）。
      from_quote = Decimal.div(Decimal.mult(notionals, bps), Decimal.new(10_000))
      from_base = Decimal.div(Decimal.mult(sizes, bps), Decimal.new(10_000))
      from_bps = Decimal.add(from_quote, from_base)

      if Decimal.compare(from_bps, abs_floor) == :gt, do: from_bps, else: abs_floor
    end
  end

  defp quote_notional_abs(fills, currency) do
    Enum.reduce(fills, Decimal.new(0), fn fill, acc ->
      if Product.quote_currency(fill.product_code) == currency do
        Decimal.add(acc, Decimal.mult(fill.size, fill.price))
      else
        acc
      end
    end)
  end

  defp base_size_abs(fills, currency) do
    Enum.reduce(fills, Decimal.new(0), fn fill, acc ->
      if Product.base_currency(fill.product_code) == currency do
        Decimal.add(acc, fill.size)
      else
        acc
      end
    end)
  end

  defp tolerance_bps(opts) do
    parse_decimal(
      Keyword.get_lazy(opts, :fee_tolerance_bps, fn ->
        reconcile_env(:balance_fee_tolerance_bps, "20")
      end)
    )
  end

  defp tolerance_abs(currency, opts) do
    abs_map =
      Keyword.get_lazy(opts, :fee_tolerance_abs, fn ->
        reconcile_env(:balance_fee_tolerance_abs, %{"JPY" => "1", "BTC" => "0.00000001"})
      end)

    parse_decimal(Map.get(abs_map, currency, 0))
  end

  defp reconcile_env(key, default) do
    Application.get_env(:bitflyer, Reconcile, [])
    |> Keyword.get(key, default)
  end

  # float は受けない（金額の float 禁止。config は string / Decimal / integer）。
  # 未知型は 0（許容なし）へ倒し、端数をごまかして前進しない。
  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp parse_decimal(_), do: Decimal.new(0)

  defp resolve_fills(internal_snaps, trade_mode, opts) do
    case Keyword.fetch(opts, :fills) do
      {:ok, fills} when is_list(fills) ->
        {:ok, fills}

      :error ->
        load_fills_since(internal_snaps, trade_mode)
    end
  end

  defp load_fills_since(internal_snaps, trade_mode) do
    since =
      internal_snaps
      |> Enum.map(&watermark/1)
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> Enum.min(DateTime, fn -> nil end)

    query =
      Fill
      |> Ash.Query.filter(trade_mode == ^trade_mode)

    query =
      if match?(%DateTime{}, since) do
        Ash.Query.filter(query, inserted_at >= ^since)
      else
        query
      end

    case Ash.read(query) do
      {:ok, fills} -> {:ok, fills}
      {:error, error} -> {:error, :restore_failed, %{detail: error, step: :live_balance_fills}}
    end
  end

  defp captured_at_for(fills, opts) do
    now =
      Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
      |> DateTime.truncate(:microsecond)

    fill_times =
      fills
      |> Enum.map(&fill_watermark/1)
      |> Enum.filter(&match?(%DateTime{}, &1))

    # 次回 explain で今回の Fill を再計上しないよう、now / Fill より 1µs 後にする
    DateTime.add(Enum.max([now | fill_times], DateTime), 1, :microsecond)
  end

  defp persist_changed(plan, changed) do
    captured_at = plan.captured_at
    trade_mode = plan.trade_mode

    case Bitflyer.Repo.transaction(fn ->
           with :ok <- acquire_advance_lock(trade_mode),
                {:ok, latest} <- current_tips(trade_mode),
                {:ok, to_write} <- resolve_advance(plan, changed, latest) do
             Enum.reduce(to_write, [], fn row, acc ->
               case BalanceSnapshot
                    |> Ash.Changeset.for_create(:create, %{
                      currency: row.currency,
                      amount: row.amount,
                      available: row.available,
                      captured_at: captured_at,
                      trade_mode: trade_mode
                    })
                    |> Ash.create(return_notifications?: true) do
                 {:ok, _snap, notifications} ->
                   acc ++ notifications

                 {:error, error} ->
                   Bitflyer.Repo.rollback({:persist_failed, error, row.currency})
               end
             end)
           else
             {:error, reason, details} when is_atom(reason) and is_map(details) ->
               Bitflyer.Repo.rollback({reason, details})

             other ->
               Bitflyer.Repo.rollback(
                 {:persist_failed, %{error: other, step: :live_balance_advance}}
               )
           end
         end) do
      {:ok, notifications} ->
        _ = Ash.Notifier.notify(notifications)

        if notifications != [] do
          Bitflyer.Telemetry.log(:info, "live balance tip advanced from exchange", %{
            trade_mode: trade_mode,
            kind: :live_balance_advanced,
            currencies: Enum.map(changed, & &1.currency)
          })
        end

        :ok

      {:error, {:persist_failed, error, currency}} ->
        {:error, :persist_failed,
         %{error: error, currency: currency, step: :live_balance_advance}}

      {:error, {reason, details}} when is_atom(reason) and is_map(details) ->
        {:error, reason, details}

      {:error, error} ->
        {:error, :persist_failed, %{error: error, step: :live_balance_advance}}
    end
  end

  defp baseline_watermarks(internal_snaps) do
    Map.new(internal_snaps, fn snap ->
      {currency(snap), watermark(snap)}
    end)
  end

  defp current_tips(trade_mode) do
    case BalanceSnapshot.latest_tips(trade_mode) do
      {:ok, rows} -> {:ok, rows}
      {:error, error} -> {:error, :persist_failed, %{error: error, step: :live_balance_tips}}
    end
  end

  # Resume と定期突合が重なったとき、古い getbalance の plan で新しい tip を上書きしない。
  defp resolve_advance(plan, changed, latest) do
    latest_map = Map.new(latest, &{currency(&1), &1})
    baselines = Map.get(plan, :baselines, %{})

    cond do
      tip_moved_since_explain?(changed, latest_map, baselines) ->
        # 他方が先に tip を進めた。古い plan では上書きも halt もしない。
        Bitflyer.Telemetry.log(:info, "live balance advance skipped; tip already moved", %{
          trade_mode: plan.trade_mode,
          kind: :live_balance_stale_skipped,
          currencies: Enum.map(changed, & &1.currency)
        })

        {:ok, []}

      true ->
        {:ok, changed}
    end
  end

  defp tip_moved_since_explain?(changed, latest_map, baselines) do
    Enum.any?(changed, fn row ->
      case {Map.get(latest_map, row.currency), Map.get(baselines, row.currency)} do
        {%{} = tip, %DateTime{} = since} ->
          DateTime.compare(watermark(tip), since) == :gt

        _ ->
          false
      end
    end)
  end

  defp decimal_meta(%Decimal{} = value) do
    value |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp decimal_meta(value), do: value

  defp acquire_advance_lock(trade_mode) do
    key = :erlang.phash2({:live_balance_advance, trade_mode}, 2_147_483_647)

    case Bitflyer.Repo.query("SELECT pg_advisory_xact_lock($1, $2)", [
           @advance_lock_namespace,
           key
         ]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, :persist_failed, %{error: error, step: :live_balance_lock}}
    end
  end

  defp currency(row), do: Map.fetch!(row, :currency)
end
