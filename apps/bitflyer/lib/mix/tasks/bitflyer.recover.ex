defmodule Mix.Tasks.Bitflyer.Recover do
  @moduledoc """
  `submission_unknown`（および ID 未埋込 pending）を取引所一覧から回収する。

  必ず `--dry-run` か `--confirm` のどちらか一方。
  操作者は `BITFLYER_RECOVER_OPERATOR`。confirm 時は dry-run の hash を `--hash` で渡す。

      BITFLYER_RECOVER_OPERATOR=alice mix bitflyer.recover --dry-run \\
        --internal-order-id=ord-1

      # 候補 1 件
      BITFLYER_RECOVER_OPERATOR=alice mix bitflyer.recover --confirm \\
        --internal-order-id=ord-1 --hash=<dry-run hash>

      # 候補複数（承認 ID 必須）
      BITFLYER_RECOVER_OPERATOR=alice mix bitflyer.recover --confirm \\
        --internal-order-id=ord-1 --hash=<hash> --exchange-order-id=JRF-...

      # 取引所に無いと確認済み（cancelled。hold は残す）
      BITFLYER_RECOVER_OPERATOR=alice mix bitflyer.recover --confirm \\
        --internal-order-id=ord-1 --hash=<hash> --absent

  Ready にはしない。続けて `mix bitflyer.resume`。
  """

  use Mix.Task

  @shortdoc "Recover submission_unknown via exchange child-order match"

  @impl Mix.Task
  def run(args) do
    {parsed, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          confirm: :boolean,
          hash: :string,
          internal_order_id: :string,
          exchange_order_id: :string,
          absent: :boolean,
          window_seconds: :integer
        ]
      )

    if invalid != [] do
      Mix.shell().error("invalid options: #{inspect(invalid)}")
      System.halt(1)
    end

    Mix.Task.run("app.start")

    opts = [
      dry_run?: Keyword.get(parsed, :dry_run, false),
      confirm?: Keyword.get(parsed, :confirm, false),
      expected_hash: Keyword.get(parsed, :hash),
      operator: System.get_env("BITFLYER_RECOVER_OPERATOR"),
      internal_order_id: Keyword.get(parsed, :internal_order_id),
      exchange_order_id: Keyword.get(parsed, :exchange_order_id),
      absent?: Keyword.get(parsed, :absent, false)
    ]

    opts =
      case Keyword.fetch(parsed, :window_seconds) do
        {:ok, seconds} -> Keyword.put(opts, :window_seconds, seconds)
        :error -> opts
      end

    case Bitflyer.System.recover_submission(opts) do
      {:ok, %{dry_run?: true} = preview} ->
        Mix.shell().info(format_preview(preview))
        Mix.shell().info(confirm_hint(preview))
        :ok

      {:ok, %{dry_run?: false, action: :bound} = result} ->
        Mix.shell().info(
          "recovery ok: bound exchange_order_id=#{result.exchange_order_id} " <>
            "internal_order_id=#{result.order.internal_order_id}; readiness NOT marked ready"
        )

        Mix.shell().info("Next: mix bitflyer.resume")
        :ok

      {:ok, %{dry_run?: false, action: :absent} = result} ->
        Mix.shell().info(
          "recovery ok: marked absent/cancelled internal_order_id=#{result.order.internal_order_id}; " <>
            "hold retained; readiness NOT marked ready"
        )

        Mix.shell().info("Next: mix bitflyer.resume")
        :ok

      {:error, :confirm_required} ->
        Mix.shell().error("recover failed: pass --dry-run or --confirm (exactly one)")
        System.halt(1)

      {:error, :ambiguous_mode} ->
        Mix.shell().error("recover failed: pass only one of --dry-run or --confirm")
        System.halt(1)

      {:error, :operator_required} ->
        Mix.shell().error("recover failed: set BITFLYER_RECOVER_OPERATOR")
        System.halt(1)

      {:error, :expected_hash_required} ->
        Mix.shell().error("recover failed: pass --hash=<dry-run snapshot_hash> with --confirm")
        System.halt(1)

      {:error, :internal_order_id_required} ->
        Mix.shell().error("recover failed: pass --internal-order-id=...")
        System.halt(1)

      {:error, :ambiguous_requires_id} ->
        Mix.shell().error(
          "recover failed: multiple candidates — pass --exchange-order-id=... with --confirm"
        )

        System.halt(1)

      {:error, reason, details} when is_map(details) ->
        Mix.shell().error("recover failed: #{inspect(reason)} #{inspect(details)}")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("recover failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp format_preview(preview) do
    ids =
      Enum.map_join(preview.candidates, ", ", fn c ->
        "#{c.exchange_order_id}(#{c.status})"
      end)

    "operator=#{preview.operator} internal_order_id=#{preview.order.internal_order_id} " <>
      "match=#{preview.match} hash=#{preview.snapshot_hash} " <>
      "window=#{preview.window_seconds}s candidates=[#{ids}]"
  end

  defp confirm_hint(%{match: :unique, snapshot_hash: hash, order: order}) do
    "unique match: mix bitflyer.recover --confirm --internal-order-id=#{order.internal_order_id} --hash=#{hash}"
  end

  defp confirm_hint(%{match: :ambiguous, snapshot_hash: hash, order: order}) do
    "ambiguous: pick ID then --confirm --internal-order-id=#{order.internal_order_id} " <>
      "--hash=#{hash} --exchange-order-id=<JRF-...>"
  end

  defp confirm_hint(%{match: :none, snapshot_hash: hash, order: order}) do
    "none: if confirmed absent on exchange, --confirm --internal-order-id=#{order.internal_order_id} " <>
      "--hash=#{hash} --absent"
  end
end
