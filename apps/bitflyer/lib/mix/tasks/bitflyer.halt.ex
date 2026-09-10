defmodule Mix.Tasks.Bitflyer.Halt do
  @moduledoc """
  RiskState に永続 halt を書く補助（kill switch の DB 側）。

  **即停止（Readiness ETS）の正本は同一 BEAM の StatusLive Kill /
  `Bitflyer.Release.halt_trading` rpc。**

  `docker compose exec … mix bitflyer.halt` は常駐 `phx.server` と別 BEAM のため、
  このタスクだけでは常駐側 ETS は即時更新されない。常駐の `Risk.CircuitSync`
  （既定 2s）が DB→ETS を同期すると新規発注は止まる（その間の遅れと画面 Ready
  表示とのずれがありうる）。即停止の正本は StatusLive / Release rpc。
  """

  use Mix.Task

  @shortdoc "Persist RiskState halt (prefer StatusLive/rpc for live ETS)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Bitflyer.System.halt_trading(operator: "mix.bitflyer.halt") do
      :ok ->
        Mix.shell().info("RiskState halt persisted (reason=manual_halt or already halted).")

        Mix.shell().error("""
        WARNING: Mix runs in a separate BEAM from phx.server.
        - Running app Readiness ETS is NOT updated immediately by this task.
        - CircuitSync (default 2s) will sync DB halt into ETS on the running app.
        Prefer immediate stop: StatusLive Kill, or rpc \"Bitflyer.Release.halt_trading()\".
        """)

        :ok

      {:ok, :persist_failed} ->
        Mix.shell().error(
          "This Mix BEAM ETS is halted but RiskState persist failed — running app may keep trading."
        )

        System.halt(1)

      {:error, error} ->
        Mix.shell().error("halt failed: #{inspect(error)}")
        System.halt(1)
    end
  end
end
