defmodule Bitflyer.Exchange.PermissionsTest do
  use ExUnit.Case, async: true

  alias Bitflyer.Exchange.Permissions

  test "assert_safe accepts trading-only permissions" do
    assert :ok =
             Permissions.assert_safe([
               "/v1/me/getpermissions",
               "/v1/me/getbalance",
               "/v1/me/sendchildorder",
               "/v1/me/getwithdrawals"
             ])
  end

  test "assert_safe rejects empty permission list" do
    assert {:error, :unsafe_api_permissions, %{permission: :empty}} =
             Permissions.assert_safe([])
  end

  test "assert_safe rejects withdraw permission" do
    assert {:error, :unsafe_api_permissions, %{permission: "/v1/me/withdraw"}} =
             Permissions.assert_safe(["/v1/me/getbalance", "/v1/me/withdraw"])
  end

  test "assert_safe rejects sendcoin permission" do
    assert {:error, :unsafe_api_permissions, %{permission: "/v1/me/sendcoin"}} =
             Permissions.assert_safe(["/v1/me/sendcoin"])
  end
end
