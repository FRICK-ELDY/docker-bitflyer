defmodule DockerBitflyer.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp aliases do
    [
      # Umbrella ルートには :app が無いため、Repo 解決に domains を明示する
      setup: ["deps.get", "ash.setup --domains Bitflyer.System"],
      # 副作用なしの品質ゲート（ローカル / CI 共通）。両アプリを検査する
      precommit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "compile --warnings-as-errors",
        # test/ は compile 対象外のため、こちらでも warnings-as-errors にする
        "test --warnings-as-errors"
      ]
    ]
  end
end
