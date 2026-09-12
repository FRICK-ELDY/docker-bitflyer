# docker-bitflyer 第2評価者 提案（2026-09-12）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点を批判せず、実装すれば価値が上がる提案 |

## 技術評価層 — apps/bitflyer

### market-data / strategy

- **板 snapshot＋差分整合と流動性ゲート** `0`
  > ticker LTP だけでなく board sequence、spread、上位板厚、取引所 board state を read-only Risk 入力にすれば、薄板・異常 spread・取引所 BUSY 時の成行を止められる。戦略高度化より安全ゲートとして先行するとよい。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **戦略 revision の承認ワークフローと canary 有効化** `0`
  > immutable revision と注文 provenance は揃った。次は作成者と承認者を分け、最大注文数・最大稼働時間・最小ロットを revision 単位で段階有効化できると、設定変更の live リスクを下げられる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### risk / order-executor

- **資金状態機械のモデルベース・プロパティ試験** `0`
  > hold、partial fill、fee、cancel、submission_unknown、reconcile、再起動の command sequence を生成し、「利用可能額が過大にならない」「execution は二度反映されない」「unknown 中は発注不可」を不変条件として検査すると、例示試験で見落とす順序依存を発見しやすい。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/risk/`, `apps/bitflyer/test/bitflyer/order_executor/`

## 技術評価層 — observe / apps/ui

### 可観測性

- **資金保全 SLO と外部時系列ダッシュボード** `0`
  > ready率、Feed 再接続時間、reconcile mismatch、submission_unknown、open age、損失headroom、通知成功率を低カーディナリティで外部保存し、SLOとページ条件を定義する。LiveDashboard はOTP診断、Statusは現在値、外部基盤は率・推移と役割分担できる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/telemetry.ex`

- **高危険操作の任意二者承認** `0`
  > kill は単独即時のまま維持し、resume、live strategy 有効化、baseline/re-baseline、ambiguous recovery だけを短時間の二者承認にすると誤操作耐性が上がる。監査行には実行者と承認者を分けて残す。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`

## 技術評価層 — 実行基盤 / 横断評価

### 復旧 / セキュリティ

- **隔離環境への定期 restore Game Day** `0`
  > backup を別 volume/DB へ自動 restore し、not-ready→reconcile→ready、WS断、DB断、unknown 回収、SIGTERM drain を演習してRTO/RPOを記録する。バックアップファイルの存在を復旧可能性の実測へ進められる。
  >
  > 対象ファイル: `bin/backup-db.sh`, `bin/deploy-prod.sh`, `.workspace/0_doc/architecture/env/prod.md`

- **SBOM・署名・デプロイ時検証** `0`
  > digest 固定に加え、CycloneDX/SPDX SBOM、コンテナ署名、provenance、デプロイ側の署名検証を追加すれば、Hex・GitHub・OS依存を含む成果物の supply-chain 証跡が閉じる。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `Dockerfile.prod`

**提案件数: 7件**
