defmodule Bitflyer.Release do
  @moduledoc """
  mix 無しの本番 release 向けタスク（migrate / resume / baseline import）。

  Docker 例:

      bin/docker_bitflyer eval "Bitflyer.Release.migrate()"
      bin/docker_bitflyer rpc "Bitflyer.Release.resume()"
      bin/docker_bitflyer rpc "Bitflyer.Release.import_baseline(dry_run: true, operator: \\"alice\\")"
      bin/docker_bitflyer rpc "Bitflyer.Release.import_baseline(confirm: true, operator: \\"alice\\", expected_hash: \\"<hash>\\")"
  """

  @app :bitflyer

  @doc """
  Ecto マイグレーションをすべて適用する。起動前に entrypoint から呼ぶ。
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  マイグレーション状態を表示する（運用確認用）。
  """
  def migration_status do
    load_app()

    for repo <- repos() do
      {:ok, migrations, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.migrations/1)

      IO.puts("Repo: #{inspect(repo)}")
      IO.inspect(migrations, label: "migrations")
    end

    :ok
  end

  @doc """
  再突合成功時のみ halt を解除する（`mix bitflyer.resume` 相当）。
  常駐 BEAM 上で実行すること（別プロセスの eval だけでは ETS が残る）。
  """
  def resume(opts \\ []) do
    case Bitflyer.System.resume(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "resume failed: #{inspect(reason)}"
    end
  end

  @doc """
  live 初回 BalanceSnapshot baseline を取り込む（`mix bitflyer.baseline` 相当）。

  - `dry_run: true` — preview のみ
  - `confirm: true` — 書き込み（Ready にはしない）
  - `operator:` — 必須
  - `expected_hash:` — confirm 必須（dry-run の snapshot_hash）

  常駐 BEAM 上で RPC すること。
  """
  def import_baseline(opts \\ []) do
    normalized =
      opts
      |> Keyword.put(:dry_run?, Keyword.get(opts, :dry_run, Keyword.get(opts, :dry_run?, false)))
      |> Keyword.put(:confirm?, Keyword.get(opts, :confirm, Keyword.get(opts, :confirm?, false)))
      |> Keyword.put_new(:expected_hash, Keyword.get(opts, :hash))
      |> Keyword.drop([:dry_run, :confirm, :hash])

    case Bitflyer.System.import_baseline(normalized) do
      {:ok, result} ->
        result

      {:error, reason, details} when is_map(details) ->
        raise "baseline import failed: #{inspect(reason)} #{inspect(details)}"

      {:error, reason} ->
        raise "baseline import failed: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
