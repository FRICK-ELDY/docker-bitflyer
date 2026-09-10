defmodule UiWeb.Hooks.BasicAuthTest do
  use ExUnit.Case, async: true

  alias UiWeb.Hooks.BasicAuth

  test "on_mount continues when ui_basic_ok is true and assigns operator" do
    socket = %Phoenix.LiveView.Socket{endpoint: UiWeb.Endpoint}

    assert {:cont, mounted} =
             BasicAuth.on_mount(
               :default,
               %{},
               %{"ui_basic_ok" => true, "ui_basic_username" => "ops-user"},
               socket
             )

    assert mounted.assigns.ops_operator == "ops-user"
  end

  test "on_mount falls back to anonymous when username is missing" do
    socket = %Phoenix.LiveView.Socket{endpoint: UiWeb.Endpoint}

    assert {:cont, mounted} =
             BasicAuth.on_mount(:default, %{}, %{"ui_basic_ok" => true}, socket)

    assert mounted.assigns.ops_operator == "anonymous"
  end

  test "on_mount halts and redirects when ui_basic_ok is missing" do
    socket = %Phoenix.LiveView.Socket{endpoint: UiWeb.Endpoint}

    assert {:halt, redirected} = BasicAuth.on_mount(:default, %{}, %{}, socket)
    assert {:redirect, %{to: "/"}} = redirected.redirected
  end
end
