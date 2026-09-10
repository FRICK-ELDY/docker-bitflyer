defmodule Mix.Tasks.Bitflyer.Halt do
  @moduledoc """
  RiskState に永続 halt を書く補助（kill switch の DB 側）。

  **即停止（Readiness ETS）の正本は同一 BEAM の StatusLive Kill /
  `Bitflyer.Release.halt_trading` rpc。**

  `docker compose exec … mix bitflyer.halt` は常駐 `phx.server` と別 BEAM のため、
  このタスクだけでは常駐側 ETS は変わらない。ただし `Risk.authorize` は永続
  RiskState を見るので、DB 反映後は新規発注は拒否される（画面の Ready 表示と
  ずれる場合あり）。ETS 表示を揃えるには StatusLive / rpc / `restart app`。
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
        - New orders: blocked via persisted RiskState (authorize fail-closed).
        - Running app Readiness ETS is NOT updated by this task.
        Prefer: StatusLive Kill switch, or rpc \"Bitflyer.Release.halt_trading()\".
        To sync ETS display: StatusLive Kill, Release rpc, or restart app.
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
