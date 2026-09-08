# マイナス点統合一覧 2026-09-08

初回評価。第1評価者（Opus）と第2評価者（GPT）の独立評価を統合。
詳細の正本: [opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-08.md) / [gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

採点欄の `採用` はまとめが採用した点数。`Opus` / `GPT` は各評価者の点数（未計上は `—`）。

---

## 技術評価層 — apps/bitflyer

### 取引ドメインの中核

- **risk-manager（Safety first の執行主体）が未実装** `-5`（採用） / Opus: コンポーネント一括 `-4` に含む / GPT: `-5`
  > Vision が必須とするサイズ・損失・頻度・異常値超過時の停止をコードで説明できない。骨格 ToDo 完了後の計画的未着手ではあるが、資金保全原則の欠如として最重く扱う。
  > 改善方針: fail-closed の単一 `authorize/2` 境界とサーキット永続化を、strategy より先に置く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **冪等な order-executor と dry_run / paper / live 出口が未実装** `-5`（採用） / Opus: 一括 `-4` に含む / GPT: `-5`
  > `TRADE_MODE` は表示専用。内部注文 ID・取引所突合・モード別アダプタが無く、Idempotent actions を検証できない。
  > 改善方針: 内部注文 ID の一意制約 + DryRun / Paper / Live アダプタ。paper / dry_run が発注 REST を呼ばない契約テストを先に固定する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `config/runtime.exs`

- **market-data（購読・再接続・鮮度）が未実装** `-4`（採用） / Opus: 一括 `-4` に含む / GPT: `-4`
  > 「古いデータでは発注しない」ゲートの入力が存在しない。
  > 改善方針: Req REST + WebSocket、受信時刻付きイベントを ETS へ、stale を risk 拒否理由へ直結。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **復旧に必要な永続状態が Heartbeat 以外にない** `-4`（採用） / Opus: `-3` / GPT: `-4`
  > Order / Position / BalanceSnapshot / RiskState / パラメータ履歴が無く Recoverable を検証不能。
  > 改善方針: 発注コードより先に Decimal 型の Resource と一意制約を置く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`, `apps/bitflyer/priv/repo/migrations/`

- **起動シーケンス（復元 → 突合 → 不整合なら停止 → Ready）が未実装** `-4`（採用） / Opus: `-3` / GPT: `-4`（observe/OTP に含む）
  > Application の子は `Bitflyer.Repo` のみ。Ready / halted の概念がコードに無い。
  > 改善方針: boot state machine を監督し、Ready 以外では executor が必ず拒否する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `bin/docker-entrypoint.sh`

- **鮮度付き ETS cache が未実装** `-3`（採用） / Opus: 提案寄りに分離 / GPT: `-3`
  > 市場データの age / stale / 再構築経路が無い。Safety 直結のため減点を採用。
  > 改善方針: ETS owner プロセスと `fresh?/2` を先に置く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **strategy の内部コマンド境界が未定義** `-2`（採用） / Opus: 一括に含む / GPT: `-2`
  > 「買いたい / 売りたい / 閉じたい」への変換境界を検証できない。戦略内容自体は後続でよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer.ex`

- **TRADE_MODE の値検証と live 解禁条件がない** `-3`（採用） / Opus: `-1` / GPT: `-3`
  > 任意文字列が素通りし、live 時の key・上限・同期完了チェックが無い。誤操作リスクとして GPT の厳しさを採用。
  > 改善方針: 許可値以外は起動停止。live は二重明示設定 + Ready 完了まで halted。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/system.ex`

- **グレースフルシャットダウン経路がない** `-1`（採用） / Opus: `-1` / GPT: 起動シーケンスに含む
  > 現状実害は小さいが executor 追加前に枠が必要。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`

---

## 技術評価層 — apps/ui

- **「今トレードしてよいか」と停止理由が分からない** `-2`（採用） / Opus: `-2` / GPT: `-2`
  > StatusLive は mode と DB 接続のみ。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **本番 UI が全インターフェース bind・認証なし** `-3`（採用） / Opus: `-2` / GPT: `-3`
  > 開発は localhost 限定だが prod は wildcard。VLAN 越え監視を想定する以上、多層防御が必要。
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/router.ex`

- **Phoenix 生成物の残骸（マーケ導線・未使用 PageController 等）** `-1`（採用） / Opus: `-1` / GPT: —
  > 運用画面の一等地を占有する。
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **healthcheck が readiness を判定しない** `-3`（採用） / Opus: `-2` / GPT: `-3`
  > `/` の 200 のみ。DB 断でも healthy。
  > 対象ファイル: `compose.yaml`, `apps/ui/lib/ui_web/live/status_live.ex`

- **本番 release / Compose / 復旧運用がない** `-3`（採用） / Opus: `-3` / GPT: `-3`
  > Dockerfile は開発専用。24/365 の実行手段が無い。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **テスト DB が開発 DB を共有** `-2`（採用） / Opus: `-2` / GPT: —
  > `MIX_ENV=test` でも `docker_bitflyer_dev`。Sandbox 外テストで破壊リスク。
  > 対象ファイル: `config/runtime.exs`, `.env.example`

- **`.dockerignore` 不在** `-1`（採用） / Opus: `-1` / GPT: —
  > 将来の `COPY` 時に秘密混入リスク。
  > 対象ファイル: リポジトリルート

- **開発コンテナが root 実行** `-1`（採用） / Opus: `-1` / GPT: —
  > 対象ファイル: `Dockerfile`

---

## 技術評価層 — CI / CD

- **`.github/workflows/` が存在せず自動品質ゲートがゼロ** `-3`（採用） / Opus: `-3` / GPT: precommit と合算 `-3`
  > PR 運用なのに format / compile / test が自動化されていない。
  > 対象ファイル: `.github/workflows/`（不在）

- **ルート `mix precommit` が未整備で bitflyer を素通りし、標準コマンドが失敗する** `-3`（採用） / Opus: `-3`+`-2`+`-2` / GPT: `-3`
  > 実測: `docker compose run --rm app mix precommit` は `MIX_ENV=dev` により `UiWeb.ConnCase` 未ロードで失敗。`MIX_ENV=test` 明示時も ui の 6 tests のみ。alias は副作用のある `format`。
  > 改善方針: ルートに副作用なし alias + `preferred_envs`、compose の MIX_ENV 固定を見直す、CI から同じ alias を呼ぶ。
  > 対象ファイル: `mix.exs`, `apps/ui/mix.exs`, `compose.yaml`

---

## 横断評価層

- **資金保全経路の回帰テストが皆無** `-5`（採用） / Opus: `-3`+`-2`+`-1` / GPT: `-5`
  > 全テストは hello / エラーページ / Status DOM ID 程度。冪等・mode・risk・stale・突合なし。
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`

- **取引イベントの可観測性がない** `-3`（採用） / Opus: `-2`+`-1` / GPT: `-3`
  > bitflyer に Logger / telemetry なし。人に届くアラート経路も未着手。
  > 対象ファイル: `apps/bitflyer/lib/`, `apps/ui/lib/ui_web/telemetry.ex`

- **「不整合なら Ready にしない」ゲートがコードに無い** `-2`（採用） / Opus: `-2` / GPT: 起動シーケンスに含む
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **取引完成度が 0%（縦貫通経路なし）** `-4`（採用） / Opus: `-4`+`-2` / GPT: bitflyer 各欠如に分散
  > 起動 → SELECT 1 までしか通らない。bitflyer に `:req` すら無い。
  > 対象ファイル: `apps/bitflyer/`

- **README が完成済み骨格と乖離・リンク切れ** `-2`（採用） / Opus: `-2` / GPT: `-2`
  > 対象ファイル: `README.md`

- **設計文書と実装の隔たり・完成度表示が曖昧** `-2`（採用） / Opus: 文書間リンク `-1`+backlog 残留 `-1` / GPT: `-2`
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `README.md`, `.workspace/1_backlog/`

- **依存脆弱性の自動検査がない** `-1`（採用） / Opus: `-1` / GPT: `-1`
  > 対象ファイル: `mix.exs`, `.github/`

- **bitFlyer API キーの環境変数名が未定義** `-1`（採用） / Opus: `-1` / GPT: —
  > 対象ファイル: `.env.example`

- **生成テンプレ（hello / アプリ README）が残存** `-1`（採用） / Opus: `-1` / GPT: —
  > 対象ファイル: `apps/bitflyer/lib/bitflyer.ex`

---

## 小計（採用）

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer | -31 |
| apps/ui | -6 |
| 実行基盤 / 設定 | -10 |
| CI / CD | -6 |
| 横断評価層 | -21 |
| **合計** | **-74** |

### 評価者間の主な相違

| 論点 | Opus | GPT | まとめの判断 |
|:---|:---|:---|:---|
| 未実装 engine の扱い | 一括 -4 + 周辺 | risk/executor を各 -5 | **GPT 寄り**（資金保全優先） |
| TRADE_MODE 無検証 | -1 | -3 | **GPT 寄り**（live 文字列が先にある危険） |
| 文書・Compose の作り込みを減点で相殺するか | 横断で細かく減点 | 実装欠如を重く | 両方採用し項目を統合 |
| テスト DB 共有 / .dockerignore | 減点 | 未計上または提案 | **Opus を採用**（実測根拠あり） |
