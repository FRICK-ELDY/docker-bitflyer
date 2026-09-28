# docker-bitflyer 第2評価者 提案（2026-09-29）

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点の必須欠陥ではないが、実装すれば価値を高める提案 |

## 長期運用

### データと復旧

- **Fill / BalanceSnapshot の保持・集約方針** `0`
  > 監査用の生データ保持期間、日次 aggregate、DB 容量閾値、VACUUM 判断を明文化すると、24/365 での読取・再起動コストを予測できる。正しさの現行欠陥ではないため提案扱いとする。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **隔離環境への定期 restore ドリル** `0`
  > backup hash、空 DB、restore、migration、boot/reconcile の結果を自動記録すると Recoverable を手順から実績へ引き上げられる。本番 DB を壊さない隔離 Compose project で定期実行する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `bin/backup-db.sh`

### 可観測性

- **Prometheus と SLO の時系列化** `0`
  > 現行 telemetry / ConsoleReporter を exporter へ接続し、Ready 率、再接続率、拒否率、突合失敗率、heartbeat 欠落をホスト外へ保持する。カーディナリティ上限と保持期間も同時に定義する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/telemetry.ex`

**小計: 3件 / 0点**

## Supply chain / 実行環境

### 依存・イメージ

- **release image と Git 依存の脆弱性 scanner** `0`
  > Hex advisory に加え、ベース image・OS package・Git 依存を Trivy / Grype / OSV 等で検査し、high / critical の例外に期限を持たせる。SBOM と image digest を同じ成果物に残すと追跡しやすい。
  > 対象ファイル: `.github/workflows/ci.yml`, `Dockerfile.prod`

- **開発コンテナの非 root 化** `0`
  > 本番 runner は非 root だが開発 Dockerfile は root のままである（`Dockerfile:1-20`）。固定 UID/GID と bind mount の所有権を整えると、開発生成物とホスト侵害時の権限を抑えられる。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **WebSocket client の採用理由と移行条件の記録** `0`
  > 現行 socket adapter の運用実績、再接続責務、依存更新方針を ADR にし、websockex 等へ移る条件を固定する。現行 Feed の安全性を否定する指摘ではなく、複数サイクルの保守判断を残す提案である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `mix.lock`

**小計: 3件 / 0点**

## 取引完成度

### 検証と戦略

- **金額・数量・冪等キーの property / model-based test** `0`
  > Decimal 境界、部分約定列、手数料、hold 解放、同一 internal ID の操作列を生成し、「残高を増やさない」「二重 REST しない」「HWM は下がらない」を不変条件として検証すると、例示回帰の外側を補える。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`, `apps/bitflyer/test/bitflyer/order_executor_test.exs`

- **承認済み live 戦略の canary 契約** `0`
  > FixedOnce を禁止する現在の安全既定を維持しつつ、live-approved strategy に revision、最大1注文、時間帯、dry-run shadow、rollback 条件を持たせる。利益機能の拡張なので live 安全条件より後でよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **private execution WS と API レート予算** `0`
  > REST fill 同期を正本のまま、private execution WS を早期通知として加え、REST paging・ticker・残高・権限検査のレート予算を文書化すると、約定反映遅延とレート制限時の挙動を予測しやすい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

**小計: 3件 / 0点**

## 合計

**提案合計: 9件 / 0点**
