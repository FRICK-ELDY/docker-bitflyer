defmodule Bitflyer.Exchange.Rest.DecodeTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Exchange.Rest.Decode

  test "to_decimal accepts valid numbers and rejects invalid" do
    assert {:ok, d} = Decode.to_decimal("1.5")
    assert Decimal.eq?(d, Decimal.new("1.5"))

    assert {:ok, _} = Decode.to_decimal(0)
    assert {:ok, _} = Decode.to_decimal(1.25)

    assert :error = Decode.to_decimal(nil)
    assert :error = Decode.to_decimal("")
    assert :error = Decode.to_decimal("abc")
    assert :error = Decode.to_decimal("NaN")
    assert :error = Decode.to_decimal("Infinity")
    assert :error = Decode.to_decimal(:not_a_number)
    assert :error = Decode.to_decimal(:nan)
  end

  test "to_decimal rejects float NaN and infinity" do
    nan = <<0x7FF8000000000000::float>>
    pos_inf = <<0x7FF0000000000000::float>>
    neg_inf = <<0xFFF0000000000000::float>>

    assert :error = Decode.to_decimal(nan)
    assert :error = Decode.to_decimal(pos_inf)
    assert :error = Decode.to_decimal(neg_inf)
  end

  test "balance fails closed on null/NaN amount instead of zeroing" do
    assert {:error, :invalid_number} =
             Decode.balance(%{
               "currency_code" => "JPY",
               "amount" => nil,
               "available" => "100"
             })

    assert {:error, :invalid_number} =
             Decode.balance(%{
               "currency_code" => "JPY",
               "amount" => "NaN",
               "available" => "100"
             })

    assert {:ok, %{amount: amount}} =
             Decode.balance(%{
               "currency_code" => "JPY",
               "amount" => "0",
               "available" => "0"
             })

    assert Decimal.eq?(amount, Decimal.new("0"))
  end

  test "position fails closed on invalid size" do
    assert {:error, :invalid_number} =
             Decode.position(%{
               "product_code" => "FX_BTC_JPY",
               "side" => "BUY",
               "size" => "not-a-number",
               "price" => "5000000"
             })
  end

  test "incomplete identity and unknown side fail closed" do
    assert {:error, :missing_identifier} =
             Decode.balance(%{"amount" => "1", "available" => "1"})

    assert {:error, :missing_identifier} =
             Decode.position(%{"product_code" => "FX_BTC_JPY", "size" => "0.01"})

    assert {:error, :unknown_side} =
             Decode.position(%{
               "product_code" => "FX_BTC_JPY",
               "side" => "HOLD",
               "size" => "0.01",
               "price" => "5000000"
             })

    assert {:error, :unknown_side} =
             Decode.open_order(%{
               "child_order_acceptance_id" => "JRF-1",
               "product_code" => "FX_BTC_JPY",
               "side" => "FLAT",
               "size" => "0.01",
               "executed_size" => "0"
             })

    assert {:error, :missing_identifier} =
             Decode.open_order(%{
               "product_code" => "FX_BTC_JPY",
               "side" => "BUY",
               "size" => "0.01",
               "executed_size" => "0"
             })

    assert {:error, :unknown_status} =
             Decode.order_info(%{
               "child_order_acceptance_id" => "JRF-1",
               "product_code" => "FX_BTC_JPY",
               "side" => "BUY",
               "size" => "0.01",
               "executed_size" => "0",
               "child_order_state" => "PENDING"
             })

    assert {:error, :missing_identifier} =
             Decode.execution(%{
               "id" => 1,
               "child_order_acceptance_id" => "JRF-1",
               "side" => "BUY",
               "price" => "100",
               "size" => "0.01"
             })

    assert {:ok, %{product_code: "BTC_JPY"}} =
             Decode.execution(
               %{
                 "id" => 1,
                 "child_order_acceptance_id" => "JRF-1",
                 "side" => "BUY",
                 "price" => "100",
                 "size" => "0.01"
               },
               "BTC_JPY"
             )
  end

  test "execution parses exec_date and rejects invalid datetime" do
    base = %{
      "id" => 42,
      "child_order_acceptance_id" => "JRF-1",
      "side" => "BUY",
      "price" => "100",
      "size" => "0.01"
    }

    assert {:ok, %{id: "42", executed_at: %DateTime{}}} =
             Decode.execution(Map.put(base, "exec_date", "2026-01-15T01:02:03.456"), "BTC_JPY")

    assert {:ok, %{executed_at: nil}} =
             Decode.execution(base, "BTC_JPY")

    assert {:error, :invalid_datetime} =
             Decode.execution(Map.put(base, "exec_date", "not-a-date"), "BTC_JPY")
  end

  test "order_info accepts atom child_order_state like side atoms" do
    base = %{
      child_order_acceptance_id: "JRF-1",
      product_code: "BTC_JPY",
      side: :buy,
      size: "0.01",
      executed_size: "0",
      child_order_state: :active
    }

    assert {:ok, %{status: :active, side: :buy}} = Decode.order_info(base)
  end

  test "order_info treats 0.0 and 0.00 average_price as absent" do
    base = %{
      "child_order_acceptance_id" => "JRF-1",
      "product_code" => "FX_BTC_JPY",
      "side" => "BUY",
      "size" => "0.01",
      "executed_size" => "0",
      "child_order_state" => "ACTIVE"
    }

    assert {:ok, %{average_price: nil}} = Decode.order_info(Map.put(base, "average_price", "0.0"))

    assert {:ok, %{average_price: nil}} =
             Decode.order_info(Map.put(base, "average_price", "0.00"))

    assert {:ok, %{average_price: nil}} = Decode.order_info(Map.put(base, "average_price", 0.0))
  end

  test "child_order fails closed on missing or invalid child_order_date" do
    base = %{
      "child_order_acceptance_id" => "JRF-1",
      "product_code" => "FX_BTC_JPY",
      "side" => "BUY",
      "size" => "0.01",
      "executed_size" => "0",
      "child_order_state" => "ACTIVE",
      "price" => "5000000",
      "child_order_type" => "LIMIT"
    }

    assert {:error, :invalid_datetime} = Decode.child_order(base)
    assert {:error, :invalid_datetime} = Decode.child_order(Map.put(base, "child_order_date", ""))

    assert {:error, :invalid_datetime} =
             Decode.child_order(Map.put(base, "child_order_date", "not-a-date"))

    assert {:ok, %{ordered_at: %DateTime{} = dt}} =
             Decode.child_order(Map.put(base, "child_order_date", "2015-07-07T08:45:53"))

    assert DateTime.compare(dt, ~U[2015-07-06 23:45:53Z]) == :eq

    assert {:ok, %{ordered_at: %DateTime{} = offset_dt}} =
             Decode.child_order(Map.put(base, "child_order_date", "2015-07-07T08:45:53+09:00"))

    assert DateTime.compare(offset_dt, ~U[2015-07-06 23:45:53Z]) == :eq

    assert {:ok, %{ordered_at: %DateTime{} = z_dt}} =
             Decode.child_order(Map.put(base, "child_order_date", "2015-07-06T23:45:53Z"))

    assert DateTime.compare(z_dt, ~U[2015-07-06 23:45:53Z]) == :eq
  end

  test "map_error treats 401/403 as auth_failed and 429 as rate_limited" do
    assert Decode.map_error(401, %{"status_code" => 401, "error_message" => "Unauthorized"}) ==
             :auth_failed

    assert Decode.map_error(403, %{"error_message" => "Forbidden"}) == :auth_failed

    assert Decode.map_error(429, %{"error_message" => "Too Many Requests"}) == :rate_limited

    assert Decode.map_error(400, %{"error_message" => "Order rejected"}) == :rejected_by_exchange

    assert Decode.map_error(400, %{"error_message" => "Insufficient funds"}) ==
             :insufficient_funds
  end
end
