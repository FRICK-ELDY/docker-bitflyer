defmodule Bitflyer.Exchange.CredentialsTest do
  use ExUnit.Case, async: false

  alias Bitflyer.Exchange.Credentials

  setup do
    previous = Application.get_env(:bitflyer, :exchange_api)

    on_exit(fn ->
      if previous do
        Application.put_env(:bitflyer, :exchange_api, previous)
      else
        Application.delete_env(:bitflyer, :exchange_api)
      end
    end)

    :ok
  end

  test "present? is false when keys are blank" do
    Application.put_env(:bitflyer, :exchange_api, api_key: "", api_secret: "")

    refute Credentials.present?()
    assert Credentials.api_key() == ""
    assert Credentials.api_secret() == ""
  end

  test "present? is true when both key and secret are set" do
    Application.put_env(:bitflyer, :exchange_api,
      api_key: "test-key",
      api_secret: "test-secret"
    )

    assert Credentials.present?()
    assert Credentials.api_key() == "test-key"
    assert Credentials.api_secret() == "test-secret"
  end
end
