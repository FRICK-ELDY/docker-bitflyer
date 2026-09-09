defmodule Bitflyer.Observe.Discord do
  @moduledoc """
  Discord Incoming Webhook 通知アダプタ（observe）。

  telemetry を購読し、halt / reconcile_mismatch / disconnect を人に届ける。
  発注経路には接続しない。Webhook 未設定・送信失敗でも取引を止めない。

  Bot は使わない。チャンネルの Incoming Webhook URL だけを
  `DISCORD_WEBHOOK_URL` に置く。
  """

  use GenServer

  alias Bitflyer.Observe.Discord.HTTP
  alias Bitflyer.Telemetry
  alias Bitflyer.TradeMode

  @name __MODULE__
  @handler_id "bitflyer-observe-discord"
  @default_cooldown_ms 60_000

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
  @spec notify(GenServer.server(), atom(), map()) :: :ok
  def notify(server \\ @name, kind, metadata) when is_atom(kind) and is_map(metadata) do
    GenServer.cast(server, {:notify, kind, metadata})
  end

  @doc """
  設定（Application env）。
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:bitflyer, __MODULE__, [])

  @impl true
  def init(opts) do
    # Supervisor 停止時に terminate/2 で telemetry を detach するため必須。
    Process.flag(:trap_exit, true)

    cfg = config()
    webhook_url = Keyword.get(opts, :webhook_url, Keyword.get(cfg, :webhook_url))

    cooldown_ms =
      Keyword.get(opts, :cooldown_ms, Keyword.get(cfg, :cooldown_ms, @default_cooldown_ms))

    http_client = Keyword.get(opts, :http_client, Keyword.get(cfg, :http_client, HTTP))
    attach? = Keyword.get(opts, :attach?, Keyword.get(cfg, :attach?, true))

    if attach? do
      :ok = attach_handlers(self())
    end

    {:ok,
     %{
       webhook_url: normalize_url(webhook_url),
       cooldown_ms: cooldown_ms,
       http_client: http_client,
       last_sent_at: %{},
       attached?: attach?
     }}
  end

  @impl true
  def terminate(_reason, state) do
    if state.attached? do
      _ = :telemetry.detach(handler_id(self()))
    end

    :ok
  end

  @impl true
  def handle_cast({:notify, kind, metadata}, state) do
    {:noreply, maybe_send(state, kind, metadata)}
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
      content = format_message(kind, metadata)
      result = deliver(state.http_client, state.webhook_url, content)

      case result do
        :ok ->
          %{state | last_sent_at: Map.put(state.last_sent_at, kind, now)}

        {:error, reason} ->
          # URL はログに出さない。通知失敗で取引は止めない。
          Telemetry.log(:error, "discord notify failed: #{inspect(reason)}", %{reason: kind})
          state
      end
    end
  end

  defp deliver(client, url, content) do
    try do
      client.post_json(url, %{content: content})
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp format_message(kind, metadata) do
    trade_mode = metadata[:trade_mode] || TradeMode.current()
    readiness = safe_readiness()

    [
      "[docker-bitflyer] #{kind_label(kind)}",
      "trade_mode=#{TradeMode.name(trade_mode)} readiness=#{readiness}",
      detail_line(kind, metadata)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp kind_label(:halt), do: "HALTED"
  defp kind_label(:reconcile_mismatch), do: "RECONCILE_MISMATCH"
  defp kind_label(:disconnect), do: "MARKET_DATA_DISCONNECTED"
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

  defp attach_handlers(pid) do
    :telemetry.attach_many(
      handler_id(pid),
      @events,
      &__MODULE__.handle_event/4,
      %{pid: pid}
    )
  end

  defp handler_id(pid), do: "#{@handler_id}-#{:erlang.phash2(pid)}"

  @doc false
  def handle_event([:bitflyer, :reconcile, :mismatch], _measurements, metadata, %{pid: pid}) do
    GenServer.cast(pid, {:notify, :reconcile_mismatch, Map.new(metadata)})
  end

  def handle_event([:bitflyer, :market_data, :disconnected], _measurements, metadata, %{pid: pid}) do
    GenServer.cast(pid, {:notify, :disconnect, Map.new(metadata)})
  end

  def handle_event([:bitflyer, :readiness, :changed], _measurements, metadata, %{pid: pid}) do
    metadata = Map.new(metadata)
    to = Map.get(metadata, :to, "")

    # reconcile_mismatch は専用イベントで詳細を送る。二重投稿を避ける。
    if halted_to?(to) and Map.get(metadata, :reason) != :reconcile_mismatch do
      GenServer.cast(pid, {:notify, :halt, metadata})
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp halted_to?(to) when is_binary(to), do: String.starts_with?(to, "halted")
  defp halted_to?(_), do: false
end
