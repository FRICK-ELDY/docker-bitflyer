defmodule Mix.Tasks.Bitflyer.Baseline do
  @moduledoc """
  live 初回の BalanceSnapshot baseline を取引所から取り込む。

  必ず `--dry-run` か `--confirm` のどちらか一方を付ける。
  操作者は環境変数 `BITFLYER_BASELINE_OPERATOR`（必須）。
  confirm 時は dry-run で表示された hash を `--hash` で渡す（見た金額の承認）。

      BITFLYER_BASELINE_OPERATOR=alice mix bitflyer.baseline --dry-run
      BITFLYER_BASELINE_OPERATOR=alice mix bitflyer.baseline --confirm --hash=<dry-run hash>

  既存 tip を取引所残高で上書きするときは `--rebaseline`（初期化とは別経路）:

      BITFLYER_BASELINE_OPERATOR=alice mix bitflyer.baseline --rebaseline --dry-run
      BITFLYER_BASELINE_OPERATOR=alice mix bitflyer.baseline --rebaseline --confirm --hash=<dry-run hash>

  confirm しても Ready にはしない。続いて起動突合または `mix bitflyer.resume`
  が成功したときだけ Ready になる。通常 import は必須通貨のうち tip が無いものだけを書く。
  """

  use Mix.Task

  @shortdoc "Import live balance baseline (approved dry-run/confirm)"

  @impl Mix.Task
  def run(args) do
    {parsed, _argv, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, confirm: :boolean, hash: :string, rebaseline: :boolean],
        aliases: []
      )

    if invalid != [] do
      Mix.shell().error("invalid options: #{inspect(invalid)}")
      System.halt(1)
    end

    Mix.Task.run("app.start")

    operator = System.get_env("BITFLYER_BASELINE_OPERATOR")

    opts = [
      dry_run?: Keyword.get(parsed, :dry_run, false),
      confirm?: Keyword.get(parsed, :confirm, false),
      rebaseline?: Keyword.get(parsed, :rebaseline, false),
      expected_hash: Keyword.get(parsed, :hash),
      operator: operator
    ]

    case Bitflyer.System.import_baseline(opts) do
      {:ok, %{dry_run?: true} = preview} ->
        Mix.shell().info(format_preview(preview))
        Mix.shell().info("dry-run only: no BalanceSnapshot written; readiness unchanged")

        Mix.shell().info("To confirm this exact snapshot: #{confirm_command(preview)}")

        :ok

      {:ok, %{dry_run?: false} = result} ->
        Mix.shell().info(format_preview(result))

        Mix.shell().info(
          "#{persist_label(result)} ok: snapshots written; readiness NOT marked ready"
        )

        Mix.shell().info(
          "Next: boot reconcile or mix bitflyer.resume after exchange matches baseline."
        )

        :ok

      {:error, :confirm_required} ->
        Mix.shell().error("baseline failed: pass --dry-run or --confirm (exactly one)")
        System.halt(1)

      {:error, :ambiguous_mode} ->
        Mix.shell().error("baseline failed: pass only one of --dry-run or --confirm")
        System.halt(1)

      {:error, :operator_required} ->
        Mix.shell().error("baseline failed: set BITFLYER_BASELINE_OPERATOR")
        System.halt(1)

      {:error, :expected_hash_required} ->
        Mix.shell().error("baseline failed: pass --hash=<dry-run snapshot_hash> with --confirm")
        System.halt(1)

      {:error, reason, details} when is_map(details) ->
        Mix.shell().error("baseline failed: #{inspect(reason)} #{inspect(details)}")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("baseline failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp format_preview(preview) do
    rows =
      Enum.map_join(preview.balances, ", ", fn row ->
        "#{row.currency}=#{Decimal.to_string(row.amount, :normal)}/" <>
          Decimal.to_string(row.available, :normal)
      end)

    kind = if Map.get(preview, :rebaseline?), do: "rebaseline", else: "import"

    "kind=#{kind} operator=#{preview.operator} trade_mode=#{preview.trade_mode} " <>
      "hash=#{preview.snapshot_hash} balances=[#{rows}]"
  end

  defp confirm_command(%{rebaseline?: true, snapshot_hash: hash}) do
    "mix bitflyer.baseline --rebaseline --confirm --hash=#{hash}"
  end

  defp confirm_command(%{snapshot_hash: hash}) do
    "mix bitflyer.baseline --confirm --hash=#{hash}"
  end

  defp persist_label(%{rebaseline?: true}), do: "baseline rebaseline"
  defp persist_label(_), do: "baseline import"
end
