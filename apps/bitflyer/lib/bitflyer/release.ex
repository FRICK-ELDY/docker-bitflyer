defmodule Bitflyer.Release do
  @moduledoc """
  mix 無しの本番 release 向けタスク（migrate / resume）。

  Docker 例:

      bin/docker_bitflyer eval "Bitflyer.Release.migrate()"
      bin/docker_bitflyer rpc "Bitflyer.Release.resume()"
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
