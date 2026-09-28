defmodule Mix.Tasks.Bitflyer.GameDayStage2 do
  @moduledoc """
  Game Day Stage 2 の縦経路（paper Executor）。

  SQL 直投入や ready 503 だけの代替ではなく、同一 BEAM で次を記録する:

  1. paper `System.submit_order/2` で建玉を作る
  2. Feed を切断し、同 API が `feed_disconnected` で拒否する
  3. Feed を戻して再認可・再発注が通る
  4. Discord Webhook へ到達確認（HTTP 2xx。URL は出さない）

      TRADE_MODE=paper mix bitflyer.game_day_stage2

  発注・取消の bitFlyer REST は呼ばない。

  `app.start` の前に Repo だけで永続 `RiskState` を読む。halted または読めないときは
  理由を出して終了し、Feed を含む監督木は起動しない。既存停止の `halted_at` は
  書き換えない。起動突合・CircuitSync・halt 時取消はこの BEAM では外す。
  Ready は seed の `Reconciler.run_now/0` が `:ok` のあと `Readiness` が `:ready`
  のときだけ使う。その失敗は新しい停止として `halted_at` を残す。
  建玉のあとと Feed 復帰後は突合をやり直さない。paper 発注の前に永続停止を読み直す。
  """

  use Mix.Task

  require Ash.Query

  alias Bitflyer.MarketData.{Cache, Feed}
  alias Bitflyer.Observe.Discord
  alias Bitflyer.Readiness
  alias Bitflyer.Risk.{BalanceCache, CircuitSync, OpenOrderPolicy}
  alias Bitflyer.Startup.Reconciler
  alias Bitflyer.System, as: TradingSystem
  alias Bitflyer.Trading.{BalanceSnapshot, Fill, Order, Position}

  @shortdoc "Game Day Stage 2 vertical path (paper Executor)"
  @product "BTC_JPY"
  @market_key {:ticker, @product}
  @feed_child Bitflyer.MarketData.Feed
  @inject_ws "wss://127.0.0.1:1/json-rpc"
  @gameday_order_prefix "gameday-paper-"
  @feed_poll_ms 50
  @feed_poll_attempts 100

  @impl Mix.Task
  def run(args) when is_list(args), do: run(args, [])

  @doc false
  @spec run(list(), keyword()) :: term()
  def run(args, opts) when is_list(args) and is_list(opts) do
    previous = disarm_startup!()

    try do
      do_run(args, opts)
    after
      restore_startup!(previous)
    end
  end

  defp do_run(_args, opts) do
    halt = Keyword.get(opts, :halt, &System.halt/1)
    start = Keyword.get(opts, :start, &start_app/0)
    read_halt = Keyword.get(opts, :read_halt, &persisted_start_block/0)

    case ensure_paper_mode() do
      :ok ->
        # 停止中に Feed まで上げない。Repo だけで読み、clear のときだけ監督木を起動する。
        case with_repo(read_halt) do
          :ok ->
            start.()
            abort_or_drill(:ok, halt)

          blocked ->
            abort_or_drill(blocked, halt)
        end

      {:error, :trade_mode, mode} ->
        Mix.shell().error("""
        TRADE_MODE must be paper (got #{inspect(mode)}).
        Example: TRADE_MODE=paper mix bitflyer.game_day_stage2
        """)

        halt.(1)
    end
  end

  defp abort_or_drill(:ok, halt) do
    stamp = System.system_time(:second)
    open_id = "#{@gameday_order_prefix}open-#{stamp}"
    reject_id = "#{@gameday_order_prefix}reject-#{stamp}"
    resume_id = "#{@gameday_order_prefix}resume-#{stamp}"

    results = %{
      trade_mode: Bitflyer.TradeMode.current(),
      seed: nil,
      open: nil,
      feed_reject: nil,
      resume: nil,
      discord: nil,
      position: nil
    }

    results =
      try do
        results
        |> step_seed_and_ready()
        |> step_open_position(open_id)
        |> step_feed_disconnect_reject(reject_id)
        |> step_feed_restore_and_resubmit(resume_id)
        |> step_discord_probe()
        |> step_position_snapshot()
      after
        # feed_reject 失敗時も毒 URL を残さない（長寿命 paper BEAM 対策）
        _ = safe_restore_feed()
        :ok = cleanup_paper_side_effects!()
      end

    print_report(results)
    halt_if_failed!(results, halt)
  end

  defp abort_or_drill({:halted, reason}, halt) do
    Mix.shell().error("""
    Game Day Stage 2 aborted: RiskState is halted (reason=#{reason}).
    This drill does not clear the circuit or rewrite halted_at.
    Resume only through the halt recovery path.
    """)

    halt.(1)
  end

  defp abort_or_drill(:unsynced, halt) do
    Mix.shell().error("""
    Game Day Stage 2 aborted: RiskState could not be read (unsynced).
    Refusing to run while a persisted halt might exist.
    """)

    halt.(1)
  end

  defp start_app do
    Mix.Task.run("app.start")
  end

  defp with_repo(read_halt) do
    case Bitflyer.Repo.start_link() do
      {:ok, pid} ->
        try do
          read_halt.()
        after
          GenServer.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        read_halt.()
    end
  end

  # 起動突合と CircuitSync は app.start 中に live 取消へ進む。
  # start より先にこの BEAM だけ外す。常駐側の設定は別プロセスのまま。
  defp disarm_startup! do
    previous = %{
      reconciler: Application.get_env(:bitflyer, Reconciler),
      circuit_sync: Application.get_env(:bitflyer, CircuitSync),
      open_order_policy: Application.get_env(:bitflyer, OpenOrderPolicy)
    }

    reconciler = Application.get_env(:bitflyer, Reconciler, [])

    Application.put_env(
      :bitflyer,
      Reconciler,
      reconciler |> Keyword.put(:boot?, false) |> Keyword.put(:interval_ms, :infinity)
    )

    circuit_sync = Application.get_env(:bitflyer, CircuitSync, [])

    Application.put_env(
      :bitflyer,
      CircuitSync,
      Keyword.put(circuit_sync, :interval_ms, :disabled)
    )

    policy = Application.get_env(:bitflyer, OpenOrderPolicy, [])

    Application.put_env(
      :bitflyer,
      OpenOrderPolicy,
      policy
      |> Keyword.put(:cancel_on_halt, %{})
      |> Keyword.put(:max_open_age_ms, :infinity)
    )

    previous
  end

  defp restore_startup!(previous) do
    restore_env(Reconciler, previous.reconciler)
    restore_env(CircuitSync, previous.circuit_sync)
    restore_env(OpenOrderPolicy, previous.open_order_policy)
  end

  defp restore_env(key, nil), do: Application.delete_env(:bitflyer, key)
  defp restore_env(key, value), do: Application.put_env(:bitflyer, key, value)

  defp ensure_paper_mode do
    mode = Bitflyer.TradeMode.current()

    if mode == :paper do
      :ok
    else
      {:error, :trade_mode, mode}
    end
  end

  @doc false
  @spec persisted_start_block() :: :ok | {:halted, atom()} | :unsynced
  def persisted_start_block do
    case Bitflyer.Risk.Circuit.persisted_halt_reason() do
      {:halted, reason} -> {:halted, reason}
      :unsynced -> :unsynced
      :clear -> :ok
    end
  end

  @doc false
  @spec require_ready_via_reconcile() :: :ok | {:error, term()}
  def require_ready_via_reconcile do
    case Reconciler.run_now() do
      :ok ->
        case Readiness.get() do
          :ready -> :ok
          other -> {:error, {:not_ready, other}}
        end

      {:error, reason} ->
        {:error, {:reconcile_failed, reason, Readiness.get()}}
    end
  end

  # ETS の Ready だけでは発注しない。CircuitSync を止めているので、別 BEAM が
  # 共有 DB を halt してもここで読む。run_now はしない（enforce で新たに開かない）。
  @doc false
  @spec order_gate() :: :ok | {:error, term()}
  def order_gate do
    case persisted_start_block() do
      :ok ->
        case Readiness.get() do
          :ready -> :ok
          other -> {:error, {:not_ready, other}}
        end

      {:halted, reason} ->
        {:error, {:persisted_halt, reason}}

      :unsynced ->
        {:error, :unsynced}
    end
  end

  defp step_seed_and_ready(results) do
    :ok = clear_paper_btc_position!()
    :ok = seed_paper_tips!()
    :ok = BalanceCache.refresh(:paper)
    # 既存 HWM / 建玉で enforce が halt しないよう LTP を高めに置く
    put_fresh_ticker!(Decimal.new("6000000"))

    case require_ready_via_reconcile() do
      :ok ->
        Mix.shell().info("ready=ready after paper reconcile")
        %{results | seed: {:ok, :ready}}

      {:error, detail} ->
        Mix.shell().error(
          "not ready after seed/reconcile: #{inspect(detail)} (refusing mark_ready push-through)"
        )

        %{results | seed: {:error, detail}}
    end
  end

  defp step_open_position(%{seed: {:ok, _}} = results, internal_order_id) do
    case order_gate() do
      :ok ->
        case TradingSystem.submit_order(command(internal_order_id), trade_mode: :paper) do
          {:ok, order} ->
            Mix.shell().info(
              "open ok status=#{order.status} filled=#{Decimal.to_string(order.filled_size)}"
            )

            %{results | open: {:ok, order.status}}

          other ->
            Mix.shell().error("open failed: #{inspect(other)}")
            %{results | open: {:error, other}}
        end

      {:error, detail} ->
        Mix.shell().error(
          "not ready before open: #{inspect(detail)} (persisted halt blocks paper submit)"
        )

        %{results | open: {:error, detail}}
    end
  end

  defp step_open_position(results, _id), do: results

  defp step_feed_disconnect_reject(%{open: {:ok, _}} = results, internal_order_id) do
    case order_gate() do
      :ok ->
        :ok = inject_disconnected_feed!()
        :ok = await_feed!(connected?: false)

        snap = Feed.connection_snapshot()

        Mix.shell().info(
          "feed after inject available=#{snap.available?} connected=#{snap.connected?}"
        )

        case TradingSystem.submit_order(command(internal_order_id), trade_mode: :paper) do
          {:error, :stale, %{reason: :feed_disconnected} = meta} ->
            Mix.shell().info("feed reject ok reason=feed_disconnected")
            %{results | feed_reject: {:ok, meta.reason}}

          {:error, :stale, %{reason: :feed_unavailable} = meta} ->
            Mix.shell().info("feed reject ok reason=feed_unavailable")
            %{results | feed_reject: {:ok, meta.reason}}

          other ->
            Mix.shell().error("feed reject unexpected: #{inspect(other)}")
            %{results | feed_reject: {:error, other}}
        end

      {:error, detail} ->
        Mix.shell().error(
          "not ready before feed inject: #{inspect(detail)} (refusing mark_ready push-through)"
        )

        %{results | feed_reject: {:error, detail}}
    end
  end

  defp step_feed_disconnect_reject(results, _id), do: results

  # open 成功後は reject 成否に関わらず必ず Feed を戻す
  defp step_feed_restore_and_resubmit(%{open: {:ok, _}} = results, internal_order_id) do
    :ok = restore_feed!()
    :ok = await_feed!(connected?: true)
    put_fresh_ticker!(Decimal.new("6000000"))

    case order_gate() do
      :ok ->
        case results.feed_reject do
          {:ok, _} ->
            case TradingSystem.submit_order(command(internal_order_id, "0.01"),
                   trade_mode: :paper
                 ) do
              {:ok, order} ->
                Mix.shell().info("resume submit ok status=#{order.status}")
                %{results | resume: {:ok, order.status}}

              other ->
                Mix.shell().error("resume submit failed: #{inspect(other)}")
                %{results | resume: {:error, other}}
            end

          _ ->
            Mix.shell().info("resume skipped: feed_reject did not succeed")
            %{results | resume: {:error, :skipped_after_feed_reject_fail}}
        end

      {:error, detail} ->
        Mix.shell().error(
          "not ready after feed restore: #{inspect(detail)} (refusing mark_ready push-through)"
        )

        %{results | resume: {:error, detail}}
    end
  end

  defp step_feed_restore_and_resubmit(results, _id), do: results

  defp step_discord_probe(results) do
    case System.get_env("DISCORD_WEBHOOK_URL") do
      url when is_binary(url) and url != "" ->
        content =
          "Game Day Stage 2 probe trade_mode=paper (no secrets; #{DateTime.utc_now() |> DateTime.to_iso8601()})"

        case Discord.HTTP.post_json(url, %{content: content}) do
          :ok ->
            Mix.shell().info("discord probe ok http=2xx")
            Discord.notify(:heartbeat, %{source: "game_day_stage2"})
            %{results | discord: {:ok, :http_2xx}}

          {:error, reason} ->
            Mix.shell().error("discord probe failed: #{Discord.redact_reason(reason)}")
            %{results | discord: {:error, reason}}
        end

      _ ->
        Mix.shell().error("DISCORD_WEBHOOK_URL unset; cannot close Discord step")
        %{results | discord: {:error, :webhook_unset}}
    end
  end

  defp step_position_snapshot(results) do
    case Position
         |> Ash.Query.filter(product_code == ^@product and trade_mode == :paper)
         |> Ash.read_one() do
      {:ok, %Position{side: side, size: size}} ->
        Mix.shell().info("position side=#{side} size=#{Decimal.to_string(size)}")
        %{results | position: {:ok, %{side: side, size: Decimal.to_string(size)}}}

      {:ok, nil} ->
        Mix.shell().error("position not found")
        %{results | position: {:error, :not_found}}

      {:error, reason} ->
        Mix.shell().error("position read failed: #{inspect(reason)}")
        %{results | position: {:error, reason}}
    end
  end

  defp print_report(results) do
    Mix.shell().info("""

    === Game Day Stage 2 report ===
    trade_mode=#{results.trade_mode}
    seed=#{inspect(results.seed)}
    open=#{inspect(results.open)}
    feed_reject=#{inspect(results.feed_reject)}
    resume=#{inspect(results.resume)}
    discord=#{inspect(results.discord)}
    position=#{inspect(results.position)}
    """)
  end

  defp halt_if_failed!(results, halt) do
    failed? =
      Enum.any?(
        [
          results.seed,
          results.open,
          results.feed_reject,
          results.resume,
          results.discord,
          results.position
        ],
        fn
          {:ok, _} -> false
          _ -> true
        end
      )

    if failed? do
      halt.(1)
    else
      :ok
    end
  end

  defp command(internal_order_id, size \\ "0.01") do
    %{
      internal_order_id: internal_order_id,
      product_code: @product,
      side: :buy,
      size: Decimal.new(size),
      market_key: @market_key,
      order_type: :market
    }
  end

  # 常に新しい tip を積み、共有 DB で減った JPY 先端を上書きする
  defp seed_paper_tips! do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {currency, amount} <- [{"JPY", "1000000"}, {"BTC", "0"}] do
      amt = Decimal.new(amount)

      BalanceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        currency: currency,
        amount: amt,
        available: amt,
        captured_at: captured_at,
        trade_mode: :paper
      })
      |> Ash.create!()
    end

    :ok
  end

  defp put_fresh_ticker!(%Decimal{} = ltp) do
    half = Decimal.max(Decimal.new("1"), Decimal.mult(ltp, Decimal.new("0.0001")))

    :ok =
      Cache.put(@market_key, %{
        ltp: ltp,
        best_bid: Decimal.sub(ltp, half),
        best_ask: Decimal.add(ltp, half),
        source_timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond)
      })
  end

  defp cleanup_paper_side_effects! do
    :ok = clear_paper_btc_position!()
    :ok = clear_gameday_paper_orders_and_fills!()
    :ok = seed_paper_tips!()
    :ok = BalanceCache.refresh(:paper)

    Mix.shell().info(
      "cleanup: paper position cleared, gameday orders/fills removed, tips reseeded"
    )

    :ok
  end

  defp clear_paper_btc_position! do
    case Position
         |> Ash.Query.filter(product_code == ^@product and trade_mode == :paper)
         |> Ash.read() do
      {:ok, rows} ->
        Enum.each(rows, fn row -> Ash.destroy!(row) end)
        :ok

      {:error, reason} ->
        raise "failed to clear paper position: #{inspect(reason)}"
    end
  end

  defp clear_gameday_paper_orders_and_fills! do
    Fill
    |> Ash.Query.filter(trade_mode == :paper)
    |> Ash.read!()
    |> Enum.filter(&String.starts_with?(&1.internal_order_id, @gameday_order_prefix))
    |> Enum.each(&Ash.destroy!/1)

    Order
    |> Ash.Query.filter(trade_mode == :paper)
    |> Ash.read!()
    |> Enum.filter(&String.starts_with?(&1.internal_order_id, @gameday_order_prefix))
    |> Enum.each(&Ash.destroy!/1)

    :ok
  end

  defp await_feed!(connected?: want_connected?) do
    reached? =
      Enum.any?(1..@feed_poll_attempts, fn _ ->
        snap = Feed.connection_snapshot()

        cond do
          snap.available? and snap.connected? == want_connected? ->
            true

          true ->
            Process.sleep(@feed_poll_ms)
            false
        end
      end)

    if reached? do
      :ok
    else
      snap = Feed.connection_snapshot()

      raise """
      feed did not reach connected?=#{want_connected?} within #{@feed_poll_attempts * @feed_poll_ms}ms \
      (available?=#{snap.available?} connected?=#{snap.connected?})
      """
    end
  end

  defp inject_disconnected_feed! do
    _ = Supervisor.terminate_child(Bitflyer.Supervisor, @feed_child)
    _ = Supervisor.delete_child(Bitflyer.Supervisor, @feed_child)

    spec =
      Supervisor.child_spec(
        {Feed, [ws_url: @inject_ws]},
        id: @feed_child,
        shutdown: 5_000
      )

    case Supervisor.start_child(Bitflyer.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> raise "failed to inject disconnected feed: #{inspect(reason)}"
    end
  end

  defp restore_feed! do
    _ = Supervisor.terminate_child(Bitflyer.Supervisor, @feed_child)
    _ = Supervisor.delete_child(Bitflyer.Supervisor, @feed_child)

    spec =
      Supervisor.child_spec(
        {Feed, []},
        id: @feed_child,
        shutdown: 5_000
      )

    case Supervisor.start_child(Bitflyer.Supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> raise "failed to restore feed: #{inspect(reason)}"
    end
  end

  defp safe_restore_feed do
    restore_feed!()
  rescue
    error ->
      Mix.shell().error("feed restore in after failed: #{Exception.message(error)}")
      :error
  end
end
