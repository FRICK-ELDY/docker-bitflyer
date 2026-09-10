# docker-bitflyer 第2評価者 提案（2026-09-10_2）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

## 技術評価層 — apps/bitflyer

### market-data / strategy

- **板スナップショット＋差分整合と流動性ゲート** `0`
  > ticker LTP だけでなく board snapshot の sequence、差分適用、spread、上位板厚を持てば、価格乖離だけでは防げない薄板・異常 spread 時の注文を止められる。まずは Risk 入力として read-only に追加し、戦略高度化より安全ゲートを先行させる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **戦略 revision の承認ワークフローと canary 有効化** `0`
  > immutable 履歴は揃った。次は revision を作成・承認・段階有効化し、最大注文数や稼働時間を canary 制限できると、設定変更が即全量 live へ反映される運用リスクを下げられる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### risk / order-executor

- **リスク状態機械のモデルベース試験** `0`
  > AuthorizedOrder、hold、partial fill、cancel、submission_unknown、reconcile は相互作用が多い。StreamData 等で command sequence を生成し、「利用可能額は増えすぎない」「同じ execution は二度反映しない」「unknown 中は新規発注不可」を不変条件として検査すると、例示テストでは見落とす順序依存を発見しやすい。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/risk/`, `apps/bitflyer/test/bitflyer/order_executor/`

- **Execution 正本と取引所 execution ID の一意制約** `0`
  > Fill に `exchange_execution_id` 欄はあるが live 反映では nil のままである。取引所 execution を1件ずつ保存し `(trade_mode, exchange_execution_id)` を一意にすれば、累積値差分より直接的な冪等性と監査証跡を得られる。今回の累積平均価格バグもこのモデルで避けやすい。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

## 技術評価層 — observe / apps/ui

### 可観測性

- **SLO と資金保全ダッシュボード** `0`
  > ready 率、Feed 再接続時間、reconcile mismatch、submission_unknown、open order age、日次損失／証拠金余力を時系列で保存し、SLO と閾値を定義する。LiveDashboard は診断用に残し、長期傾向とページングは外部監視へ分離する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/telemetry.ex`

- **二者承認を要する高危険操作** `0`
  > kill は単独で即時実行のままがよい。一方 resume、live strategy 有効化、baseline、ambiguous recovery は、別資格情報または短時間の二者承認を任意で要求できると誤操作耐性が上がる。監査ログには操作者と承認者を分けて残す。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`

## 技術評価層 — 実行基盤 / 横断評価

### セキュリティ / 運用

- **SBOM・署名・検証付き release 配布** `0`
  > GHCR digest 固定に加え、CycloneDX/SPDX SBOM、cosign keyless 署名、デプロイ側の署名検証を追加すれば、依存と成果物の supply-chain 証跡が閉じる。provenance を無効にしている現状から段階導入する。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `Dockerfile.prod`

- **隔離環境での自動 restore / Game Day** `0`
  > backup script の存在だけでなく、定期的に別 volume へ restore し、起動後に not-ready→reconcile→ready、unknown 回収、WS断、DB断、SIGTERM drain を演習する。RTO/RPO と手動判断点を計測値として残す。
  >
  > 対象ファイル: `bin/backup-db.sh`, `bin/deploy-prod.sh`, `.workspace/0_doc/architecture/env/prod.md`

**提案合計: 0**
