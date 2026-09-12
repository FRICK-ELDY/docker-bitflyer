defmodule Bitflyer.Exchange.Rest.Decode do
  @moduledoc """
  Private REST 応答の正規化。

  数値は strict（不正・欠損・NaN/Inf は `:invalid_number`）。
  execution の `commission` は必須・0 以上（欠落・負は `:invalid_number`）。
  識別子欠落・未知 side / status は snapshot/list 全体失敗
  （`:missing_identifier` / `:unknown_side` / `:unknown_status`）。
  `:skip` は明示 allowlist に載った無関係行のみ（現状は空。条件追加時はここに書く）。
  """

  alias Bitflyer.Exchange.Client

  @type structure_error :: :missing_identifier | :unknown_side | :unknown_status
  @type decode_error ::
          :invalid_number | :invalid_datetime | :invalid_structure | structure_error
  @type decode_result(t) :: {:ok, t} | :skip | {:error, decode_error}

  @payload_errors [
    :invalid_number,
    :invalid_datetime,
    :invalid_structure,
    :missing_identifier,
    :unknown_side,
    :unknown_status
  ]

  # 無関係行を落とす必要があるときだけ足す。private snapshot の識別子欠落は載せない。
  @allowlisted_skip_order_states MapSet.new([])

  @doc false
  @spec payload_error?(term()) :: boolean()
  def payload_error?(reason) when reason in @payload_errors, do: true
  def payload_error?(_), do: false

  @doc """
  数値を `Decimal` へ。不正・欠損・NaN/Inf は `:error`（0 に丸めない）。
  """
  @spec to_decimal(term()) :: {:ok, Decimal.t()} | :error
  def to_decimal(%Decimal{} = d) do
    if decimal_finite?(d), do: {:ok, d}, else: :error
  end

  def to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}

  def to_decimal(n) when is_float(n) do
    cond do
      # NaN
      n != n ->
        :error

      true ->
        try do
          bin = :erlang.float_to_binary(n, decimals: 10)
          lowered = String.downcase(bin)

          if String.contains?(lowered, "inf") or String.contains?(lowered, "nan") do
            :error
          else
            case Decimal.parse(bin) do
              {decimal, _} ->
                if decimal_finite?(decimal), do: {:ok, decimal}, else: :error

              :error ->
                :error
            end
          end
        rescue
          ArgumentError -> :error
        end
    end
  end

  def to_decimal(s) when is_binary(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        :error

      non_finite_string?(trimmed) ->
        :error

      true ->
        case Decimal.parse(trimmed) do
          {decimal, ""} ->
            if decimal_finite?(decimal), do: {:ok, decimal}, else: :error

          _ ->
            :error
        end
    end
  end

  def to_decimal(_), do: :error

  @doc false
  @spec side(term()) :: :buy | :sell | nil
  def side("BUY"), do: :buy
  def side("SELL"), do: :sell
  def side(:buy), do: :buy
  def side(:sell), do: :sell
  def side(_), do: nil

  @doc false
  @spec order_status(term()) :: Client.order_status() | nil
  def order_status("ACTIVE"), do: :active
  def order_status("COMPLETED"), do: :completed
  def order_status("CANCELED"), do: :canceled
  def order_status("EXPIRED"), do: :expired
  def order_status("REJECTED"), do: :rejected
  def order_status(:active), do: :active
  def order_status(:completed), do: :completed
  def order_status(:canceled), do: :canceled
  def order_status(:expired), do: :expired
  def order_status(:rejected), do: :rejected
  def order_status(_), do: nil

  @doc false
  @spec balance(map()) :: decode_result(Client.balance())
  def balance(%{} = row) do
    currency = Map.get(row, "currency_code") || Map.get(row, :currency_code)

    with {:ok, currency} <- require_binary(currency),
         {:ok, amount} <- require_decimal(Map.get(row, "amount") || Map.get(row, :amount)),
         {:ok, available} <-
           require_decimal(Map.get(row, "available") || Map.get(row, :available)) do
      {:ok, %{currency: currency, amount: amount, available: available}}
    end
  end

  def balance(_), do: {:error, :missing_identifier}

  @doc false
  @spec position(map()) :: decode_result(Client.position())
  def position(%{} = row) do
    product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
    raw_side = Map.get(row, "side") || Map.get(row, :side)

    with {:ok, product_code} <- require_binary(product_code),
         {:ok, side} <- require_side(raw_side),
         {:ok, size} <- require_decimal(Map.get(row, "size") || Map.get(row, :size)),
         {:ok, average_price} <-
           require_decimal(Map.get(row, "price") || Map.get(row, :price)) do
      {:ok, %{product_code: product_code, side: side, size: size, average_price: average_price}}
    end
  end

  def position(_), do: {:error, :missing_identifier}

  @doc false
  @spec open_order(map()) :: decode_result(Client.open_order())
  def open_order(%{} = row) do
    case maybe_skip_order_row(row) do
      :skip ->
        :skip

      :cont ->
        exchange_order_id =
          Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

        product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
        raw_side = Map.get(row, "side") || Map.get(row, :side)

        with {:ok, exchange_order_id} <- require_binary(exchange_order_id),
             {:ok, product_code} <- require_binary(product_code),
             {:ok, side} <- require_side(raw_side),
             {:ok, size} <- require_decimal(Map.get(row, "size") || Map.get(row, :size)),
             {:ok, filled_size} <-
               require_decimal(Map.get(row, "executed_size") || Map.get(row, :executed_size)) do
          {:ok,
           %{
             exchange_order_id: exchange_order_id,
             product_code: product_code,
             side: side,
             size: size,
             filled_size: filled_size
           }}
        end
    end
  end

  def open_order(_), do: {:error, :missing_identifier}

  @doc false
  @spec order_info(map()) :: decode_result(Client.order_info())
  def order_info(%{} = row) do
    case maybe_skip_order_row(row) do
      :skip ->
        :skip

      :cont ->
        exchange_order_id =
          Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

        product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
        raw_side = Map.get(row, "side") || Map.get(row, :side)
        avg = Map.get(row, "average_price") || Map.get(row, :average_price)

        with {:ok, exchange_order_id} <- require_binary(exchange_order_id),
             {:ok, product_code} <- require_binary(product_code),
             {:ok, side} <- require_side(raw_side),
             {:ok, size} <- require_decimal(Map.get(row, "size") || Map.get(row, :size)),
             {:ok, filled_size} <-
               require_decimal(Map.get(row, "executed_size") || Map.get(row, :executed_size)),
             {:ok, average_price} <- optional_average_price(avg),
             {:ok, status} <-
               require_order_status(
                 Map.get(row, "child_order_state") || Map.get(row, :child_order_state)
               ) do
          {:ok,
           %{
             exchange_order_id: exchange_order_id,
             product_code: product_code,
             side: side,
             size: size,
             filled_size: filled_size,
             average_price: average_price,
             status: status
           }}
        end
    end
  end

  def order_info(_), do: {:error, :missing_identifier}

  @doc false
  @spec execution(map(), String.t() | nil) :: decode_result(Client.execution())
  def execution(row, default_product \\ nil)

  def execution(%{} = row, default_product) do
    exchange_order_id =
      Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

    raw_side = Map.get(row, "side") || Map.get(row, :side)
    id = Map.get(row, "id") || Map.get(row, :id)

    product_code =
      Map.get(row, "product_code") || Map.get(row, :product_code) || default_product

    raw_executed_at = Map.get(row, "exec_date") || Map.get(row, :exec_date)

    with {:ok, exchange_order_id} <- require_binary(exchange_order_id),
         {:ok, side} <- require_side(raw_side),
         {:ok, id} <- require_execution_id(id),
         {:ok, product_code} <- require_binary(product_code),
         {:ok, price} <- require_decimal(Map.get(row, "price") || Map.get(row, :price)),
         {:ok, size} <- require_decimal(Map.get(row, "size") || Map.get(row, :size)),
         {:ok, commission} <-
           require_nonneg_decimal(Map.get(row, "commission") || Map.get(row, :commission)),
         {:ok, executed_at} <- optional_execution_datetime(raw_executed_at) do
      {:ok,
       %{
         id: id,
         exchange_order_id: exchange_order_id,
         product_code: product_code,
         side: side,
         price: price,
         size: size,
         commission: commission,
         executed_at: executed_at
       }}
    end
  end

  def execution(_, _), do: {:error, :missing_identifier}

  @doc false
  @spec child_order(map()) :: decode_result(Client.child_order())
  def child_order(%{} = row) do
    case order_info(row) do
      {:ok, info} ->
        with {:ok, price} <- optional_price(Map.get(row, "price") || Map.get(row, :price)),
             {:ok, ordered_at} <-
               child_order_datetime(
                 Map.get(row, "child_order_date") || Map.get(row, :child_order_date)
               ) do
          {:ok,
           Map.merge(info, %{
             price: price,
             order_type:
               child_order_type(
                 Map.get(row, "child_order_type") || Map.get(row, :child_order_type)
               ),
             ordered_at: ordered_at
           })}
        end

      other ->
        other
    end
  end

  def child_order(_), do: {:error, :missing_identifier}

  @doc false
  @spec map_error(integer(), term()) :: atom()
  def map_error(status, body) when status in 400..499 do
    message =
      cond do
        is_map(body) ->
          Map.get(body, "error_message") || Map.get(body, :error_message) || inspect(body)

        is_binary(body) ->
          body

        true ->
          inspect(body)
      end

    lowered = String.downcase(to_string(message))

    cond do
      status in [401, 403] -> :auth_failed
      status == 429 -> :rate_limited
      String.contains?(lowered, "insufficient") -> :insufficient_funds
      String.contains?(lowered, "invalid") -> :invalid_order
      true -> :rejected_by_exchange
    end
  end

  def map_error(_status, _body), do: :rejected_by_exchange

  @doc false
  @spec transport_error(term()) :: atom()
  def transport_error(%Req.TransportError{reason: reason}), do: classify_transport(reason)
  def transport_error({:timeout, _}), do: :timeout
  def transport_error(:timeout), do: :timeout
  def transport_error(:closed), do: :closed
  def transport_error(:econnrefused), do: :disconnected
  def transport_error(:nxdomain), do: :disconnected
  def transport_error(reason) when is_atom(reason), do: classify_transport(reason)
  def transport_error(_), do: :disconnected

  defp maybe_skip_order_row(row) do
    state = Map.get(row, "child_order_state") || Map.get(row, :child_order_state)

    if is_binary(state) and MapSet.member?(@allowlisted_skip_order_states, state) do
      :skip
    else
      :cont
    end
  end

  defp require_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_), do: {:error, :missing_identifier}

  defp require_execution_id(id) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp require_execution_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp require_execution_id(_), do: {:error, :missing_identifier}

  # exec_date 欠落は許容（filled_at は呼び出し側で utc_now フォールバック）。不正文字列は拒否。
  defp optional_execution_datetime(nil), do: {:ok, nil}
  defp optional_execution_datetime(""), do: {:ok, nil}
  defp optional_execution_datetime(value), do: child_order_datetime(value)

  defp require_side(raw) do
    case side(raw) do
      side when side in [:buy, :sell] ->
        {:ok, side}

      nil ->
        if blank?(raw) do
          {:error, :missing_identifier}
        else
          {:error, :unknown_side}
        end
    end
  end

  defp require_order_status(raw) do
    case order_status(raw) do
      status when status in [:active, :completed, :canceled, :expired, :rejected] ->
        {:ok, status}

      nil ->
        if blank?(raw) do
          {:error, :missing_identifier}
        else
          {:error, :unknown_status}
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp require_decimal(term) do
    case to_decimal(term) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, :invalid_number}
    end
  end

  # live 手数料。欠落・負は fail-closed（0 はプロモ無料として許す）。
  defp require_nonneg_decimal(term) do
    case require_decimal(term) do
      {:ok, decimal} ->
        if Decimal.compare(decimal, 0) == :lt do
          {:error, :invalid_number}
        else
          {:ok, decimal}
        end

      {:error, _} = error ->
        error
    end
  end

  # 未約定などで average_price が 0 / 欠落は許容（"0" / "0.0" / "0.00" 含む）。不正は拒否。
  defp optional_average_price(avg) when avg in [nil, ""], do: {:ok, nil}

  defp optional_average_price(avg) do
    case to_decimal(avg) do
      {:ok, decimal} ->
        if Decimal.compare(decimal, 0) == :eq do
          {:ok, nil}
        else
          {:ok, decimal}
        end

      :error ->
        {:error, :invalid_number}
    end
  end

  defp optional_price(nil), do: {:ok, nil}
  defp optional_price(""), do: {:ok, nil}

  defp optional_price(price) do
    case to_decimal(price) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, :invalid_number}
    end
  end

  defp child_order_type("LIMIT"), do: :limit
  defp child_order_type("MARKET"), do: :market
  defp child_order_type(:limit), do: :limit
  defp child_order_type(:market), do: :market
  defp child_order_type(_), do: nil

  # bitFlyer Private API の日時はオフセット無しの JST 壁時計が契約（例: "2015-07-07T08:45:53"）。
  # オフセット付き ISO8601 が来た場合はそのまま解釈する（誤って -9h しない）。
  # 欠落・不正は fail-closed（{:error, :invalid_datetime}）。nil に丸めない。
  @jst_offset_seconds 9 * 60 * 60

  defp child_order_datetime(nil), do: {:error, :invalid_datetime}
  defp child_order_datetime(""), do: {:error, :invalid_datetime}

  defp child_order_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            naive
            |> NaiveDateTime.add(-@jst_offset_seconds, :second)
            |> DateTime.from_naive("Etc/UTC")

          {:error, _} ->
            {:error, :invalid_datetime}
        end

      {:error, _} ->
        {:error, :invalid_datetime}
    end
  end

  defp child_order_datetime(%DateTime{} = dt), do: {:ok, dt}
  defp child_order_datetime(_), do: {:error, :invalid_datetime}

  defp decimal_finite?(%Decimal{} = d) do
    not (Decimal.nan?(d) or Decimal.inf?(d))
  end

  defp non_finite_string?(s) do
    String.downcase(s) in [
      "nan",
      "inf",
      "+inf",
      "-inf",
      "infinity",
      "+infinity",
      "-infinity"
    ]
  end

  defp classify_transport(:timeout), do: :timeout
  defp classify_transport(:closed), do: :closed
  defp classify_transport(:econnrefused), do: :disconnected
  defp classify_transport(:nxdomain), do: :disconnected
  defp classify_transport(_), do: :disconnected
end
