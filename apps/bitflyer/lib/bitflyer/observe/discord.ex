defmodule Bitflyer.Observe.Discord do
  @moduledoc """
  Discord Incoming Webhook 通知アダプタ（observe）。

  telemetry は Application 起動時に静的 ID で一度だけ attach し、イベントは
  登録名の GenServer へ cast する（GenServer 再起動で attach/detach しない）。

  発注経路には接続しない。Webhook 未設定・送信失敗でも取引を止めない。
  Bot は使わない。`DISCORD_WEBHOOK_URL` に Incoming Webhook URL を置く。

  Webhook があるとき、起動直後に HEARTBEAT を 1 通送り、以降は
  `heartbeat_interval_ms`（既定 15 分）ごと。通知経路の死はイベント欠落では
  分からない。イベント cooldown は heartbeat に掛けない。
  HTTP は Task に逃がし、halt の cast を待たせない。失敗ログから URL を落とす。
  """

  use GenServer

  alias Bitflyer.Observe.Discord.HTTP
  alias Bitflyer.Telemetry
  alias Bitflyer.TradeMode

  @name __MODULE__
  @handler_id "bitflyer-observe-discord"
  @default_cooldown_ms 60_000
  @default_heartbeat_interval_ms 15 * 60 * 1000
  # Discord Incoming Webhook の content 上限
  @max_content_length 2000
  @truncate_suffix "...(trunc)"

  @events [
    [:bitflyer, :readiness, :changed],
    [:bitflyer, :reconcile, :mismatch],
    [:bitflyer, :market_data, :disconnected]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  テスト用。手動で通知を積む。
  """
  @spec notify(atom(), map()) :: :ok
  def notify(kind, metadata) when is_atom(kind) and is_map(metadata) do
    notify(@name, kind, metadata)
  end

  @spec notify(GenServer.server(), atom(), map()) :: :ok
  def notify(server, kind, metadata) when is_atom(kind) and is_map(metadata) do
    GenServer.cast(server, {:notify, kind, metadata})
  end

  @doc """
  設定（Application env）。
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:bitflyer, __MODULE__, [])

  @doc """
  telemetry ハンドラを静的 ID で一度 attach する。

  `target:` で cast 先（既定は `__MODULE__`）。テストでは一意の `id:` を渡す。
  """
  @spec install_telemetry(keyword()) :: :ok
  def install_telemetry(opts \\ []) do
    id = Keyword.get(opts, :id, @handler_id)
    target = Keyword.get(opts, :target, @name)

    case :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, %{target: target}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  `install_telemetry/1` で付けたハンドラを外す。
  """
  @spec uninstall_telemetry(keyword()) :: :ok
  def uninstall_telemetry(opts \\ []) do
    id = Keyword.get(opts, :id, @handler_id)
    _ = :telemetry.detach(id)
    :ok
  end

  @doc false
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @impl true
  def init(opts) do
    cfg = config()
    webhook_url = Keyword.get(opts, :webhook_url, Keyword.get(cfg, :webhook_url))

    cooldown_ms =
      Keyword.get(opts, :cooldown_ms, Keyword.get(cfg, :cooldown_ms, @default_cooldown_ms))

    http_client = Keyword.get(opts, :http_client, Keyword.get(cfg, :http_client, HTTP))

    heartbeat_interval_ms =
      opts
      |> Keyword.get(
        :heartbeat_interval_ms,
        Keyword.get(cfg, :heartbeat_interval_ms, @default_heartbeat_interval_ms)
      )
      |> normalize_interval()

    state = %{
      webhook_url: normalize_url(webhook_url),
      cooldown_ms: cooldown_ms,
      heartbeat_interval_ms: heartbeat_interval_ms,
      http_client: http_client,
      last_sent_at: %{}
    }

    {:ok, schedule_heartbeat(state, :initial)}
  end

  @impl true
  def handle_cast({:notify, kind, metadata}, state) do
    {:noreply, maybe_send(state, kind, metadata)}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    {:noreply, state |> deliver_now(:heartbeat, %{}) |> schedule_heartbeat(:interval)}
  end

  defp maybe_send(%{webhook_url: nil} = state, kind, _metadata) do
    Telemetry.log(:debug, "discord notify skipped (webhook unset)", %{reason: kind})
    state
  end

  defp maybe_send(state, kind, metadata) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(state.last_sent_at, kind)

    if is_integer(last) and now - last < state.cooldown_ms do
      Telemetry.log(:debug, "discord notify suppressed (cooldown)", %{reason: kind})
      state
    else
      deliver_now(state, kind, metadata)
    end
  end

  # heartbeat は間隔タイマーがレート制限。イベント cooldown は掛けない。
  defp deliver_now(%{webhook_url: nil} = state, kind, _metadata) do
    Telemetry.log(:debug, "discord notify skipped (webhook unset)", %{reason: kind})
    state
  end

  defp deliver_now(state, kind, metadata) do
    now = System.monotonic_time(:millisecond)

    try do
      content = format_message(kind, metadata)
      client = state.http_client
      url = state.webhook_url

      # HTTP は Task。失敗時も先に cooldown して連打で GenServer を埋めない。
      _ =
        Task.start(fn ->
          case deliver(client, url, content) do
            :ok ->
              :ok

            {:error, reason} ->
              Telemetry.log(
                :error,
                "discord notify failed: #{redact_reason(reason)}",
                %{reason: kind}
              )
          end
        end)

      mark_sent(state, kind, now)
    rescue
      error ->
        Telemetry.log(
          :error,
          "discord notify failed during formatting: #{redact_reason(Exception.message(error))}",
          %{reason: kind}
        )

        mark_sent(state, kind, now)
    catch
      kind_caught, reason ->
        Telemetry.log(
          :error,
          "discord notify failed during formatting: #{redact_reason({kind_caught, reason})}",
          %{reason: kind}
        )

        mark_sent(state, kind, now)
    end
  end

  @doc false
  def redact_reason(reason) when is_binary(reason) do
    String.replace(reason, ~r{https?://[^\s"'\\]+}i, "[redacted-url]")
  end

  def redact_reason(reason) do
    reason
    |> inspect()
    |> redact_reason()
  end

  defp mark_sent(state, kind, now) do
    %{state | last_sent_at: Map.put(state.last_sent_at, kind, now)}
  end

  defp deliver(client, url, content) do
    try do
      client.post_json(url, %{content: content})
    rescue
      error -> {:error, redact_reason(Exception.message(error))}
    catch
      kind, reason -> {:error, redact_reason({kind, reason})}
    end
  end

  defp format_message(kind, metadata) do
    trade_mode = metadata[:trade_mode] || TradeMode.current()
    readiness = safe_readiness()

    message =
      [
        "[docker-bitflyer] #{kind_label(kind)}",
        "trade_mode=#{TradeMode.name(trade_mode)} readiness=#{readiness}",
        detail_line(kind, metadata)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    truncate_content(message)
  end

  defp truncate_content(message) when is_binary(message) do
    if String.length(message) <= @max_content_length do
      message
    else
      keep = @max_content_length - String.length(@truncate_suffix)
      String.slice(message, 0, keep) <> @truncate_suffix
    end
  end

  defp kind_label(:halt), do: "HALTED"
  defp kind_label(:reconcile_mismatch), do: "RECONCILE_MISMATCH"
  defp kind_label(:disconnect), do: "MARKET_DATA_DISCONNECTED"
  defp kind_label(:heartbeat), do: "HEARTBEAT"
  defp kind_label(other), do: other |> to_string() |> String.upcase()

  defp detail_line(:halt, metadata) do
    "reason=#{stringify(metadata[:reason] || metadata[:to])}"
  end

  defp detail_line(:reconcile_mismatch, metadata) do
    [
      metadata[:kind] && "kind=#{stringify(metadata[:kind])}",
      metadata[:currency] && "currency=#{stringify(metadata[:currency])}",
      metadata[:product_code] && "product=#{stringify(metadata[:product_code])}",
      metadata[:reason] && "reason=#{stringify(metadata[:reason])}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp detail_line(:disconnect, metadata) do
    "reason=#{stringify(metadata[:reason] || metadata[:status] || :disconnected)}"
  end

  defp detail_line(:heartbeat, _metadata), do: "probe=notify"

  defp detail_line(_kind, metadata) do
    "reason=#{stringify(metadata[:reason])}"
  end

  defp stringify(nil), do: "unknown"
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp safe_readiness do
    try do
      Bitflyer.Readiness.format(Bitflyer.Readiness.get())
    rescue
      _ -> "unknown"
    catch
      :exit, _ -> "unknown"
    end
  end

  defp normalize_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_url(_), do: nil

  defp normalize_interval(:infinity), do: :infinity
  defp normalize_interval(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_interval(_), do: :infinity

  defp schedule_heartbeat(
         %{heartbeat_interval_ms: ms, webhook_url: url} = state,
         :initial
       )
       when is_integer(ms) and ms > 0 and is_binary(url) do
    Process.send_after(self(), :heartbeat, 0)
    state
  end

  defp schedule_heartbeat(
         %{heartbeat_interval_ms: ms, webhook_url: url} = state,
         :interval
       )
       when is_integer(ms) and ms > 0 and is_binary(url) do
    Process.send_after(self(), :heartbeat, ms)
    state
  end

  defp schedule_heartbeat(state, _when), do: state

  @doc false
  def handle_event([:bitflyer, :reconcile, :mismatch], _measurements, metadata, config) do
    cast_notify(config, :reconcile_mismatch, Map.new(metadata))
  end

  def handle_event([:bitflyer, :market_data, :disconnected], _measurements, metadata, config) do
    cast_notify(config, :disconnect, Map.new(metadata))
  end

  def handle_event([:bitflyer, :readiness, :changed], _measurements, metadata, config) do
    metadata = Map.new(metadata)
    to = Map.get(metadata, :to, "")

    # reconcile_mismatch は専用イベントで詳細を送る。二重投稿を避ける。
    if halted_to?(to) and Map.get(metadata, :reason) != :reconcile_mismatch do
      cast_notify(config, :halt, metadata)
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp cast_notify(%{target: target}, kind, metadata) do
    case resolve_target(target) do
      nil -> :ok
      pid when is_pid(pid) -> GenServer.cast(pid, {:notify, kind, metadata})
    end
  end

  defp resolve_target(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp resolve_target(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_target(_), do: nil

  defp halted_to?(to) when is_binary(to), do: String.starts_with?(to, "halted")
  defp halted_to?(_), do: false
end
