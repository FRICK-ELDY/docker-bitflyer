defmodule UiWeb.StatusLive do
  @moduledoc """
  稼働確認ページ。発注可否・取引モード・Ready・Feed・市場データ鮮度・DB を表示する。
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
