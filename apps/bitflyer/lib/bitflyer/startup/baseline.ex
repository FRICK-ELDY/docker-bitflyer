defmodule Bitflyer.Startup.Baseline do
  @moduledoc """
  live 初回の BalanceSnapshot baseline を取引所残高から取り込む。

  承認付き（`--confirm` / `confirm?: true`）でのみ書き込む。
  confirm 時は dry-run で見た `expected_hash` と再取得結果の hash が一致すること。
  必須通貨のうち tip が無いものだけを書く（欠落分の補完可）。
  dry-run / confirm とも Ready にはしない。
  Ready は通常の起動・定期突合（または `resume`）成功時のみ。
  """

  alias Bitflyer.Startup.Reconcile
  alias Bitflyer.Trading.{BalanceSnapshot, BaselineImport}

  # pg_advisory_xact_lock 用。Balances の namespace 1 と衝突させない。
  @baseline_lock_namespace 2

  @type balance_row :: %{
          currency: String.t(),
          amount: Decimal.t(),
          available: Decimal.t()
        }

  @type preview :: %{
          dry_run?: boolean(),
          trade_mode: Bitflyer.TradeMode.t(),
          operator: String.t(),
          snapshot_hash: String.t(),
          balances: [balance_row()],
          currencies: [String.t()]
        }

  @type confirm_result :: %{
          dry_run?: false,
          trade_mode: Bitflyer.TradeMode.t(),
          operator: String.t(),
          snapshot_hash: String.t(),
          balances: [balance_row()],
          currencies: [String.t()],
          import: BaselineImport.t()
        }

  @type result ::
          {:ok, preview()}
          | {:ok, confirm_result()}
          | {:error, atom()}
          | {:error, atom(), map()}

  @doc """
  取引所残高を取得し、未整備の必須通貨 baseline を preview または永続化する。

  ## Options
  - `:dry_run?` — true なら DB に書かず preview のみ（既定 false）
  - `:confirm?` — true のときだけ書き込む（既定 false）。dry-run と同時指定は拒否
  - `:expected_hash` — confirm 必須。dry-run で表示した `snapshot_hash` と一致させる
  - `:operator` — 必須（非空）。Mix では `BITFLYER_BASELINE_OPERATOR`
  - `:trade_mode` — 既定は `TradeMode.current/0`。`:live` 以外は拒否
  - `:exchange` — 既定 `Bitflyer.Exchange`
  - `:required_balance_currencies` — 既定は Reconcile 設定（JPY / BTC）
  """
  @spec import(keyword()) :: result()
  def import(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, false) == true
    confirm? = Keyword.get(opts, :confirm?, false) == true

    with :ok <- validate_mode_flags(dry_run?, confirm?),
         {:ok, operator} <- normalize_operator(Keyword.get(opts, :operator)),
         trade_mode <- Keyword.get_lazy(opts, :trade_mode, &Bitflyer.TradeMode.current/0),
         :ok <- require_live(trade_mode),
         required <-
           Keyword.get_lazy(opts, :required_balance_currencies, &required_balance_currencies/0),
         exchange <- Keyword.get(opts, :exchange, Bitflyer.Exchange),
         {:ok, missing} <- missing_required_currencies(trade_mode, required),
         {:ok, balances} <- fetch_required_balances(exchange, missing),
         snapshot_hash <- snapshot_hash(balances),
         :ok <-
           maybe_verify_expected_hash(dry_run?, snapshot_hash, Keyword.get(opts, :expected_hash)),
         preview <- %{
           dry_run?: dry_run?,
           trade_mode: trade_mode,
           operator: operator,
           snapshot_hash: snapshot_hash,
           balances: balances,
           currencies: Enum.map(balances, & &1.currency)
         } do
      if dry_run? do
        Bitflyer.Telemetry.log(:info, "baseline import dry-run", %{
          trade_mode: trade_mode,
          kind: :baseline_import_dry_run,
          operator: operator,
          snapshot_hash: snapshot_hash
        })

        {:ok, preview}
      else
        persist(preview, required)
      end
    end
  end

  defp validate_mode_flags(true, true), do: {:error, :ambiguous_mode}
  defp validate_mode_flags(false, false), do: {:error, :confirm_required}
  defp validate_mode_flags(_, _), do: :ok

  defp require_live(:live), do: :ok
  defp require_live(other), do: {:error, :live_only, %{trade_mode: other}}

  defp normalize_operator(nil), do: {:error, :operator_required}

  defp normalize_operator(operator) when is_binary(operator) do
    trimmed = String.trim(operator)

    if trimmed == "" do
      {:error, :operator_required}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_operator(_), do: {:error, :operator_required}

  defp maybe_verify_expected_hash(true, _actual, _expected), do: :ok

  defp maybe_verify_expected_hash(false, actual, expected) do
    case normalize_expected_hash(expected) do
      {:ok, ^actual} ->
        :ok

      {:ok, normalized} ->
        {:error, :snapshot_hash_mismatch, %{expected: normalized, actual: actual}}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_expected_hash(nil), do: {:error, :expected_hash_required}

  defp normalize_expected_hash(hash) when is_binary(hash) do
    trimmed = hash |> String.trim() |> String.downcase()

    if trimmed == "" do
      {:error, :expected_hash_required}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_expected_hash(_), do: {:error, :expected_hash_required}

  defp required_balance_currencies do
    Application.get_env(:bitflyer, Reconcile, [])
    |> Keyword.get(:required_balance_currencies, ["JPY", "BTC"])
  end

  defp missing_required_currencies(trade_mode, required) do
    case existing_tip_currencies(trade_mode) do
      {:ok, existing} ->
        missing = Enum.reject(required, &MapSet.member?(existing, &1))

        if missing == [] do
          {:error, :baseline_already_complete, %{trade_mode: trade_mode, required: required}}
        else
          {:ok, missing}
        end

      {:error, _, _} = error ->
        error
    end
  end

  defp existing_tip_currencies(trade_mode) do
    case Reconcile.restore(trade_mode) do
      {:ok, %{balance_snapshots: snaps}} ->
        {:ok, MapSet.new(snaps, & &1.currency)}

      {:error, :restore_failed, details} ->
        {:error, :restore_failed, details}
    end
  end

  defp fetch_required_balances(exchange, required) do
    case exchange.fetch_reconcile_snapshot() do
      {:ok, %{balances: balances}} when is_list(balances) ->
        pick_required_balances(balances, required)

      {:error, :invalid_number} ->
        {:error, :invalid_exchange_payload, %{kind: :invalid_number}}

      {:error, reason} when is_atom(reason) ->
        {:error, :exchange_unavailable, %{reason: reason}}

      other ->
        {:error, :exchange_unavailable, %{reason: other}}
    end
  end

  defp pick_required_balances(balances, required) do
    by_currency = Map.new(balances, fn row -> {Map.fetch!(row, :currency), row} end)

    Enum.reduce_while(required, {:ok, []}, fn currency, {:ok, acc} ->
      case Map.fetch(by_currency, currency) do
        {:ok, row} ->
          amount = Map.fetch!(row, :amount)
          available = Map.get(row, :available) || amount

          if match?(%Decimal{}, amount) and match?(%Decimal{}, available) do
            {:cont,
             {:ok,
              acc ++
                [
                  %{
                    currency: currency,
                    amount: amount,
                    available: available
                  }
                ]}}
          else
            {:halt,
             {:error, :invalid_exchange_payload, %{kind: :invalid_number, currency: currency}}}
          end

        :error ->
          {:halt, {:error, :exchange_currency_missing, %{currency: currency, required: required}}}
      end
    end)
  end

  @doc false
  @spec snapshot_hash([balance_row()]) :: String.t()
  def snapshot_hash(balances) when is_list(balances) do
    balances
    |> Enum.sort_by(& &1.currency)
    |> Enum.map_join("\n", fn row ->
      [
        row.currency,
        Decimal.to_string(row.amount, :normal),
        Decimal.to_string(row.available, :normal)
      ]
      |> Enum.join("|")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp persist(%{dry_run?: false} = preview, required) do
    imported_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    payload = payload_from_balances(preview.balances)

    case Bitflyer.Repo.transaction(fn ->
           with :ok <- acquire_baseline_lock(preview.trade_mode),
                :ok <-
                  assert_currencies_still_missing(
                    preview.trade_mode,
                    preview.currencies,
                    required
                  ) do
             notifications =
               Enum.reduce(preview.balances, [], fn row, acc ->
                 case BalanceSnapshot
                      |> Ash.Changeset.for_create(:create, %{
                        currency: row.currency,
                        amount: row.amount,
                        available: row.available,
                        captured_at: imported_at,
                        trade_mode: preview.trade_mode
                      })
                      |> Ash.create(return_notifications?: true) do
                   {:ok, _snap, row_notifications} ->
                     acc ++ row_notifications

                   {:error, error} ->
                     Bitflyer.Repo.rollback({:persist_failed, error})
                 end
               end)

             case BaselineImport
                  |> Ash.Changeset.for_create(:create, %{
                    trade_mode: preview.trade_mode,
                    snapshot_hash: preview.snapshot_hash,
                    operator: preview.operator,
                    imported_at: imported_at,
                    payload: payload
                  })
                  |> Ash.create(return_notifications?: true) do
               {:ok, import_row, import_notifications} ->
                 {import_row, notifications ++ import_notifications}

               {:error, error} ->
                 Bitflyer.Repo.rollback({:persist_failed, error})
             end
           else
             {:error, reason, details} when is_atom(reason) and is_map(details) ->
               Bitflyer.Repo.rollback({reason, details})

             {:error, reason} when is_atom(reason) ->
               Bitflyer.Repo.rollback(reason)
           end
         end) do
      {:ok, {import_row, notifications}} ->
        _ = Ash.Notifier.notify(notifications)

        Bitflyer.Telemetry.log(:info, "baseline import confirmed", %{
          trade_mode: preview.trade_mode,
          kind: :baseline_import_confirmed,
          operator: preview.operator,
          snapshot_hash: preview.snapshot_hash
        })

        {:ok, Map.put(preview, :import, import_row)}

      {:error, {reason, details}} when is_atom(reason) and is_map(details) ->
        {:error, reason, details}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:persist_failed, error}} ->
        {:error, :persist_failed, %{error: error}}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp acquire_baseline_lock(trade_mode) do
    key = :erlang.phash2({:baseline_import, trade_mode}, 2_147_483_647)

    case Bitflyer.Repo.query("SELECT pg_advisory_xact_lock($1, $2)", [
           @baseline_lock_namespace,
           key
         ]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp assert_currencies_still_missing(trade_mode, planned_currencies, required) do
    case missing_required_currencies(trade_mode, required) do
      {:ok, missing} ->
        planned = MapSet.new(planned_currencies)
        actual = MapSet.new(missing)

        cond do
          MapSet.equal?(planned, actual) ->
            :ok

          MapSet.size(actual) == 0 ->
            {:error, :baseline_already_complete, %{trade_mode: trade_mode, required: required}}

          true ->
            {:error, :baseline_race,
             %{planned: Enum.sort(planned_currencies), missing: Enum.sort(missing)}}
        end

      {:error, :baseline_already_complete, details} ->
        {:error, :baseline_already_complete, details}

      {:error, _, _} = error ->
        error
    end
  end

  defp payload_from_balances(balances) do
    %{
      "balances" =>
        Enum.map(balances, fn row ->
          %{
            "currency" => row.currency,
            "amount" => Decimal.to_string(row.amount, :normal),
            "available" => Decimal.to_string(row.available, :normal)
          }
        end)
    }
  end
end
