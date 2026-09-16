# Bitflyer（`apps/bitflyer`）

Umbrella の取引所連携・Domain・エンジン正本。UI は含めない（`apps/ui`）。

- Repo / Domain: `Bitflyer.Repo`、`Bitflyer.Trading`（Ash）
- 論理コンポ: market-data / strategy / risk / order-executor / observe
- 品質ゲート: ルートで `mix precommit`（`ash.codegen --check` 含む）

詳細はルート [README.md](../../README.md) と
[overview.md](../../.workspace/0_doc/architecture/overview.md)。
