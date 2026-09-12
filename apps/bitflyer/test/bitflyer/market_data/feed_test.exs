defmodule Bitflyer.MarketData.FeedTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.MarketDataCacheHelper
  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Health
  alias Bitflyer.MarketData
  alias Bitflyer.MarketData.{Cache, Feed, Socket}
  alias Bitflyer.Readiness
  alias Bitflyer.Risk

  @product "BTC_JPY"
  @market_key {:ticker, @product}

  defmodule FakeRest do
    @behaviour Bitflyer.MarketData.Rest.Client

    @impl true
    def fetch_ticker(product_code) do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> send(pid, {:fetch_ticker, product_code})
      end

      Agent.update(__MODULE__.Counter, fn n -> n + 1 end)

      {:ok,
       %{
         "product_code" => product_code,
         "ltp" => 4_900_000,
         "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end

    def start_counter, do: Agent.start_link(fn -> 0 end, name: __MODULE__.Counter)
    def fetch_count, do: Agent.get(__MODULE__.Counter, & &1)
  end

  setup do
    reset_market_data_cache()
    reset_readiness()

    {:ok, _} = FakeRest.start_counter()
    Process.register(self(), FakeRest)

    on_exit(fn ->
      reset_market_data_cache()
      reset_readiness()

      case Process.whereis(FakeRest.Counter) do
        pid when is_pid(pid) ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      if Process.whereis(FakeRest) == self() do
        Process.unregister(FakeRest)
      end
    end)

    :ok
  end

  test "connects, subscribes, gap-fills, and applies ws ticks" do
    parent = self()
    handler_id = "md-tick-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bitflyer, :market_data, :tick],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: true,
         reconnect_base_ms: 50,
         reconnect_max_ms: 50}
      )

    # Local auto-connect + async gap fill
    assert_receive {:fetch_ticker, @product}, 500

    assert_receive {:telemetry, [:bitflyer, :market_data, :tick], %{count: 1},
                    %{product_code: @product}},
                   500

    assert Cache.fresh?(@market_key, 5_000)
    assert {:ok, %{ltp: ltp}, _} = Cache.get(@market_key)
    assert Decimal.equal?(ltp, Decimal.new(4_900_000))

    status = Feed.status(feed)
    assert status.connected?
    assert status.subscribe_count >= 1

    socket = status.socket
    assert MarketData.ticker_channel(@product) in Socket.Local.subscribed(socket)

    frame =
      Jason.encode!(%{
        "method" => "channelMessage",
        "params" => %{
          "channel" => MarketData.ticker_channel(@product),
          "message" => %{"product_code" => @product, "ltp" => "5000000"}
        }
      })

    Socket.Local.push_frame(socket, frame)
    _ = Feed.status(feed)

    assert_receive {:telemetry, [:bitflyer, :market_data, :tick], %{count: 1},
                    %{product_code: @product}},
                   500

    assert {:ok, %{ltp: ws_ltp}, _} = Cache.get(@market_key)
    assert Decimal.equal?(ws_ltp, Decimal.new("5000000"))
  end

  test "disconnect resubscribes and gap-fills again; stale cache rejects risk" do
    parent = self()
    disc_id = "md-disc-#{System.unique_integer([:positive])}"
    tick_id = "md-tick2-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    :ok =
      :telemetry.attach(
        tick_id,
        [:bitflyer, :market_data, :tick],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(disc_id)
      :telemetry.detach(tick_id)
    end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: true,
         reconnect_base_ms: 20,
         reconnect_max_ms: 20}
      )

    assert_receive {:fetch_ticker, @product}, 500

    assert_receive {:telemetry, [:bitflyer, :market_data, :tick], %{count: 1},
                    %{product_code: @product}},
                   500

    fetches_after_connect = FakeRest.fetch_count()
    socket = Feed.status(feed).socket
    subs_before = length(Socket.Local.subscribed(socket))
    assert subs_before >= 1

    # 古いデータを残したまま切断（再接続まで発注は stale）
    now = Cache.monotonic_ms()
    assert Cache.put(@market_key, %{ltp: Decimal.new("1")}, received_at: now - 60_000) == :ok
    refute Cache.fresh?(@market_key, 5_000, now: now)

    assert Readiness.mark_ready() == :ok

    assert {:error, :stale, _} =
             Risk.authorize(
               %{
                 product_code: @product,
                 side: :buy,
                 size: Decimal.new("0.01"),
                 market_key: @market_key
               },
               positions: [],
               now: now,
               check_persisted_circuit: false
             )

    Socket.Local.notify_disconnected(socket, :test_closed)

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1}, _}, 500

    # 再接続で再購読 + 穴埋め
    assert_receive {:fetch_ticker, @product}, 500

    assert_receive {:telemetry, [:bitflyer, :market_data, :tick], %{count: 1},
                    %{product_code: @product}},
                   500

    assert FakeRest.fetch_count() > fetches_after_connect

    status = Feed.status(feed)
    assert status.connected?
    assert status.subscribe_count > subs_before

    assert Cache.fresh?(@market_key, 5_000)
  end

  test "gap fill does not overwrite newer websocket ticks" do
    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 50,
         reconnect_max_ms: 50}
      )

    await_connected(feed)

    started_at = Cache.monotonic_ms()
    newer = started_at + 10

    assert Cache.put(@market_key, %{ltp: Decimal.new("5000000")}, received_at: newer) == :ok

    send(
      feed,
      {:gap_fill_tick, @market_key, %{ltp: Decimal.new("100")}, @product, started_at}
    )

    _ = Feed.status(feed)

    assert {:ok, %{ltp: ltp}, ^newer} = Cache.get(@market_key)
    assert Decimal.equal?(ltp, Decimal.new("5000000"))
  end

  test "silent stall disconnects socket and reconnects without manual restart" do
    parent = self()
    disc_id = "md-stall-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: true,
         reconnect_base_ms: 20,
         reconnect_max_ms: 20,
         stall_timeout_ms: 80}
      )

    assert_receive {:fetch_ticker, @product}, 500
    fetches_after_connect = FakeRest.fetch_count()

    status = Feed.status(feed)
    assert status.connected?
    assert status.stall_timeout_ms == 80
    refute is_nil(status.last_frame_at)

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :stale_watchdog}},
                   500

    # 再接続で再購読 + 穴埋め（人手再起動なし）
    assert_receive {:fetch_ticker, @product}, 500
    await_connected(feed)
    assert FakeRest.fetch_count() > fetches_after_connect

    status = Feed.status(feed)
    assert status.connected?
  end

  test "ws tick resets stall watchdog so healthy feed stays connected" do
    parent = self()
    disc_id = "md-stall-reset-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 20,
         reconnect_max_ms: 20,
         stall_timeout_ms: 5_000}
      )

    await_connected(feed)
    %{stall_ref: old_ref} = :sys.get_state(feed)
    socket = Feed.status(feed).socket

    frame =
      Jason.encode!(%{
        "method" => "channelMessage",
        "params" => %{
          "channel" => MarketData.ticker_channel(@product),
          "message" => %{"product_code" => @product, "ltp" => "5100000"}
        }
      })

    Socket.Local.push_frame(socket, frame)
    _ = Feed.status(feed)

    %{stall_ref: new_ref, stall_timer: active_timer} = :sys.get_state(feed)
    assert new_ref != old_ref
    assert is_reference(active_timer)

    # 張り直し前の timer 発火は無視され、現行 stall_timer は残る
    send(feed, {:stall_watchdog, old_ref})
    _ = Feed.status(feed)

    %{stall_ref: ^new_ref, stall_timer: ^active_timer} = :sys.get_state(feed)

    refute_receive {:telemetry, [:bitflyer, :market_data, :disconnected], _,
                    %{reason: :stale_watchdog}},
                   50

    assert Feed.status(feed).connected?
  end

  test "connection_snapshot is unavailable when default feed is down" do
    refute is_pid(Process.whereis(Feed))
    assert Feed.connection_snapshot() == %{available?: false, connected?: false}
  end

  test "connection_snapshot treats another pid's flag as disconnected" do
    feed =
      start_supervised!(
        {Feed,
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    _ = :sys.get_state(feed)
    :persistent_term.put(Feed.connection_key(), {self(), true})

    assert Feed.connection_snapshot() == %{available?: true, connected?: false}
  end

  test "authorize and ready share feed_unavailable when default feed is down" do
    refute is_pid(Process.whereis(Feed))
    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData, [])

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous_md)
    end)

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.put(previous_md, :enabled, true)
    )

    now = Cache.monotonic_ms()
    assert put_fresh_ticker(@market_key, Decimal.new("5000000"), received_at: now) == :ok
    assert Readiness.mark_ready() == :ok

    assert {:error, :stale, %{reason: :feed_unavailable}} =
             Risk.authorize(
               %{
                 product_code: @product,
                 side: :buy,
                 size: Decimal.new("0.01"),
                 market_key: @market_key
               },
               positions: [],
               now: now,
               check_persisted_circuit: false
             )

    health =
      Health.ready_snapshot(
        database: fn -> :ok end,
        readiness: fn -> :ready end
      )

    assert health.status == :not_ready
    assert health.reason == :feed_unavailable
    refute health.feed.available?
  end

  test "connection_snapshot flips on disconnect while cache stays fresh" do
    parent = self()
    disc_id = "md-snap-disc-#{System.unique_integer([:positive])}"
    tick_id = "md-snap-tick-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    :ok =
      :telemetry.attach(
        tick_id,
        [:bitflyer, :market_data, :tick],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(disc_id)
      :telemetry.detach(tick_id)
    end)

    feed =
      start_supervised!(
        {Feed,
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         gap_fill_on_connect?: true,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    assert_receive {:telemetry, [:bitflyer, :market_data, :tick], %{count: 1},
                    %{product_code: @product}},
                   500

    _ = :sys.get_state(feed)
    assert Feed.connection_snapshot() == %{available?: true, connected?: true}

    now = Cache.monotonic_ms()
    assert put_fresh_ticker(@market_key, Decimal.new("5000000"), received_at: now) == :ok
    assert Cache.fresh?(@market_key, 5_000, now: now)

    socket = Feed.status(feed).socket
    Socket.Local.notify_disconnected(socket, :test_closed)

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1}, _}, 500

    _ = :sys.get_state(feed)
    assert Feed.connection_snapshot() == %{available?: true, connected?: false}
    assert Cache.fresh?(@market_key, 5_000, now: now)

    previous_md = Application.get_env(:bitflyer, Bitflyer.MarketData, [])

    on_exit(fn ->
      Application.put_env(:bitflyer, Bitflyer.MarketData, previous_md)
    end)

    Application.put_env(
      :bitflyer,
      Bitflyer.MarketData,
      Keyword.put(previous_md, :enabled, true)
    )

    assert Readiness.mark_ready() == :ok

    assert {:error, :stale, %{reason: :feed_disconnected}} =
             Risk.authorize(
               %{
                 product_code: @product,
                 side: :buy,
                 size: Decimal.new("0.01"),
                 market_key: @market_key
               },
               positions: [],
               now: now,
               check_persisted_circuit: false
             )
  end

  test "write success alone does not mark feed connected" do
    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed)
    status = Feed.status(feed)
    refute status.connected?
    assert status.pending_ack_count == 1
    assert status.subscribe_count == 0
    assert MarketData.ticker_channel(@product) in Socket.Local.subscribed(status.socket)
  end

  test "subscribe ACK marks connected and increments subscribe_count" do
    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed)
    socket = Feed.status(feed).socket
    assert :ok = Socket.Local.ack(socket, 1)
    await_connected(feed)

    status = Feed.status(feed)
    assert status.connected?
    assert status.pending_ack_count == 0
    assert status.subscribe_count == 1
  end

  test "string id ACK matches integer pending request" do
    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed)
    socket = Feed.status(feed).socket

    assert :ok =
             Socket.Local.push_frame(
               socket,
               Jason.encode!(%{"id" => "1", "result" => true})
             )

    await_connected(feed)
    assert Feed.status(feed).connected?
    assert Feed.status(feed).pending_ack_count == 0
  end

  test "one of two subscribe ACKs does not mark connected" do
    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product, "ETH_JPY"],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed, 2)
    socket = Feed.status(feed).socket
    assert :ok = Socket.Local.ack(socket, 1)
    _ = :sys.get_state(feed)

    status = Feed.status(feed)
    refute status.connected?
    assert status.pending_ack_count == 1
    assert status.subscribe_count == 1

    assert :ok = Socket.Local.ack(socket, 2)
    await_connected(feed)
    status = Feed.status(feed)
    assert status.connected?
    assert status.pending_ack_count == 0
    assert status.subscribe_count == 2
  end

  test "result false subscribe response reconnects" do
    parent = self()
    disc_id = "md-ack-false-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed)
    socket = Feed.status(feed).socket

    assert :ok =
             Socket.Local.push_frame(
               socket,
               Jason.encode!(%{"id" => 1, "result" => false})
             )

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :subscribe_error}},
                   500

    refute Feed.status(feed).connected?
  end

  test "channelError reconnects" do
    parent = self()
    disc_id = "md-ch-err-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    await_pending_subscribe(feed)
    socket = Feed.status(feed).socket

    assert :ok =
             Socket.Local.push_frame(
               socket,
               Jason.encode!(%{"method" => "channelError", "params" => %{"channel" => "x"}})
             )

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :subscribe_error}},
                   500
  end

  test "subscribe ACK timeout reconnects" do
    parent = self()
    disc_id = "md-ack-timeout-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :never,
         subscribe_ack_timeout_ms: 40,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 20,
         reconnect_max_ms: 20}
      )

    await_pending_subscribe(feed)

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :subscribe_ack_timeout}},
                   500

    _ = :sys.get_state(feed)
    refute Feed.status(feed).connected?
  end

  test "subscribe RPC error reconnects" do
    parent = self()
    disc_id = "md-ack-err-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    _feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Socket.Local,
         subscribe_ack: :error,
         subscribe_ack_timeout_ms: 30_000,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :subscribe_error}},
                   500
  end

  test "subscribe write failure reconnects" do
    parent = self()
    disc_id = "md-ack-write-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        disc_id,
        [:bitflyer, :market_data, :disconnected],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(disc_id) end)

    _feed =
      start_supervised!(
        {Feed,
         name: :"feed-#{System.unique_integer([:positive])}",
         product_codes: [@product],
         rest_client: FakeRest,
         socket_client: Bitflyer.TestSupport.WriteFailSocket,
         gap_fill_on_connect?: false,
         reconnect_base_ms: 30_000,
         reconnect_max_ms: 30_000}
      )

    assert_receive {:telemetry, [:bitflyer, :market_data, :disconnected], %{count: 1},
                    %{reason: :subscribe_failed}},
                   500
  end

  defp await_connected(feed) do
    connected? =
      Enum.any?(1..50, fn _ ->
        _ = :sys.get_state(feed)

        if Feed.status(feed).connected? do
          true
        else
          pause_ms(1)
          false
        end
      end)

    assert connected?, "feed did not become connected"
  end

  defp await_pending_subscribe(feed, count \\ 1) do
    pending? =
      Enum.any?(1..50, fn _ ->
        _ = :sys.get_state(feed)
        status = Feed.status(feed)

        if status.pending_ack_count >= count and not is_nil(status.socket) do
          true
        else
          pause_ms(1)
          false
        end
      end)

    assert pending?, "feed did not start a pending subscribe"
  end

  defp pause_ms(ms) do
    receive do
    after
      ms -> :ok
    end
  end
end
