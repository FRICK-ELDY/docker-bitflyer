defmodule Bitflyer.Observe.DiscordTest do
  use ExUnit.Case, async: false

  import Bitflyer.TestSupport.ReadinessHelper

  alias Bitflyer.Observe.Discord
  alias Bitflyer.Readiness
  alias Bitflyer.Telemetry

  defmodule CapturingHTTP do
    @moduledoc false
    def post_json(url, body) do
      case Process.whereis(:discord_http_probe) do
        nil -> :ok
        pid -> send(pid, {:discord_post, url, body})
      end

      :ok
    end
  end

  defmodule FailingHTTP do
    @moduledoc false
    def post_json(_url, _body), do: {:error, :forced_failure}
  end

  setup do
    reset_readiness()
    Process.register(self(), :discord_http_probe)

    on_exit(fn ->
      reset_readiness()

      if Process.whereis(:discord_http_probe) == self() do
        Process.unregister(:discord_http_probe)
      end
    end)

    :ok
  end

  test "webhook unset skips send and keeps process alive" do
    pid =
      start_supervised!(
        {Discord,
         name: :"discord-unset-#{System.unique_integer([:positive])}",
         webhook_url: nil,
         attach?: false,
         http_client: CapturingHTTP}
      )

    assert :ok = Discord.notify(pid, :halt, %{reason: :circuit_open, trade_mode: :dry_run})
    refute_receive {:discord_post, _, _}, 100
    assert Process.alive?(pid)
  end

  test "sends halt payload without leaking webhook url into body" do
    url = "https://discord.example/api/webhooks/test-secret-token"
    name = :"discord-halt-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Discord,
         name: name, webhook_url: url, attach?: false, cooldown_ms: 0, http_client: CapturingHTTP}
      )

    assert :ok =
             Discord.notify(pid, :halt, %{
               reason: :submission_unknown,
               trade_mode: :dry_run,
               to: "halted:submission_unknown"
             })

    assert_receive {:discord_post, ^url, %{content: content}}, 500
    assert content =~ "HALTED"
    assert content =~ "submission_unknown"
    assert content =~ "trade_mode=dry_run"
    refute content =~ "test-secret-token"
  end

  test "cooldown suppresses repeated disconnect notifications" do
    name = :"discord-cool-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Discord,
         name: name,
         webhook_url: "https://discord.example/hook",
         attach?: false,
         cooldown_ms: 60_000,
         http_client: CapturingHTTP}
      )

    assert :ok = Discord.notify(pid, :disconnect, %{reason: :closed, trade_mode: :dry_run})
    assert_receive {:discord_post, _, %{content: content}}, 500
    assert content =~ "MARKET_DATA_DISCONNECTED"

    assert :ok = Discord.notify(pid, :disconnect, %{reason: :closed, trade_mode: :dry_run})
    refute_receive {:discord_post, _, _}, 100
  end

  test "http failure is logged and does not stop the notifier" do
    name = :"discord-fail-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Discord,
         name: name,
         webhook_url: "https://discord.example/hook",
         attach?: false,
         cooldown_ms: 0,
         http_client: FailingHTTP}
      )

    assert :ok =
             Discord.notify(pid, :reconcile_mismatch, %{kind: :balance_mismatch, currency: "JPY"})

    assert Process.alive?(pid)
  end

  test "telemetry reconcile_mismatch reaches discord adapter" do
    name = :"discord-tel-#{System.unique_integer([:positive])}"

    _pid =
      start_supervised!(
        {Discord,
         name: name,
         webhook_url: "https://discord.example/hook",
         attach?: true,
         cooldown_ms: 0,
         http_client: CapturingHTTP}
      )

    assert :ok =
             Telemetry.execute(:reconcile_mismatch, %{count: 1}, %{
               reason: :reconcile_mismatch,
               kind: :position_mismatch,
               product_code: "FX_BTC_JPY",
               trade_mode: :live
             })

    assert_receive {:discord_post, _, %{content: content}}, 500
    assert content =~ "RECONCILE_MISMATCH"
    assert content =~ "kind=position_mismatch"
    assert content =~ "product=FX_BTC_JPY"
  end

  test "telemetry halt notifies except reconcile_mismatch reason" do
    name = :"discord-halt-tel-#{System.unique_integer([:positive])}"

    _pid =
      start_supervised!(
        {Discord,
         name: name,
         webhook_url: "https://discord.example/hook",
         attach?: true,
         cooldown_ms: 0,
         http_client: CapturingHTTP}
      )

    assert Readiness.halt(:submission_unknown) == :ok
    assert_receive {:discord_post, _, %{content: content}}, 500
    assert content =~ "HALTED"
    assert content =~ "submission_unknown"

    assert Readiness.halt(:reconcile_mismatch) == :ok
    refute_receive {:discord_post, _, _}, 100
  end

  test "supervisor stop detaches telemetry handlers via terminate" do
    name = :"discord-detach-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Discord,
         name: name,
         webhook_url: "https://discord.example/hook",
         attach?: true,
         cooldown_ms: 0,
         http_client: CapturingHTTP}
      )

    handler_id = "bitflyer-observe-discord-#{:erlang.phash2(pid)}"

    assert Enum.any?(
             :telemetry.list_handlers([:bitflyer, :reconcile, :mismatch]),
             &(&1.id == handler_id)
           )

    assert :ok = stop_supervised(Discord)

    refute Enum.any?(
             :telemetry.list_handlers([:bitflyer, :reconcile, :mismatch]),
             &(&1.id == handler_id)
           )
  end
end
