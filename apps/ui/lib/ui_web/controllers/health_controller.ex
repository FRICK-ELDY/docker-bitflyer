defmodule UiWeb.HealthController do
  @moduledoc """
  認証不要の稼働エンドポイント。

  - `GET /health/live` — プロセス生存（Compose healthcheck）
  - `GET /health/ready` — 外形 readiness（DB / halt / Feed / stale）
  - `GET /health` — 従来互換（DB + halt。起動中 not_ready は 200）
  """
  use UiWeb, :controller

  def live(conn, _params) do
    health = Bitflyer.System.health_live()

    conn
    |> put_status(200)
    |> json(Bitflyer.Health.to_json_map(health))
  end

  def ready(conn, _params) do
    respond(conn, Bitflyer.System.health_ready())
  end

  def show(conn, _params) do
    respond(conn, Bitflyer.System.health())
  end

  defp respond(conn, health) do
    status_code = if health.healthy?, do: 200, else: 503

    if not health.healthy? do
      Bitflyer.Telemetry.execute(
        :health_unhealthy,
        %{count: 1},
        %{
          status: health.status,
          reason: health.reason,
          db: health.db,
          readiness: Bitflyer.Readiness.format(health.readiness),
          trade_mode: health.trade_mode
        }
      )

      # db_error は公開 JSON / telemetry metadata に載せない。サーバログ本文のみ。
      Bitflyer.Telemetry.log(
        :error,
        "health check unhealthy status=#{health.status} reason=#{inspect(health.reason)} db=#{health.db} db_error=#{inspect(health.db_error)}",
        status: health.status,
        reason: health.reason,
        db: health.db,
        trade_mode: health.trade_mode
      )
    end

    conn
    |> put_status(status_code)
    |> json(Bitflyer.Health.to_json_map(health))
  end
end
