defmodule Bitflyer.Exchange.Rest.Decode do
  @moduledoc false

  alias Bitflyer.Exchange.Client

  @doc false
  @spec to_decimal(term()) :: Decimal.t()
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)

  def to_decimal(n) when is_float(n) do
    n |> :erlang.float_to_binary(decimals: 10) |> Decimal.new()
  end

  def to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      _ -> Decimal.new("0")
    end
  end

  def to_decimal(_), do: Decimal.new("0")

  @doc false
  @spec side(term()) :: :buy | :sell | nil
  def side("BUY"), do: :buy
  def side("SELL"), do: :sell
  def side(:buy), do: :buy
  def side(:sell), do: :sell
  def side(_), do: nil

  @doc false
  @spec order_status(term()) :: Client.order_status()
  def order_status("ACTIVE"), do: :active
  def order_status("COMPLETED"), do: :completed
  def order_status("CANCELED"), do: :canceled
  def order_status("EXPIRED"), do: :expired
  def order_status("REJECTED"), do: :rejected
  def order_status(_), do: :unknown

  @doc false
  @spec balance(map()) :: Client.balance() | nil
  def balance(%{} = row) do
    currency = Map.get(row, "currency_code") || Map.get(row, :currency_code)

    if is_binary(currency) and currency != "" do
      %{
        currency: currency,
        amount: to_decimal(Map.get(row, "amount") || Map.get(row, :amount)),
        available: to_decimal(Map.get(row, "available") || Map.get(row, :available))
      }
    else
      nil
    end
  end

  @doc false
  @spec position(map()) :: Client.position() | nil
  def position(%{} = row) do
    product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
    side = side(Map.get(row, "side") || Map.get(row, :side))

    if is_binary(product_code) and side do
      %{
        product_code: product_code,
        side: side,
        size: to_decimal(Map.get(row, "size") || Map.get(row, :size)),
        average_price: to_decimal(Map.get(row, "price") || Map.get(row, :price))
      }
    else
      nil
    end
  end

  @doc false
  @spec open_order(map()) :: Client.open_order() | nil
  def open_order(%{} = row) do
    exchange_order_id =
      Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

    product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
    side = side(Map.get(row, "side") || Map.get(row, :side))

    if is_binary(exchange_order_id) and is_binary(product_code) and side do
      %{
        exchange_order_id: exchange_order_id,
        product_code: product_code,
        side: side,
        size: to_decimal(Map.get(row, "size") || Map.get(row, :size)),
        filled_size: to_decimal(Map.get(row, "executed_size") || Map.get(row, :executed_size))
      }
    else
      nil
    end
  end

  @doc false
  @spec order_info(map()) :: Client.order_info() | nil
  def order_info(%{} = row) do
    exchange_order_id =
      Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

    product_code = Map.get(row, "product_code") || Map.get(row, :product_code)
    side = side(Map.get(row, "side") || Map.get(row, :side))

    if is_binary(exchange_order_id) and is_binary(product_code) and side do
      avg = Map.get(row, "average_price") || Map.get(row, :average_price)

      %{
        exchange_order_id: exchange_order_id,
        product_code: product_code,
        side: side,
        size: to_decimal(Map.get(row, "size") || Map.get(row, :size)),
        filled_size: to_decimal(Map.get(row, "executed_size") || Map.get(row, :executed_size)),
        average_price: if(avg in [nil, 0, 0.0, "0"], do: nil, else: to_decimal(avg)),
        status:
          order_status(Map.get(row, "child_order_state") || Map.get(row, :child_order_state))
      }
    else
      nil
    end
  end

  @doc false
  @spec execution(map(), String.t() | nil) :: Client.execution() | nil
  def execution(%{} = row, default_product \\ nil) do
    exchange_order_id =
      Map.get(row, "child_order_acceptance_id") || Map.get(row, :child_order_acceptance_id)

    side = side(Map.get(row, "side") || Map.get(row, :side))
    id = Map.get(row, "id") || Map.get(row, :id)

    if exchange_order_id && side && id do
      %{
        id: id,
        exchange_order_id: exchange_order_id,
        product_code:
          Map.get(row, "product_code") || Map.get(row, :product_code) || default_product,
        side: side,
        price: to_decimal(Map.get(row, "price") || Map.get(row, :price)),
        size: to_decimal(Map.get(row, "size") || Map.get(row, :size)),
        executed_at: Map.get(row, "exec_date") || Map.get(row, :exec_date)
      }
    else
      nil
    end
  end

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
      String.contains?(lowered, "insufficient") -> :insufficient_funds
      String.contains?(lowered, "invalid") -> :invalid_order
      status == 401 or status == 403 -> :rejected_by_exchange
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

  defp classify_transport(:timeout), do: :timeout
  defp classify_transport(:closed), do: :closed
  defp classify_transport(:econnrefused), do: :disconnected
  defp classify_transport(:nxdomain), do: :disconnected
  defp classify_transport(_), do: :disconnected
end
