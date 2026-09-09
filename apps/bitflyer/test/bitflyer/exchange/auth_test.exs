defmodule Bitflyer.Exchange.AuthTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Exchange.Auth

  # bitFlyer 公式サンプル相当のベクトル（secret / timestamp / method / path / body）
  @secret "secret"
  @timestamp "1.234"
  @method "POST"
  @path "/v1/me/sendchildorder"
  @body ~s({"product_code":"FX_BTC_JPY","child_order_type":"MARKET","side":"BUY","size":"0.01"})

  test "sign is HMAC-SHA256 hex of timestamp+method+path+body" do
    expected =
      :hmac
      |> :crypto.mac(:sha256, @secret, @timestamp <> @method <> @path <> @body)
      |> Base.encode16(case: :lower)

    assert Auth.sign(@secret, @timestamp, @method, @path, @body) == expected
  end

  test "sign for GET has empty body" do
    path = "/v1/me/getbalance"

    expected =
      :hmac
      |> :crypto.mac(:sha256, @secret, @timestamp <> "GET" <> path)
      |> Base.encode16(case: :lower)

    assert Auth.sign(@secret, @timestamp, "GET", path, "") == expected
  end

  test "headers include ACCESS-* and never return the secret" do
    headers = Auth.headers("key", @secret, @timestamp, @method, @path, @body)
    values = Enum.map(headers, fn {_k, v} -> v end)

    assert {"ACCESS-KEY", "key"} in headers
    assert {"ACCESS-TIMESTAMP", @timestamp} in headers
    assert {"Content-Type", "application/json"} in headers
    refute @secret in values
    assert Enum.any?(headers, fn {k, v} -> k == "ACCESS-SIGN" and byte_size(v) == 64 end)
  end
end
