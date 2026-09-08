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
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p class="text-sm uppercase tracking-wide text-base-content/60">{gettext("Status")}</p>

            <h1 id="app-name" class="mt-2 text-3xl font-semibold tracking-tight">{@app_name}</h1>

            <p class="mt-2 text-base-content/70">
              {gettext("Operational health check. This is not a trading UI.")}
            </p>
          </div>

          <nav
            id="locale-switcher"
            class="flex items-center gap-2 text-sm"
            aria-label={gettext("Language")}
          >
            <.link
              id="locale-en"
              href={~p"/locale/en"}
              class={[
                "transition-colors hover:text-base-content",
                @locale == "en" && "font-semibold text-base-content",
                @locale != "en" && "text-base-content/60"
              ]}
            >
              English
            </.link>
            <span class="text-base-content/30" aria-hidden="true">|</span>
            <.link
              id="locale-ja"
              href={~p"/locale/ja"}
              class={[
                "transition-colors hover:text-base-content",
                @locale == "ja" && "font-semibold text-base-content",
                @locale != "ja" && "text-base-content/60"
              ]}
            >
              日本語
            </.link>
          </nav>
        </div>

        <dl class="grid gap-4 sm:grid-cols-2">
          <div id="trade-mode-card" class="rounded-lg border border-base-300 bg-base-200/40 p-4">
            <dt class="text-sm text-base-content/60">{gettext("Trade mode")}</dt>

            <dd id="trade-mode" class="mt-1 font-mono text-lg font-medium">
              {Bitflyer.TradeMode.name(@trade_mode)}
            </dd>
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
              <span id="db-status-label">
                {if(@db_ok?, do: gettext("connected"), else: gettext("unavailable"))}
              </span>
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
