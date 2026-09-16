defmodule Bitflyer.OrderExecutor.Positions do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{Fill, Order, Position, Product}

  @doc """
  約定を建玉へ反映し、Fill 行を同一トランザクション内に残す。

  戻り値の第 3 要素はコミット後に `Risk.DailyLoss.record_realized/2` へ渡す。
  既存建玉は `FOR UPDATE` でロックし、Lost Update を防ぐ。

  ## Options
  - `:exchange_execution_id` — live の取引所 execution id（string）
  - `:filled_at` — 取引所時刻優先。未指定時は `DateTime.utc_now/0`
  - `:order_id` — Order FK。未指定時は `order.id`
  - `:fee` — 手数料（`Decimal`、0 以上。省略時 0。paper は価格に含む）
  - `:fee_currency` — fee の通貨。省略時は `Product.fee_currency/1`

  建玉数量は inventory（買い+base fee なら `size − fee`）。Fill 行の `size` は
  約定数量のまま残す。反対売買・ドテンの減算も inventory 基準（`held`）で揃える。
  """
  @spec apply_fill(Order.t(), Decimal.t(), keyword()) ::
          {:ok, list(), %{realized_pnl: Decimal.t()}} | {:error, atom(), map()}
  def apply_fill(%Order{} = order, %Decimal{} = fill_price, opts \\ []) do
    trade_mode = order.trade_mode
    product_code = order.product_code
    side = order.side
    size = order.size

    with {:ok, fee} <- normalize_fee(opts),
         {:ok, fee_currency} <- resolve_fee_currency(product_code, opts),
         {:ok, fee_quote} <- fee_to_quote(fee, fee_currency, product_code, fill_price),
         {:ok, held} <- held_size(side, size, fee, fee_currency, product_code) do
      apply_fill_with_fee(
        order,
        fill_price,
        size,
        held,
        side,
        product_code,
        trade_mode,
        fee,
        fee_currency,
        fee_quote,
        opts
      )
    end
  end

  defp apply_fill_with_fee(
         order,
         fill_price,
         exec_size,
         held,
         side,
         product_code,
         trade_mode,
         fee,
         fee_currency,
         fee_quote,
         opts
       ) do
    case find_position(product_code, trade_mode) do
      {:ok, nil} ->
        case create_position(
               product_code,
               trade_mode,
               side,
               held,
               fill_price
             ) do
          {:ok, notifications} ->
            realized = net_realized(Decimal.new(0), fee_quote)

            with {:ok, fill_notifications} <-
                   insert_fill(
                     order,
                     fill_price,
                     exec_size,
                     realized,
                     fee,
                     fee_currency,
                     opts
                   ) do
              {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
            end

          {:race, %Position{} = position} ->
            merge_position(
              position,
              order,
              side,
              exec_size,
              held,
              fill_price,
              fee,
              fee_currency,
              fee_quote,
              opts
            )

          {:error, _, _} = error ->
            error
        end

      {:ok, %Position{} = position} ->
        merge_position(
          position,
          order,
          side,
          exec_size,
          held,
          fill_price,
          fee,
          fee_currency,
          fee_quote,
          opts
        )

      {:error, error} ->
        {:error, :persist_failed, %{error: error}}
    end
  end

  defp find_position(product_code, trade_mode) do
    Position
    |> Ash.Query.filter(product_code == ^product_code and trade_mode == ^trade_mode)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  defp create_position(product_code, trade_mode, side, size, fill_price) do
    case Position
         |> Ash.Changeset.for_create(:create, %{
           product_code: product_code,
           trade_mode: trade_mode,
           side: side,
           size: size,
           average_price: fill_price
         })
         |> Ash.create(return_notifications?: true) do
      {:ok, _, notifications} ->
        {:ok, notifications}

      {:error, error} ->
        case find_position(product_code, trade_mode) do
          {:ok, %Position{} = position} ->
            {:race, position}

          _ ->
            {:error, :persist_failed, %{error: error}}
        end
    end
  end

  # 建玉の増減は常に held（買い+base fee なら size−fee）。Fill.size は約定 exec_size のまま。
  # 反対売買の分岐も held 基準。exec_size で減らすと fee 分まで消し込みすぎる（過多決済）。
  defp merge_position(
         %Position{} = position,
         %Order{} = order,
         side,
         exec_size,
         held,
         fill_price,
         fee,
         fee_currency,
         fee_quote,
         opts
       ) do
    cond do
      position.side == side ->
        new_size = Decimal.add(position.size, held)

        new_avg =
          position.size
          |> Decimal.mult(position.average_price)
          |> Decimal.add(Decimal.mult(held, fill_price))
          |> Decimal.div(new_size)

        realized = net_realized(Decimal.new(0), fee_quote)

        with {:ok, notifications} <-
               update_position(position, %{size: new_size, average_price: new_avg}),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, exec_size, realized, fee, fee_currency, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      Decimal.compare(held, position.size) == :lt ->
        closed = held

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee_quote
          )

        new_size = Decimal.sub(position.size, held)

        with {:ok, notifications} <- update_position(position, %{size: new_size}),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, exec_size, realized, fee, fee_currency, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      Decimal.equal?(held, position.size) ->
        closed = position.size

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee_quote
          )

        with {:ok, notifications} <- destroy_position(position),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, exec_size, realized, fee, fee_currency, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      true ->
        closed = position.size

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee_quote
          )

        remainder = Decimal.sub(held, position.size)

        with {:ok, notifications} <-
               update_position(position, %{
                 side: side,
                 size: remainder,
                 average_price: fill_price
               }),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, exec_size, realized, fee, fee_currency, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end
    end
  end

  defp destroy_position(%Position{} = position) do
    case Ash.destroy(position, return_notifications?: true) do
      :ok -> {:ok, []}
      {:ok, notifications} when is_list(notifications) -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp update_position(%Position{} = position, attrs) do
    case position
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(return_notifications?: true) do
      {:ok, _, notifications} -> {:ok, notifications}
      {:error, error} -> {:error, :persist_failed, %{error: error}}
    end
  end

  defp realized_pnl(:buy, avg_price, fill_price, closed_size) do
    fill_price
    |> Decimal.sub(avg_price)
    |> Decimal.mult(closed_size)
  end

  defp realized_pnl(:sell, avg_price, fill_price, closed_size) do
    avg_price
    |> Decimal.sub(fill_price)
    |> Decimal.mult(closed_size)
  end

  defp net_realized(gross, fee_quote), do: Decimal.sub(gross, fee_quote)

  defp normalize_fee(opts) do
    case Keyword.get(opts, :fee, Decimal.new(0)) do
      %Decimal{} = fee ->
        if Decimal.compare(fee, 0) == :lt do
          {:error, :persist_failed, %{reason: :negative_fee}}
        else
          {:ok, fee}
        end

      _ ->
        {:error, :persist_failed, %{reason: :invalid_fee}}
    end
  end

  defp resolve_fee_currency(product_code, opts) do
    case Keyword.get(opts, :fee_currency) do
      ccy when is_binary(ccy) and ccy != "" ->
        {:ok, ccy}

      nil ->
        {:ok, Product.fee_currency(product_code)}

      _ ->
        {:error, :persist_failed, %{reason: :invalid_fee_currency}}
    end
  end

  # fee を quote 建へ mark（BTC_JPY なら JPY、ETH_BTC なら BTC）。DailyLoss / Equity は quote 建。
  defp fee_to_quote(fee, fee_currency, product_code, fill_price) do
    cond do
      Decimal.eq?(fee, 0) ->
        {:ok, Decimal.new(0)}

      fee_currency == Product.quote_currency(product_code) ->
        {:ok, fee}

      fee_currency == Product.base_currency(product_code) ->
        {:ok, Decimal.mult(fee, fill_price)}

      true ->
        {:error, :persist_failed,
         %{reason: :unsupported_fee_currency, fee_currency: fee_currency}}
    end
  end

  # 建玉に載せる数量。spot の base fee 買いでは受取 net（size − fee）。
  defp held_size(:buy, size, fee, fee_currency, product_code) do
    if fee_currency == Product.base_currency(product_code) do
      held = Decimal.sub(size, fee)

      if Decimal.compare(held, 0) == :gt do
        {:ok, held}
      else
        {:error, :persist_failed, %{reason: :fee_exceeds_size}}
      end
    else
      {:ok, size}
    end
  end

  defp held_size(:sell, size, _fee, _fee_currency, _product_code), do: {:ok, size}

  defp insert_fill(%Order{} = order, fill_price, size, realized_pnl, fee, fee_currency, opts) do
    filled_at =
      case Keyword.get(opts, :filled_at) do
        %DateTime{} = dt -> DateTime.truncate(dt, :microsecond)
        _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
      end

    attrs = %{
      internal_order_id: order.internal_order_id,
      order_id: Keyword.get(opts, :order_id, order.id),
      exchange_execution_id: Keyword.get(opts, :exchange_execution_id),
      product_code: order.product_code,
      side: order.side,
      size: size,
      price: fill_price,
      realized_pnl: realized_pnl,
      fee: fee,
      fee_currency: fee_currency,
      trade_mode: order.trade_mode,
      filled_at: filled_at
    }

    case Fill
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(return_notifications?: true) do
      {:ok, _, notifications} ->
        {:ok, notifications}

      {:error, error} ->
        if duplicate_execution_error?(error) do
          {:error, :duplicate_execution,
           %{
             exchange_execution_id: attrs.exchange_execution_id,
             trade_mode: order.trade_mode,
             error: error
           }}
        else
          {:error, :persist_failed, %{error: error}}
        end
    end
  end

  defp duplicate_execution_error?(error) do
    error
    |> error_leaves()
    |> Enum.any?(&identity_collision?/1)
  end

  defp identity_collision?(%{identity: :unique_trade_mode_exchange_execution_id}), do: true

  defp identity_collision?(%{constraint: constraint}) when is_binary(constraint) do
    constraint_name_collision?(constraint)
  end

  # Ecto/Ash が map 形や Postgrex.Error で postgres 情報だけ載せる場合
  defp identity_collision?(%{postgres: %{constraint: constraint}}) when is_binary(constraint) do
    constraint_name_collision?(constraint)
  end

  # 最終手段: メッセージ文字列。identity / constraint パスで拾えない未知ラッパ向け。
  defp identity_collision?(other) do
    other
    |> Exception.message()
    |> constraint_name_collision?()
  rescue
    _ -> false
  end

  defp constraint_name_collision?(text) when is_binary(text) do
    String.contains?(text, "unique_trade_mode_exchange_execution_id") or
      String.contains?(text, "fills_unique_trade_mode_exchange_execution_id")
  end

  defp error_leaves(%{errors: errors}) when is_list(errors) do
    Enum.flat_map(errors, &error_leaves/1)
  end

  defp error_leaves(other), do: [other]
end
