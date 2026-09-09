defmodule Mix.Tasks.Bitflyer.Resume do
  @moduledoc """
  halted からの手動復帰。

  再突合に成功したときだけ RiskState / Readiness の halt を解除し Ready にする。

      mix bitflyer.resume

  常駐の `phx.server` とは別 BEAM で動く場合、DB 上の RiskState は解除されるが
  常駐側 ETS の halted は残る。そのときは `docker compose restart app` で起動突合させる。
  同一ノードなら `Bitflyer.System.resume/0`（IEx）でも可。
  """

  use Mix.Task

  @shortdoc "Re-reconcile and clear halt only on success"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Bitflyer.System.resume() do
      :ok ->
        readiness = Bitflyer.Readiness.format(Bitflyer.Readiness.get())
        Mix.shell().info("resume ok: readiness=#{readiness}")

        Mix.shell().info(
          "Note: if phx.server runs in another BEAM, restart the app so ETS readiness matches DB."
        )

        :ok

      {:error, :not_halted} ->
        Mix.shell().error("resume failed: not halted")
        System.halt(1)

      {:error, reason, details} when is_map(details) ->
        Mix.shell().error("resume failed: #{inspect(reason)} #{inspect(details)}")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("resume failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
