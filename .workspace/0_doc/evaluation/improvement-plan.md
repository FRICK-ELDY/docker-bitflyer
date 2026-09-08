# 改善提案書（improvement-plan）

最終更新: 2026-09-08  
根拠: [evaluation-2026-09-08.md](./evaluation-2026-09-08.md) / [specific-weaknesses-2026-09-08.md](./specific-weaknesses-2026-09-08.md)

方針: **利益機能より資金保全・品質ゲート・復帰経路を先に直す。** 戦略の中身は縦貫通の後。

---

## P0 — 今すぐ（engine より先）

品質ゲートが壊れたまま発注ロジックを書くと、「緑なのに壊れている」を固定する。

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | ルート `mix precommit` | `mix.exs` に `preferred_envs: [precommit: :test]` と副作用なし alias（`format --check-formatted` / `compile --warnings-as-errors` / `test`）。ui 側の重複・`format` 書き換えをやめる | `docker compose run --rm -e MIX_ENV=test app mix precommit` が両アプリを検査して緑 |
| 2 | Compose の MIX_ENV 衝突 | `compose.yaml` の固定 `MIX_ENV=dev` を見直し、文書どおりのコマンドが通る形にする | 文書化した 1 コマンドが exit 0 |
| 3 | GitHub Actions CI | ToDo 02 どおり。Elixir 1.18 / OTP 27、PostgreSQL service、本番シークレットなし | PR で format/compile/test が自動実行 |
| 4 | README 同期 | 骨格完了を反映。アーカイブへのリンク修正。起動・ゲートコマンドを実測どおりに | 新規参加者が README だけで `compose up` とゲートに到達 |
| 5 | テスト DB 分離 | `runtime.exs` の test で `_test` DB（または `TEST_DATABASE_URL`） | `MIX_ENV=test` で `docker_bitflyer_dev` を触らない |

---

## P1 — 安全の枠（発注の前に置く骨）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 6 | `TradeMode` 型と live 解禁条件 | 許可値以外は起動停止。live は二重明示 + Ready 完了まで halted | 不正 `TRADE_MODE` で起動失敗。live 単独では発注不可 |
| 7 | Readiness 状態機械 | `:not_ready` / `:ready` / `{:halted, reason}` を単一の正本に | UI・将来の executor・health が同じ状態を読む |
| 8 | `GET /health` | DB + readiness で 200/503。compose healthcheck を切替 | DB 断で unhealthy |
| 9 | telemetry / 構造化ログ語彙 | イベント名を先に定数化。秘密は allowlist 外 | LiveDashboard またはログで語彙が見える |
| 10 | `.dockerignore` | 本番 Dockerfile より先 | ビルドコンテキストに `.env` / `_build` が入らない |

---

## P2 — Recoverable / Safety / Idempotent の実装

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | 永続 Resource | Order / Position / BalanceSnapshot / RiskState（Decimal・内部注文 ID 一意） | マイグレーションと Ash Resource が存在 |
| 12 | Boot reconcile | 復元 → 突合 → 不整合なら Ready にしない | 不整合時は halted のまま UI に理由が出る |
| 13 | ETS 鮮度 cache | `{value, received_at}` + `fresh?/2` | stale を risk が拒否できる |
| 14 | risk-manager | fail-closed `authorize/2`、サーキット永続化 | 上限超過・stale・未同期は必ず拒否 |
| 15 | order-executor | DryRun / Paper / Live 出口。冪等キー | paper/dry_run が発注 REST を呼ばないテストが緑 |
| 16 | market-data | REST + WebSocket、再接続、穴埋め | 切断後に再購読し、古いデータで発注しない |
| 17 | 資金保全の回帰テスト | 重複 intent、mode 分離、boot halt、risk 拒否 | CI で必須 |

---

## P3 — 運用として回す

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 18 | StatusLive の発注可否表示 | readiness / halt reason / 鮮度 / モード色分け | 「今トレードしてよいか」が 1 秒で分かる |
| 19 | UI 認証・本番 bind | BasicAuth 等 + 公開面最小化。ToDo 03 に明記 | 認証なしで取引詳細を見られない |
| 20 | Discord 通知アダプタ | 発注経路から独立。失敗しても取引を止めない | 起動/停止/halt が人に届く |
| 21 | 本番 release Compose | `mix release`、digest 固定、backup/rollback 文書 | 実弾なしで一度上げられる |
| 22 | deps audit | CI に可視化（最初は fail させなくてもよい） | 既知脆弱性が一覧できる |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化
- プロパティ / モデルベーステストの本格導入
- paper Game Day、SBOM / 署名、SLO 数値の精緻化
- 裁量向け UI、複数取引所、ML 基盤

---

## 既存 ToDo との対応

| 改善 | 既存文書 |
|:---|:---|
| P0 #1–3 | `.workspace/3_archive/02-ci-github-actions.md` |
| P3 #21 | `.workspace/2_todo/03-cd-prod-host.md` |
| P2 #15（paper） | `.workspace/1_backlog/paper-trade-adapter.md` |
| P3 #20 | `.workspace/1_backlog/discord-notify-adapter.md` |

次回評価では、本計画の P0 / P1 がコード上で解決済みかを対象ファイルの再読で確認する。
