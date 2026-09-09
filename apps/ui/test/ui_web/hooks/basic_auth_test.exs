defmodule UiWeb.Hooks.BasicAuthTest do
  use ExUnit.Case, async: true

  alias UiWeb.Hooks.BasicAuth

  test "on_mount continues when ui_basic_ok is true" do
    socket = %Phoenix.LiveView.Socket{endpoint: UiWeb.Endpoint}

    assert {:cont, ^socket} =
             BasicAuth.on_mount(:default, %{}, %{"ui_basic_ok" => true}, socket)
  end

  test "on_mount halts and redirects when ui_basic_ok is missing" do
    socket = %Phoenix.LiveView.Socket{endpoint: UiWeb.Endpoint}

    assert {:halt, redirected} = BasicAuth.on_mount(:default, %{}, %{}, socket)
    assert {:redirect, %{to: "/"}} = redirected.redirected
  end
end
