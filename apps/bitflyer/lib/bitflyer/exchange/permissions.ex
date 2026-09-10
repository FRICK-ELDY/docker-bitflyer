defmodule Bitflyer.Exchange.Permissions do
  @moduledoc """
  API キー権限リストの安全検査。

  `getpermissions` の応答に出金・送付系パスが含まれていれば fail-closed。
  空リストも fail-closed（取引権限が無いキーを安全とみなさない）。
  参照系（`getwithdrawals` 等）は許可する。
  """

  @forbidden MapSet.new([
               "/v1/me/withdraw",
               "/v1/me/sendcoin"
             ])

  @doc """
  権限リストに出金・送付が無く、かつ空でなければ `:ok`。
  """
  @spec assert_safe([String.t()]) :: :ok | {:error, :unsafe_api_permissions, map()}
  def assert_safe([]), do: {:error, :unsafe_api_permissions, %{permission: :empty}}

  def assert_safe(permissions) when is_list(permissions) do
    case Enum.find(permissions, &forbidden?/1) do
      nil ->
        :ok

      path when is_binary(path) ->
        {:error, :unsafe_api_permissions, %{permission: path}}
    end
  end

  def assert_safe(_), do: {:error, :unsafe_api_permissions, %{permission: :invalid_list}}

  defp forbidden?(path) when is_binary(path), do: MapSet.member?(@forbidden, path)
  defp forbidden?(_), do: false
end
