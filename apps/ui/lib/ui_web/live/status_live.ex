defmodule UiWeb.StatusLive do
  @moduledoc """
  稼働確認ページ。アプリ名・取引モード・DB 接続可否を表示する。
  """
  use UiWeb, :live_view

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok, assign_status(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_status(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="status-page" class="space-y-8">
        <div>
          <p class="text-sm uppercase tracking-wide text-base-content/60">Status</p>
          <h1 id="app-name" class="mt-2 text-3xl font-semibold tracking-tight">{@app_name}</h1>
          <p class="mt-2 text-base-content/70">運用用の生存確認。取引 UI ではない。</p>
        </div>

        <dl class="grid gap-4 sm:grid-cols-2">
          <div id="trade-mode-card" class="rounded-lg border border-base-300 bg-base-200/40 p-4">
            <dt class="text-sm text-base-content/60">取引モード</dt>
            <dd id="trade-mode" class="mt-1 font-mono text-lg font-medium">{@trade_mode}</dd>
          </div>

          <div id="db-status-card" class="rounded-lg border border-base-300 bg-base-200/40 p-4">
            <dt class="text-sm text-base-content/60">PostgreSQL</dt>
            <dd class="mt-1 flex items-center gap-2 text-lg font-medium">
              <span
                id="db-status"
                class={[
                  "inline-block size-2.5 rounded-full",
                  @db_ok? && "bg-success",
                  !@db_ok? && "bg-error"
                ]}
              />
              <span id="db-status-label">{if(@db_ok?, do: "connected", else: "unavailable")}</span>
            </dd>
            <p :if={@db_error} id="db-error" class="mt-2 text-sm text-error">{@db_error}</p>
          </div>
        </dl>
      </div>
    </Layouts.app>
    """
  end

  defp assign_status(socket) do
    {db_ok?, db_error} =
      case Bitflyer.System.check_database() do
        :ok -> {true, nil}
        {:error, message} -> {false, message}
      end

    socket
    |> assign(:app_name, "docker_bitflyer")
    |> assign(:trade_mode, Bitflyer.System.trade_mode())
    |> assign(:db_ok?, db_ok?)
    |> assign(:db_error, db_error)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end
end
