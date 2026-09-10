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

  test "incomplete identity rows are skipped" do
    assert :skip = Decode.balance(%{"amount" => "1", "available" => "1"})
    assert :skip = Decode.position(%{"product_code" => "FX_BTC_JPY", "size" => "0.01"})
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
end
