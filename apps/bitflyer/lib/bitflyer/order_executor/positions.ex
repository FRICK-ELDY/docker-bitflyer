defmodule Bitflyer.OrderExecutor.Positions do
  @moduledoc false

  require Ash.Query

  alias Bitflyer.Trading.{Fill, Order, Position}

  @doc """
  約定を建玉へ反映し、Fill 行を同一トランザクション内に残す。

  戻り値の第 3 要素はコミット後に `Risk.DailyLoss.record_realized/2` へ渡す。
  既存建玉は `FOR UPDATE` でロックし、Lost Update を防ぐ。

  ## Options
  - `:exchange_execution_id` — live の取引所 execution id（string）
  - `:filled_at` — 取引所時刻優先。未指定時は `DateTime.utc_now/0`
  - `:order_id` — Order FK。未指定時は `order.id`
  - `:fee` — quote 通貨の手数料（`Decimal`、0 以上。省略時 0。paper は価格に含む）
  """
  @spec apply_fill(Order.t(), Decimal.t(), keyword()) ::
          {:ok, list(), %{realized_pnl: Decimal.t()}} | {:error, atom(), map()}
  def apply_fill(%Order{} = order, %Decimal{} = fill_price, opts \\ []) do
    trade_mode = order.trade_mode
    product_code = order.product_code
    side = order.side
    size = order.size

    with {:ok, fee} <- normalize_fee(opts) do
      apply_fill_with_fee(order, fill_price, size, side, product_code, trade_mode, fee, opts)
    end
  end

  defp apply_fill_with_fee(order, fill_price, size, side, product_code, trade_mode, fee, opts) do
    case find_position(product_code, trade_mode) do
      {:ok, nil} ->
        case create_position(product_code, trade_mode, side, size, fill_price) do
          {:ok, notifications} ->
            with {:ok, fill_notifications} <-
                   insert_fill(
                     order,
                     fill_price,
                     size,
                     net_realized(Decimal.new(0), fee),
                     fee,
                     opts
                   ) do
              {:ok, notifications ++ fill_notifications,
               %{realized_pnl: net_realized(Decimal.new(0), fee)}}
            end

          {:race, %Position{} = position} ->
            merge_position(position, order, side, size, fill_price, fee, opts)

          {:error, _, _} = error ->
            error
        end

      {:ok, %Position{} = position} ->
        merge_position(position, order, side, size, fill_price, fee, opts)

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

  defp merge_position(%Position{} = position, %Order{} = order, side, size, fill_price, fee, opts) do
    cond do
      position.side == side ->
        new_size = Decimal.add(position.size, size)

        new_avg =
          position.size
          |> Decimal.mult(position.average_price)
          |> Decimal.add(Decimal.mult(size, fill_price))
          |> Decimal.div(new_size)

        with {:ok, notifications} <-
               update_position(position, %{size: new_size, average_price: new_avg}),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, size, net_realized(Decimal.new(0), fee), fee, opts) do
          {:ok, notifications ++ fill_notifications,
           %{realized_pnl: net_realized(Decimal.new(0), fee)}}
        end

      Decimal.compare(size, position.size) == :lt ->
        closed = size

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee
          )

        new_size = Decimal.sub(position.size, size)

        with {:ok, notifications} <- update_position(position, %{size: new_size}),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, size, realized, fee, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      Decimal.equal?(size, position.size) ->
        closed = position.size

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee
          )

        with {:ok, notifications} <- destroy_position(position),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, size, realized, fee, opts) do
          {:ok, notifications ++ fill_notifications, %{realized_pnl: realized}}
        end

      true ->
        closed = position.size

        realized =
          net_realized(
            realized_pnl(position.side, position.average_price, fill_price, closed),
            fee
          )

        remainder = Decimal.sub(size, position.size)

        with {:ok, notifications} <-
               update_position(position, %{
                 side: side,
                 size: remainder,
                 average_price: fill_price
               }),
             {:ok, fill_notifications} <-
               insert_fill(order, fill_price, size, realized, fee, opts) do
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

  defp net_realized(gross, fee), do: Decimal.sub(gross, fee)

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

  defp insert_fill(%Order{} = order, fill_price, size, realized_pnl, fee, opts) do
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
