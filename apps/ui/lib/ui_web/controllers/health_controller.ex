defmodule UiWeb.HealthController do
  @moduledoc """
  認証不要の稼働エンドポイント。Compose healthcheck と外部監視の共通入口。
  """
  use UiWeb, :controller

  require Logger

  def show(conn, _params) do
    health = Bitflyer.System.health()
    status_code = if health.healthy?, do: 200, else: 503

    if not health.healthy? do
      Logger.error(
        "health check unhealthy status=#{health.status} reason=#{inspect(health.reason)} db=#{health.db} db_error=#{inspect(health.db_error)}"
      )
    end

    conn
    |> put_status(status_code)
    |> json(Bitflyer.Health.to_json_map(health))
  end
end
