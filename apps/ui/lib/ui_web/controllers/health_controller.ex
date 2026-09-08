defmodule UiWeb.HealthController do
  @moduledoc """
  認証不要の稼働エンドポイント。Compose healthcheck と外部監視の共通入口。
  """
  use UiWeb, :controller

  def show(conn, _params) do
    health = Bitflyer.System.health()
    status_code = if health.healthy?, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(Bitflyer.Health.to_json_map(health))
  end
end
