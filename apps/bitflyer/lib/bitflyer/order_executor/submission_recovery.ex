defmodule Bitflyer.OrderExecutor.SubmissionRecovery do
  @moduledoc """
  `submission_unknown` および **persist_failed 由来の ID 未埋込 `pending`** の回収。

  未送信のただの `pending`（まだ place していない）を指紋一致で bind しない想定。
  対象は timeout 等の `submission_unknown` と、取引所受注後に ID 永続化だけ失敗した
  `pending` + `exchange_order_id: nil`。

  取引所 `list_child_orders` を時刻窓 + side + size（limit は price）で照合する。
  - 候補 1 件: confirm + dry-run の hash 一致で ID 埋込
  - 候補複数: `--exchange-order-id` 承認が必須（自動確定しない）
  - 候補 0: `--absent` で cancelled 化。**hold は解放しない**（誤 absent で残高過大評価しない）

  `child_order_date` 欠落・不正や一覧が要求件数を超えて返る場合（内部で count+1 を要求）は
  fail-closed（誤って `match=none` にしない）。ちょうど count 件しか無い口座でも成功する。

  誤 `--absent` で `cancelled` になっても、ID 未埋込なら再 recover で紐付け可能（hold は継続）。

  Ready にはしない。成功後は `mix bitflyer.resume` で再突合する。
  """

  require Ash.Query

  alias Bitflyer.Trading.Order

  @default_window_seconds 300
  # bitFlyer 既定ページは小さめ。窓内注文の取りこぼしを避けるため回収は多め。
  @default_list_count 500
  # cancelled + ID 無しは誤 --absent 後の再紐付け用（hold 残存のまま ID を付け直す）
  @recoverable_statuses [:submission_unknown, :pending, :cancelled]

  @type candidate :: Bitflyer.Exchange.Client.child_order()

  @type preview :: %{
          dry_run?: boolean(),
          operator: String.t(),
          order: Order.t(),
          candidates: [candidate()],
          match: :unique | :ambiguous | :none,
          snapshot_hash: String.t(),
          window_seconds: pos_integer()
        }

  @type result ::
          {:ok, preview()}
          | {:ok, map()}
          | {:error, atom()}
          | {:error, atom(), map()}

  @doc """
  候補照合の preview、または承認付き確定。

  ## Options
  - `:dry_run?` / `:confirm?` — 排他。confirm 時は `:expected_hash` 必須
  - `:operator` — 必須
  - `:internal_order_id` — 必須
  - `:expected_hash` — confirm 必須（dry-run の `snapshot_hash`）
  - `:exchange_order_id` — 曖昧時の承認 ID（候補内にあること）
  - `:absent?` — 候補 0 のとき取引所に無いと承認して cancelled 化（hold は残す）
  - `:window_seconds` — 既定 300
  - `:exchange` — 既定 `Bitflyer.Exchange`
  - `:count` — 照合に使う最大件数（既定 500）。内部では count+1 を要求し、超過時のみ切り捨て失敗
  """
  @spec recover(keyword()) :: result()
  def recover(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, false) == true
    confirm? = Keyword.get(opts, :confirm?, false) == true

    with :ok <- validate_mode_flags(dry_run?, confirm?),
         {:ok, operator} <- normalize_operator(Keyword.get(opts, :operator)),
         {:ok, internal_order_id} <-
           normalize_required_string(
             Keyword.get(opts, :internal_order_id),
             :internal_order_id_required
           ),
         {:ok, order} <- load_recoverable_order(internal_order_id, dry_run?: dry_run?),
         window_seconds <- Keyword.get(opts, :window_seconds, @default_window_seconds),
         exchange <- Keyword.get(opts, :exchange, Bitflyer.Exchange),
         count <- Keyword.get(opts, :count, @default_list_count),
         {:ok, listed} <- list_orders(exchange, order.product_code, count),
         {:ok, taken} <- taken_exchange_ids(order),
         candidates <- filter_candidates(order, listed, taken, window_seconds),
         snapshot_hash <- candidates_hash(order, candidates),
         :ok <-
           maybe_verify_expected_hash(dry_run?, snapshot_hash, Keyword.get(opts, :expected_hash)),
         preview <- %{
           dry_run?: dry_run?,
           operator: operator,
           order: order,
           candidates: candidates,
           match: match_kind(candidates),
           snapshot_hash: snapshot_hash,
           window_seconds: window_seconds
         } do
      if dry_run? do
        Bitflyer.Telemetry.log(:info, "submission recovery dry-run", %{
          trade_mode: order.trade_mode,
          kind: :submission_recovery_dry_run,
          operator: operator,
          snapshot_hash: snapshot_hash,
          internal_order_id: order.internal_order_id
        })

        {:ok, preview}
      else
        apply_confirm(preview, exchange, opts)
      end
    end
  end

  @doc false
  @spec candidates_hash(Order.t(), [candidate()]) :: String.t()
  def candidates_hash(%Order{} = order, candidates) when is_list(candidates) do
    ids =
      candidates
      |> Enum.map(& &1.exchange_order_id)
      |> Enum.sort()
      |> Enum.join(",")

    price =
      case order.price do
        %Decimal{} = p -> Decimal.to_string(p, :normal)
        _ -> ""
      end

    [
      order.internal_order_id,
      Atom.to_string(order.side),
      Decimal.to_string(order.size, :normal),
      Atom.to_string(order.order_type),
      price,
      ids
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_mode_flags(true, true), do: {:error, :ambiguous_mode}
  defp validate_mode_flags(false, false), do: {:error, :confirm_required}
  defp validate_mode_flags(_, _), do: :ok

  defp normalize_operator(nil), do: {:error, :operator_required}

  defp normalize_operator(operator) when is_binary(operator) do
    trimmed = String.trim(operator)
    if trimmed == "", do: {:error, :operator_required}, else: {:ok, trimmed}
  end

  defp normalize_operator(_), do: {:error, :operator_required}

  defp normalize_required_string(nil, reason), do: {:error, reason}

  defp normalize_required_string(value, reason) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, reason}, else: {:ok, trimmed}
  end

  defp normalize_required_string(_, reason), do: {:error, reason}

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
    if trimmed == "", do: {:error, :expected_hash_required}, else: {:ok, trimmed}
  end

  defp normalize_expected_hash(_), do: {:error, :expected_hash_required}

  defp load_recoverable_order(internal_order_id, opts) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false) == true

    case Order
         |> Ash.Query.filter(internal_order_id == ^internal_order_id)
         |> Ash.read_one() do
      {:ok, nil} ->
        {:error, :order_not_found, %{internal_order_id: internal_order_id}}

      {:ok, %Order{trade_mode: mode}} when mode != :live ->
        {:error, :live_only, %{trade_mode: mode}}

      {:ok, %Order{exchange_order_id: id, status: :submission_unknown} = order}
      when is_binary(id) and id != "" ->
        # drain 競合で ID だけ埋まった残骸。confirm 時のみ pending に直す（dry-run は書かない）
        if dry_run? do
          {:error, :already_resolved,
           %{
             internal_order_id: order.internal_order_id,
             exchange_order_id: id,
             healed_from: :submission_unknown,
             heal_pending?: true
           }}
        else
          case heal_unknown_with_exchange_id(order) do
            {:ok, healed} ->
              {:error, :already_resolved,
               %{
                 internal_order_id: healed.internal_order_id,
                 exchange_order_id: healed.exchange_order_id,
                 healed_from: :submission_unknown
               }}

            {:error, error} ->
              {:error, :restore_failed, %{error: error}}
          end
        end

      {:ok, %Order{exchange_order_id: id} = order} when is_binary(id) and id != "" ->
        {:error, :already_resolved,
         %{internal_order_id: order.internal_order_id, exchange_order_id: id}}

      {:ok, %Order{status: status} = order}
      when status in @recoverable_statuses ->
        # cancelled は ID 未埋込の誤 absent 後のみ再回収可（上の句で ID 有りは拒否済み）
        {:ok, order}

      {:ok, %Order{status: status}} ->
        {:error, :not_recoverable, %{status: status}}

      {:error, error} ->
        {:error, :restore_failed, %{error: error}}
    end
  end

  defp list_orders(exchange, product_code, count)
       when is_integer(count) and count > 0 do
    # count 件ちょうどでも成功させるため、count+1 を取り超過時だけ切り捨てとみなす。
    probe = count + 1

    case exchange.list_child_orders(%{product_code: product_code, count: probe}) do
      {:ok, rows} when is_list(rows) ->
        if length(rows) > count do
          {:error, :child_order_list_truncated, %{count: count, returned: length(rows)}}
        else
          {:ok, rows}
        end

      {:error, :invalid_number} ->
        {:error, :invalid_exchange_payload, %{kind: :invalid_number}}

      {:error, :invalid_datetime} ->
        {:error, :invalid_exchange_payload, %{kind: :invalid_datetime}}

      {:error, reason} when is_atom(reason) ->
        {:error, :exchange_unavailable, %{reason: reason}}

      other ->
        {:error, :exchange_unavailable, %{reason: other}}
    end
  end

  defp taken_exchange_ids(%Order{} = order) do
    case Order
         |> Ash.Query.filter(
           trade_mode == :live and not is_nil(exchange_order_id) and
             internal_order_id != ^order.internal_order_id
         )
         |> Ash.read() do
      {:ok, orders} ->
        {:ok, MapSet.new(orders, & &1.exchange_order_id)}

      {:error, error} ->
        {:error, :restore_failed, %{error: error}}
    end
  end

  defp filter_candidates(order, listed, taken, window_seconds) do
    Enum.filter(listed, fn child ->
      not MapSet.member?(taken, child.exchange_order_id) and
        fingerprint_match?(order, child, window_seconds)
    end)
  end

  defp fingerprint_match?(order, child, window_seconds) do
    order.product_code == child.product_code and
      order.side == child.side and
      match?(%Decimal{}, child.size) and
      Decimal.eq?(order.size, child.size) and
      price_match?(order, child) and
      within_window?(order.inserted_at, child.ordered_at, window_seconds)
  end

  defp price_match?(%Order{order_type: :market}, _child), do: true

  defp price_match?(%Order{order_type: :limit, price: %Decimal{} = price}, child) do
    match?(%Decimal{}, child.price) and Decimal.eq?(price, child.price)
  end

  defp price_match?(_, _), do: false

  defp within_window?(%DateTime{} = inserted_at, %DateTime{} = ordered_at, window_seconds)
       when is_integer(window_seconds) and window_seconds > 0 do
    abs(DateTime.diff(ordered_at, inserted_at, :second)) <= window_seconds
  end

  defp within_window?(_, _, _), do: false

  defp match_kind([]), do: :none
  defp match_kind([_]), do: :unique
  defp match_kind(_), do: :ambiguous

  defp apply_confirm(preview, exchange, opts) do
    absent? = Keyword.get(opts, :absent?, false) == true
    approved_id = Keyword.get(opts, :exchange_order_id)

    cond do
      absent? and preview.match == :none ->
        mark_absent(preview)

      absent? ->
        {:error, :absent_not_applicable, %{match: preview.match}}

      preview.match == :none ->
        {:error, :not_found_on_exchange,
         %{internal_order_id: preview.order.internal_order_id, hint: :use_absent}}

      preview.match == :unique and is_nil(approved_id) ->
        [only | _] = preview.candidates
        bind_id(preview, only.exchange_order_id, exchange)

      preview.match == :unique and is_binary(approved_id) ->
        [only | _] = preview.candidates
        unique_id = only.exchange_order_id

        if String.trim(approved_id) == unique_id do
          bind_id(preview, unique_id, exchange)
        else
          {:error, :exchange_order_id_mismatch,
           %{expected: unique_id, given: String.trim(approved_id)}}
        end

      preview.match == :ambiguous ->
        confirm_ambiguous(preview, approved_id, exchange)
    end
  end

  defp confirm_ambiguous(_preview, nil, _exchange), do: {:error, :ambiguous_requires_id}

  defp confirm_ambiguous(preview, approved_id, exchange) when is_binary(approved_id) do
    id = String.trim(approved_id)

    case Enum.find(preview.candidates, &(&1.exchange_order_id == id)) do
      nil ->
        {:error, :exchange_order_id_not_in_candidates, %{exchange_order_id: id}}

      _child ->
        bind_id(preview, id, exchange)
    end
  end

  defp confirm_ambiguous(_, _, _), do: {:error, :ambiguous_requires_id}

  defp heal_unknown_with_exchange_id(%Order{status: :submission_unknown} = order) do
    order
    |> Ash.Changeset.for_update(:update, %{status: :pending})
    |> Ash.update()
  end

  defp bind_id(preview, exchange_order_id, exchange) do
    order = preview.order

    attrs =
      if order.status == :submission_unknown do
        %{exchange_order_id: exchange_order_id, status: :pending}
      else
        %{exchange_order_id: exchange_order_id}
      end

    case order
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update() do
      {:ok, updated} ->
        case Bitflyer.OrderExecutor.LiveFills.sync_order(updated, exchange: exchange) do
          :ok ->
            finish_bound(preview, updated)

          {:ok, synced} ->
            finish_bound(preview, synced)

          {:error, reason, details} ->
            # ID は埋めた。fill 同期失敗はログし、resume で再試行させる。
            Bitflyer.Telemetry.log(:warning, "submission recovery bound; fill sync failed", %{
              trade_mode: :live,
              kind: :submission_recovery_sync_failed,
              reason: reason,
              internal_order_id: updated.internal_order_id,
              exchange_order_id: exchange_order_id
            })

            finish_bound(preview, updated, %{sync_error: reason, sync_details: details})
        end

      {:error, %Ash.Error.Invalid{} = error} ->
        if identity_taken?(error) do
          {:error, :exchange_order_id_taken, %{exchange_order_id: exchange_order_id}}
        else
          {:error, :persist_failed, %{error: error}}
        end

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp identity_taken?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{class: :forbidden} -> false
      %{field: :exchange_order_id} -> true
      %{vars: %{key: :unique_exchange_order_id}} -> true
      other -> inspect(other) =~ "unique_exchange_order_id"
    end)
  end

  defp identity_taken?(_), do: false

  defp finish_bound(preview, order, extra \\ %{}) do
    Bitflyer.Telemetry.log(:info, "submission recovery bound", %{
      trade_mode: :live,
      kind: :submission_recovery_bound,
      operator: preview.operator,
      snapshot_hash: preview.snapshot_hash,
      internal_order_id: order.internal_order_id,
      exchange_order_id: order.exchange_order_id
    })

    {:ok,
     Map.merge(
       %{
         dry_run?: false,
         action: :bound,
         operator: preview.operator,
         order: order,
         exchange_order_id: order.exchange_order_id,
         snapshot_hash: preview.snapshot_hash,
         candidates: preview.candidates,
         match: preview.match
       },
       extra
     )}
  end

  defp mark_absent(preview) do
    order = preview.order

    case order
         |> Ash.Changeset.for_update(:update, %{status: :cancelled})
         |> Ash.update() do
      {:ok, updated} ->
        # hold は解放しない。誤 absent でローカル available が過大になるのを防ぐ。
        # 取引所に拘束が無いと確認できたあと、resume 突合や運用手順で揃える。
        Bitflyer.Telemetry.log(:info, "submission recovery marked absent (hold retained)", %{
          trade_mode: :live,
          kind: :submission_recovery_absent,
          operator: preview.operator,
          snapshot_hash: preview.snapshot_hash,
          internal_order_id: updated.internal_order_id
        })

        {:ok,
         %{
           dry_run?: false,
           action: :absent,
           hold_released?: false,
           operator: preview.operator,
           order: updated,
           snapshot_hash: preview.snapshot_hash,
           candidates: [],
           match: :none
         }}

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end
end
