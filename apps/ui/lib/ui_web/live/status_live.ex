defmodule UiWeb.StatusLive do
  @moduledoc """
  稼働確認ページ。発注可否・取引モード・Ready・Feed・市場データ鮮度・DB を表示する。
  認証済み操作: kill switch（即 halt）、halt 中の resume / reconcile_now。
  """
  use UiWeb, :live_view

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign_new(:ops_operator, fn -> "anonymous" end)
     |> assign(:ops_busy, false)
     |> assign_status()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_status(socket)}
  end

  @impl true
  def handle_event("kill_switch", _params, %{assigns: %{ops_busy: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("kill_switch", _params, socket) do
    operator = socket.assigns.ops_operator

    {:noreply,
     socket
     |> assign(:ops_busy, true)
     |> start_async(:ops_kill, fn ->
       Bitflyer.System.halt_trading(operator: operator)
     end)}
  end

  def handle_event("resume", _params, %{assigns: %{ops_busy: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("resume", _params, socket) do
    operator = socket.assigns.ops_operator

    {:noreply,
     socket
     |> assign(:ops_busy, true)
     |> start_async(:ops_resume, fn ->
       Bitflyer.System.resume(operator: operator)
     end)}
  end

  def handle_event("reconcile_now", _params, %{assigns: %{ops_busy: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("reconcile_now", _params, socket) do
    operator = socket.assigns.ops_operator

    {:noreply,
     socket
     |> assign(:ops_busy, true)
     |> start_async(:ops_reconcile, fn ->
       Bitflyer.System.reconcile_now(operator: operator)
     end)}
  end

  @impl true
  def handle_async(:ops_kill, {:ok, result}, socket) do
    {:noreply, finish_ops(socket, :kill, result)}
  end

  def handle_async(:ops_kill, {:exit, reason}, socket) do
    {:noreply, finish_ops_exit(socket, reason)}
  end

  def handle_async(:ops_resume, {:ok, result}, socket) do
    {:noreply, finish_ops(socket, :resume, result)}
  end

  def handle_async(:ops_resume, {:exit, reason}, socket) do
    {:noreply, finish_ops_exit(socket, reason)}
  end

  def handle_async(:ops_reconcile, {:ok, result}, socket) do
    {:noreply, finish_ops(socket, :reconcile, result)}
  end

  def handle_async(:ops_reconcile, {:exit, reason}, socket) do
    {:noreply, finish_ops_exit(socket, reason)}
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

        <section
          id="orders-gate"
          class={[
            "rounded-lg border px-4 py-4 transition-colors sm:px-5",
            @orders_allowed? && "border-success/40 bg-success/10",
            !@orders_allowed? && "border-error/40 bg-error/10"
          ]}
          aria-live="polite"
        >
          <p class="text-sm font-medium text-base-content/70">{gettext("Orders")}</p>

          <p
            id="orders-gate-label"
            class={[
              "mt-1 font-mono text-2xl font-semibold tracking-tight",
              @orders_allowed? && "text-success",
              !@orders_allowed? && "text-error"
            ]}
          >
            {@orders_gate_label}
          </p>

          <p :if={@orders_reason} id="orders-gate-reason" class="mt-2 text-sm text-base-content/70">
            {gettext("Reason")}: <span class="font-mono">{@orders_reason}</span>
          </p>
        </section>

        <section
          id="ops-controls"
          class="rounded-lg border border-base-300 bg-base-200/30 px-4 py-4 sm:px-5"
        >
          <p class="text-sm font-medium text-base-content/70">{gettext("Operations")}</p>

          <p class="mt-1 text-sm text-base-content/60">
            {gettext("Authenticated controls. Kill stops orders immediately.")}
          </p>

          <div class="mt-4 flex flex-wrap gap-3">
            <button
              id="ops-kill-switch"
              type="button"
              phx-click="kill_switch"
              phx-disable-with={gettext("Halting…")}
              disabled={@ops_busy}
              class={[
                "btn btn-error btn-sm transition-opacity",
                @ops_busy && "opacity-60"
              ]}
            >
              {gettext("Kill switch")}
            </button>

            <button
              :if={@halted?}
              id="ops-resume"
              type="button"
              phx-click="resume"
              data-confirm={gettext("Resume after re-reconcile? Only if reconcile succeeds.")}
              phx-disable-with={gettext("Resuming…")}
              disabled={@ops_busy}
              class={[
                "btn btn-warning btn-sm transition-opacity",
                @ops_busy && "opacity-60"
              ]}
            >
              {gettext("Resume")}
            </button>

            <button
              :if={@halted?}
              id="ops-reconcile-now"
              type="button"
              phx-click="reconcile_now"
              phx-disable-with={gettext("Reconciling…")}
              disabled={@ops_busy}
              class={[
                "btn btn-neutral btn-sm transition-opacity",
                @ops_busy && "opacity-60"
              ]}
            >
              {gettext("Reconcile now")}
            </button>
          </div>
        </section>

        <dl class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div
            id="trade-mode-card"
            class={[
              "rounded-lg border p-4 transition-colors",
              trade_mode_card_class(@trade_mode)
            ]}
          >
            <dt class="text-sm text-base-content/60">{gettext("Trade mode")}</dt>

            <dd
              id="trade-mode"
              class={[
                "mt-1 font-mono text-lg font-medium",
                trade_mode_text_class(@trade_mode)
              ]}
            >
              {Bitflyer.TradeMode.name(@trade_mode)}
            </dd>
          </div>

          <div
            id="readiness-card"
            class={[
              "rounded-lg border p-4",
              readiness_card_class(@readiness)
            ]}
          >
            <dt class="text-sm text-base-content/60">{gettext("Readiness")}</dt>

            <dd
              id="readiness"
              class={[
                "mt-1 font-mono text-lg font-medium",
                readiness_text_class(@readiness)
              ]}
            >
              {@readiness_label}
            </dd>

            <p
              :if={@halt_reason}
              id="halt-reason"
              class="mt-2 text-sm text-error"
            >
              {gettext("Halt reason")}: <span class="font-mono">{@halt_reason}</span>
            </p>
          </div>

          <div
            id="feed-status-card"
            class={[
              "rounded-lg border p-4",
              feed_card_class(@feed)
            ]}
          >
            <dt class="text-sm text-base-content/60">{gettext("Feed")}</dt>

            <dd
              id="feed-status"
              class={[
                "mt-1 font-mono text-lg font-medium",
                feed_text_class(@feed)
              ]}
            >
              {@feed_label}
            </dd>

            <p
              :if={@feed.enabled?}
              id="feed-status-detail"
              class="mt-2 space-y-1 text-sm text-base-content/70"
            >
              <span class="block font-mono">
                {gettext("subscribes")}: {@feed.subscribe_count}
              </span>
              <span class="block font-mono">
                {gettext("reconnects")}: {@feed.reconnect_attempt}
              </span>
            </p>
          </div>

          <div
            id="market-freshness-card"
            class={[
              "rounded-lg border p-4",
              @market_all_fresh? && "border-success/30 bg-success/5",
              !@market_all_fresh? && "border-warning/40 bg-warning/5"
            ]}
          >
            <dt class="text-sm text-base-content/60">{gettext("Market data")}</dt>

            <dd
              id="market-freshness"
              class={[
                "mt-1 font-mono text-lg font-medium",
                @market_all_fresh? && "text-success",
                !@market_all_fresh? && "text-warning"
              ]}
            >
              {@market_freshness_label}
            </dd>

            <ul id="market-freshness-entries" class="mt-2 space-y-1 text-sm text-base-content/70">
              <li
                :for={entry <- @market_entries}
                id={"market-freshness-#{entry.product_code}"}
                class="font-mono"
              >
                {entry.product_code}: {format_age_ms(entry.age_ms)}
                <span class="text-base-content/50">
                  ({if(entry.fresh?, do: gettext("fresh"), else: gettext("stale"))})
                </span>
              </li>
            </ul>
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

    status = Bitflyer.System.operational_status()

    socket
    |> assign(:app_name, "docker_bitflyer")
    |> assign(:trade_mode, status.trade_mode)
    |> assign(:readiness, status.readiness)
    |> assign(:readiness_label, status.readiness_label)
    |> assign(:halted?, match?({:halted, _}, status.readiness))
    |> assign(:halt_reason, reason_label(status.halt_reason))
    |> assign(:orders_allowed?, status.orders_allowed?)
    |> assign(:orders_reason, reason_label(status.orders_reason))
    |> assign(:orders_gate_label, orders_gate_label(status.orders_allowed?))
    |> assign(:feed, status.feed)
    |> assign(:feed_label, feed_label(status.feed))
    |> assign(:market_all_fresh?, status.market_data.all_fresh?)
    |> assign(:market_freshness_label, market_freshness_label(status.market_data))
    |> assign(:market_entries, status.market_data.entries)
    |> assign(:db_ok?, db_ok?)
    |> assign(:db_error, db_error)
  end

  defp finish_ops(socket, kind, result) do
    socket
    |> assign(:ops_busy, false)
    |> flash_ops_result(kind, result)
    |> assign_status()
  end

  defp finish_ops_exit(socket, reason) do
    socket
    |> assign(:ops_busy, false)
    |> put_flash(
      :error,
      gettext("Operation failed: %{reason}", reason: inspect(reason))
    )
    |> assign_status()
  end

  defp flash_ops_result(socket, :kill, :ok) do
    put_flash(socket, :info, gettext("Kill switch applied. Orders are halted."))
  end

  defp flash_ops_result(socket, :kill, {:ok, :persist_failed}) do
    put_flash(
      socket,
      :error,
      gettext("Orders halted in memory, but RiskState persist failed. Restart may clear it.")
    )
  end

  defp flash_ops_result(socket, :kill, {:error, error}) do
    put_flash(socket, :error, gettext("Kill switch failed: %{error}", error: inspect(error)))
  end

  defp flash_ops_result(socket, :resume, :ok) do
    put_flash(socket, :info, gettext("Resume succeeded. System is ready."))
  end

  defp flash_ops_result(socket, :resume, {:error, :not_halted}) do
    put_flash(socket, :error, gettext("Resume failed: not halted."))
  end

  defp flash_ops_result(socket, :resume, {:error, reason, _details}) do
    put_flash(socket, :error, gettext("Resume failed: %{reason}", reason: inspect(reason)))
  end

  defp flash_ops_result(socket, :resume, {:error, reason}) do
    put_flash(socket, :error, gettext("Resume failed: %{reason}", reason: inspect(reason)))
  end

  defp flash_ops_result(socket, :reconcile, :ok) do
    put_flash(socket, :info, gettext("Reconcile finished successfully."))
  end

  defp flash_ops_result(socket, :reconcile, {:error, reason}) do
    put_flash(socket, :error, gettext("Reconcile failed: %{reason}", reason: inspect(reason)))
  end

  defp orders_gate_label(true), do: gettext("ALLOWED")
  defp orders_gate_label(false), do: gettext("STOPPED")

  defp market_freshness_label(%{all_fresh?: true}), do: gettext("fresh")
  defp market_freshness_label(_), do: gettext("stale")

  defp feed_label(%{enabled?: false}), do: gettext("disabled")
  defp feed_label(%{available?: false}), do: gettext("unavailable")
  defp feed_label(%{connected?: true}), do: gettext("connected")
  defp feed_label(_), do: gettext("disconnected")

  defp reason_label(nil), do: nil
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(reason), do: inspect(reason)

  defp format_age_ms(:miss), do: gettext("miss")
  defp format_age_ms(age) when is_integer(age) and age < 1_000, do: "#{age}ms"
  defp format_age_ms(age) when is_integer(age), do: "#{Float.round(age / 1_000, 1)}s"

  defp trade_mode_card_class(:dry_run), do: "border-base-300 bg-base-200/40"
  defp trade_mode_card_class(:paper), do: "border-info/40 bg-info/10"
  defp trade_mode_card_class(:live), do: "border-error/50 bg-error/10"
  defp trade_mode_card_class(_), do: "border-base-300 bg-base-200/40"

  defp trade_mode_text_class(:dry_run), do: "text-base-content"
  defp trade_mode_text_class(:paper), do: "text-info"
  defp trade_mode_text_class(:live), do: "text-error"
  defp trade_mode_text_class(_), do: "text-base-content"

  defp readiness_card_class(:ready), do: "border-success/30 bg-success/5"
  defp readiness_card_class(:not_ready), do: "border-warning/40 bg-warning/5"
  defp readiness_card_class({:halted, _}), do: "border-error/40 bg-error/10"
  defp readiness_card_class(_), do: "border-base-300 bg-base-200/40"

  defp readiness_text_class(:ready), do: "text-success"
  defp readiness_text_class(:not_ready), do: "text-warning"
  defp readiness_text_class({:halted, _}), do: "text-error"
  defp readiness_text_class(_), do: "text-base-content"

  defp feed_card_class(%{enabled?: false}), do: "border-base-300 bg-base-200/40"
  defp feed_card_class(%{available?: false}), do: "border-error/40 bg-error/10"
  defp feed_card_class(%{connected?: true}), do: "border-success/30 bg-success/5"
  defp feed_card_class(_), do: "border-warning/40 bg-warning/5"

  defp feed_text_class(%{enabled?: false}), do: "text-base-content/70"
  defp feed_text_class(%{available?: false}), do: "text-error"
  defp feed_text_class(%{connected?: true}), do: "text-success"
  defp feed_text_class(_), do: "text-warning"

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end
end
