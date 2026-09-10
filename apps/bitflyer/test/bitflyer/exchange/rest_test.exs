defmodule Bitflyer.Exchange.RestTest do
  use ExUnit.Case, async: false

  alias Bitflyer.Exchange.Rest

  @fixtures Path.expand("../../fixtures/exchange", __DIR__)

  defmodule FixtureHTTP do
    @moduledoc false

    def request(method, url, headers, body, _opts \\ []) do
      case Process.get(:rest_http_handler) do
        fun when is_function(fun, 4) -> fun.(method, url, headers, body)
        _ -> {:error, :no_handler}
      end
    end
  end

  setup do
    previous_api = Application.get_env(:bitflyer, :exchange_api)
    previous_rest = Application.get_env(:bitflyer, Rest)
    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData)

    Application.put_env(:bitflyer, :exchange_api,
      api_key: "test-key",
      api_secret: "test-secret"
    )

    Application.put_env(:bitflyer, Rest,
      base_url: "https://api.bitflyer.test",
      http_client: FixtureHTTP,
      receive_timeout: 1_000
    )

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.merge(previous_md || [], product_codes: ["FX_BTC_JPY"])
    )

    on_exit(fn ->
      Process.delete(:rest_http_handler)

      restore_env(:exchange_api, previous_api)
      restore_env(Rest, previous_rest)
      restore_env(Bitflyer.MarketData, previous_md)
    end)

    :ok
  end

  test "fetch_reconcile_snapshot maps fixture balances/positions/open_orders" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :get
      assert body == ""
      assert_signed_headers(headers)

      cond do
        String.contains?(url, "/v1/me/getbalance") ->
          {:ok, response(200, fixture("getbalance.json"))}

        String.contains?(url, "/v1/me/getpositions") ->
          assert String.contains?(url, "product_code=FX_BTC_JPY")
          {:ok, response(200, fixture("getpositions.json"))}

        String.contains?(url, "/v1/me/getchildorders") ->
          assert String.contains?(url, "child_order_state=ACTIVE")
          {:ok, response(200, fixture("getchildorders_active.json"))}

        true ->
          flunk("unexpected url: #{url}")
      end
    end)

    assert {:ok, snapshot} = Rest.fetch_reconcile_snapshot()

    assert [
             %{currency: "JPY", amount: jpy, available: jpy_avail},
             %{currency: "BTC", amount: btc, available: btc_avail}
           ] = snapshot.balances

    assert Decimal.eq?(jpy, Decimal.new("1024078"))
    assert Decimal.eq?(jpy_avail, Decimal.new("508000"))
    assert Decimal.eq?(btc, Decimal.new("10.24"))
    assert Decimal.eq?(btc_avail, Decimal.new("4.12"))

    assert [
             %{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: size,
               average_price: avg
             }
           ] = snapshot.positions

    assert Decimal.eq?(size, Decimal.new("0.01"))
    assert Decimal.eq?(avg, Decimal.new("36000"))

    assert [
             %{
               exchange_order_id: "JRF20150707-084552-031927",
               product_code: "FX_BTC_JPY",
               side: :buy,
               filled_size: filled
             }
           ] = snapshot.open_orders

    assert Decimal.eq?(filled, Decimal.new("0"))
  end

  test "place_order signs POST body and returns acceptance id" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :post
      assert String.ends_with?(url, "/v1/me/sendchildorder")
      assert_signed_headers(headers)

      decoded = Jason.decode!(body)
      assert decoded["product_code"] == "FX_BTC_JPY"
      assert decoded["child_order_type"] == "MARKET"
      assert decoded["side"] == "BUY"
      assert decoded["size"] == "0.01"

      # 署名対象 body と送信 body が同一であること
      assert {"ACCESS-SIGN", sign} = List.keyfind(headers, "ACCESS-SIGN", 0)
      assert is_binary(sign)

      {:ok, response(200, fixture("sendchildorder.json"))}
    end)

    assert {:ok, %{exchange_order_id: "JRF20150707-050237-639234"}} =
             Rest.place_order(%{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               internal_order_id: "int-1"
             })
  end

  test "cancel_order posts acceptance id" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :post
      assert String.ends_with?(url, "/v1/me/cancelchildorder")
      assert_signed_headers(headers)

      assert Jason.decode!(body) == %{
               "product_code" => "FX_BTC_JPY",
               "child_order_acceptance_id" => "JRF-1"
             }

      {:ok, response(200, "")}
    end)

    assert :ok =
             Rest.cancel_order(%{
               product_code: "FX_BTC_JPY",
               exchange_order_id: "JRF-1"
             })
  end

  test "fetch_order and fetch_executions decode fixtures" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :get
      assert body == ""
      assert_signed_headers(headers)

      cond do
        String.contains?(url, "/v1/me/getchildorders") ->
          {:ok, response(200, fixture("getchildorders_completed.json"))}

        String.contains?(url, "/v1/me/getexecutions") ->
          {:ok, response(200, fixture("getexecutions.json"))}

        true ->
          flunk("unexpected url: #{url}")
      end
    end)

    assert {:ok, info} =
             Rest.fetch_order(%{
               product_code: "FX_BTC_JPY",
               exchange_order_id: "JRF20150707-084552-031927"
             })

    assert info.status == :completed
    assert Decimal.eq?(info.filled_size, Decimal.new("0.1"))
    assert Decimal.eq?(info.average_price, Decimal.new("30100"))

    assert {:ok, [e1, e2]} =
             Rest.fetch_executions(%{
               product_code: "FX_BTC_JPY",
               exchange_order_id: "JRF20150707-060559-396699"
             })

    assert e1.exchange_order_id == "JRF20150707-060559-396699"
    assert Decimal.eq?(e1.price, Decimal.new("33470"))
    assert Decimal.eq?(e2.size, Decimal.new("0.01"))
  end

  test "4xx maps to definite rejection atoms" do
    Process.put(:rest_http_handler, fn _method, _url, _headers, _body ->
      {:ok, response(400, %{"error_message" => "Insufficient funds"})}
    end)

    assert {:error, :insufficient_funds} =
             Rest.place_order(%{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               internal_order_id: "int-2"
             })
  end

  test "timeout transport becomes :timeout" do
    Process.put(:rest_http_handler, fn _method, _url, _headers, _body ->
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, :timeout} =
             Rest.place_order(%{
               product_code: "FX_BTC_JPY",
               side: :buy,
               size: Decimal.new("0.01"),
               order_type: :market,
               internal_order_id: "int-3"
             })
  end

  test "missing credentials return :exchange_unavailable" do
    Application.put_env(:bitflyer, :exchange_api, api_key: "", api_secret: "")

    assert {:error, :exchange_unavailable} = Rest.fetch_reconcile_snapshot()
  end

  test "fetch_reconcile_snapshot fails on NaN balance instead of zeroing" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :get
      assert body == ""
      assert_signed_headers(headers)

      cond do
        String.contains?(url, "/v1/me/getbalance") ->
          {:ok,
           response(200, [
             %{
               "currency_code" => "JPY",
               "amount" => "NaN",
               "available" => "1000"
             }
           ])}

        true ->
          flunk("should fail before #{url}")
      end
    end)

    assert {:error, :invalid_number} = Rest.fetch_reconcile_snapshot()
  end

  test "fetch_reconcile_snapshot fails on null position size" do
    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :get
      assert body == ""
      assert_signed_headers(headers)

      cond do
        String.contains?(url, "/v1/me/getbalance") ->
          {:ok, response(200, fixture("getbalance.json"))}

        String.contains?(url, "/v1/me/getpositions") ->
          {:ok,
           response(200, [
             %{
               "product_code" => "FX_BTC_JPY",
               "side" => "BUY",
               "size" => nil,
               "price" => "5000000"
             }
           ])}

        true ->
          flunk("should fail before #{url}")
      end
    end)

    assert {:error, :invalid_number} = Rest.fetch_reconcile_snapshot()
  end

  test "Exchange facade can inject Rest instead of Unavailable" do
    previous = Application.get_env(:bitflyer, :exchange_client)
    Application.put_env(:bitflyer, :exchange_client, Rest)

    on_exit(fn -> restore_env(:exchange_client, previous) end)

    Process.put(:rest_http_handler, fn method, url, headers, body ->
      assert method == :get
      assert body == ""
      assert_signed_headers(headers)

      cond do
        String.contains?(url, "/v1/me/getbalance") ->
          {:ok, response(200, fixture("getbalance.json"))}

        String.contains?(url, "/v1/me/getpositions") ->
          {:ok, response(200, [])}

        String.contains?(url, "/v1/me/getchildorders") ->
          {:ok, response(200, [])}

        true ->
          flunk("unexpected url: #{url}")
      end
    end)

    assert {:ok, %{balances: balances}} = Bitflyer.Exchange.fetch_reconcile_snapshot()
    assert length(balances) == 2
  end

  defp fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp response(status, body) do
    %Req.Response{status: status, body: body}
  end

  defp assert_signed_headers(headers) do
    assert {"ACCESS-KEY", "test-key"} = List.keyfind(headers, "ACCESS-KEY", 0)
    assert {"ACCESS-TIMESTAMP", ts} = List.keyfind(headers, "ACCESS-TIMESTAMP", 0)
    assert {"ACCESS-SIGN", sign} = List.keyfind(headers, "ACCESS-SIGN", 0)
    assert is_binary(ts) and ts != ""
    assert byte_size(sign) == 64
    refute Enum.any?(headers, fn {_k, v} -> v == "test-secret" end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:bitflyer, key)
  defp restore_env(key, value), do: Application.put_env(:bitflyer, key, value)
end
