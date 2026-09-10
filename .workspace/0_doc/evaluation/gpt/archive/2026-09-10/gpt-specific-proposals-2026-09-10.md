# docker-bitflyer 第2評価者 提案（2026-09-10）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

## 横断評価層 — テスト戦略

### モデルベース試験

- **注文状態機械のプロパティベーステスト** `0`
  > `pending → partially_filled → filled/cancelled/expired/submission_unknown` を状態機械として定義し、重複 fill、順不同応答、取消との競合、再起動を自動生成する。常に `0 <= filled_size <= size`、同じ execution の二重反映なし、unknown 後の再送なしを不変条件にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **実 API fixture の差分検知ジョブ** `0`
  > 承認付き・参照権限だけの定期 job で getbalance/getpositions/getchildorders の匿名化 schema を取得し、fixture と decoder の差分を通知する。実発注は行わず、API 仕様変更を live 切替前に検知する。
  >
  > 対象ファイル: `apps/bitflyer/test/fixtures/exchange/`, `.github/workflows/`

## 横断評価層 — 可観測性

### 運用ダッシュボード

- **注文ライフサイクルと資金保全 SLO の表示** `0`
  > StatusLive に建玉、未約定、submission_unknown、最終突合、日次損益、上限までの余裕、通知最終成功時刻を read-only で追加する。「発注可否」だけでなく「なぜ、いつから、どの注文で止まったか」を1画面で追えるようにする。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **外部 heartbeat と Game Day** `0`
  > Discord adapter から一定間隔の heartbeat を送り、外部監視側で欠落を検知する。四半期ごとに WS 断、DB 再起動、DNS 断、ディスク逼迫、SIGTERM、取引所 5xx を注入し、halt・通知・復帰時間を記録する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `.workspace/0_doc/architecture/env/prod.md`

## 横断評価層 — セキュリティ / supply chain

### 成果物保証

- **SBOM・署名・provenance の追加** `0`
  > GHCR image に SBOM と署名を付与し、本番PCで digest と署名を検証してから pull する。現状 CD は `provenance: false` なので、将来の本番運用では生成元の検証可能性を高められる。
  >
  > 対象ファイル: `.github/workflows/cd.yml`, `bin/deploy-prod.sh`

- **依存監査を重大度ベースのゲートへ段階移行** `0`
  > 現状の artifact 可視化を維持しつつ、critical/high advisory は fail、取得障害は明示的な運用判断を要求する段階へ進める。GitHub tag 依存は Renovate/Dependabot と手動 review を組み合わせる。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `mix.exs`

## プロジェクト全体設計

### 戦略運用

- **shadow strategy と段階的 live 解禁** `0`
  > 同じ ticker から「記録のみ」の shadow command を生成し、paper/live の判断差、risk 拒否率、想定 fill を比較する。live は参照のみ → shadow → 最小ロット1件 → 時間帯限定 → 通常上限の順に昇格し、各段階を設定 revision として記録する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `apps/bitflyer/lib/bitflyer/trading/`

### データ保全

- **定期 restore drill の自動検証** `0`
  > backup 作成だけでなく隔離 Compose へ復元し、migration、Resource 読み出し、reconcile dry-run までを自動化する。最新 backup の age と restore 成否を外部通知し、Recoverable を実測値にする。
  >
  > 対象ファイル: `bin/backup-db.sh`, `compose.prod.yaml`, `.github/workflows/`

**提案合計: 0**
