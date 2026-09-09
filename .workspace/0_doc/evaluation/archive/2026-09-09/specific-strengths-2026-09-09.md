# プラス点の統合一覧 2026-09-09

根拠: [opus-specific-strengths](./opus/opus-specific-strengths-2026-09-09.md) / [gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-09.md)  
採用方針: コードで確認できた骨格・資金保全の質は Opus の厚い加点を採用しつつ、同一テーマの重複加点は統合して上限を抑える。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**加点合計: +62**

---

## 技術評価層 — apps/bitflyer

### TradeMode / Readiness / Circuit

- **live の三重ゲート（mode + 当日 UTC confirm + Ready）** `+4`
  > `exchange_order_gate/0` が fail-closed。`BITFLYER_LIVE_CONFIRM` は UTC 当日一致時のみ。書き残し live も翌日閉じる時限式。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trade_mode.ex`, `config/runtime.exs`
  > 採用: Opus `+5` を同テーマ重複抑制で `+4`（GPT は `+3`）

- **不正 TRADE_MODE を起動前に落とす** `+2`
  > `runtime.exs` で許可値以外 raise。`TradeMode` が正本。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

- **Readiness が単一正本・fail-closed・halted から Ready 直遷移不可** `+4`
  > ETS 消失時も `:not_ready`。`clear_halt` は `:not_ready` のみ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`

- **サーキット開閉が安全側順序** `+4`
  > 開く: メモリ halt → DB。閉じる: DB → clear。読取失敗も開いている扱い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

### risk / executor / datastore

- **fail-closed `Risk.authorize/2`（サイズ・建玉・鮮度・同期）** `+3`
  > 建玉読取失敗を空扱いにせず `:unsynced`。部分実装でも境界設計は正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **内部注文 ID の冪等性（DB unique + 競合フォールバック）** `+4`
  > create 失敗時に既存行を引き直し二重 REST を避ける。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **DryRun / Paper / Live の出口分離と paper 非送信** `+3`
  > モードで出口だけ切替。spy テストで REST 非呼び出しを固定。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/`

- **paper の Order+Position を同一 transaction + 行ロック** `+3`
  > コミット後 notify。Lost Update を意識。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `positions.ex`

- **Order / Position / BalanceSnapshot / RiskState を Decimal で永続化** `+3`
  > Ash は永続、ETS は hot path。Repo は bitflyer 所有。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`

### market-data / cache / exchange 既定

- **再接続・再購読・REST 穴埋め・stale → risk 拒否** `+3`
  > gap-fill が新しい WS tick を踏み潰さない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `cache.ex`

- **既定 exchange が Unavailable（未実装は安全側）** `+3`
  > 実 client 無しでは live 突合・発注が物理的に失敗する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/unavailable.ex`, `config/config.exs`

### 起動突合 / OTP / observe

- **モード別突合と不整合時の永続 halt** `+3`
  > dry_run/paper は内部正。live のみ取引所 snapshot。既存 halt は自動解除しない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `reconciler.ex`

- **exchange_order_id 無しの未確定注文を無条件 mismatch** `+2`
  > 送信中クラッシュ後の Ready 防止。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **取引監督と UI Application の兄弟分離** `+1`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

- **telemetry 語彙と metadata allowlist** `+2`
  > 秘密らしき key を通さない。LiveDashboard 連携。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

---

## 技術評価層 — apps/ui

- **StatusLive が Bitflyer.System 経由のみ・裁量 UI に踏み込まない** `+2`
  > Ready / halt reason / DB / mode を DOM ID・テスト付きで表示。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **`GET /health` が DB・halt で 200/503、エラー詳細を出さない** `+2`
  > Compose healthcheck も同 path。
  > 対象ファイル: `apps/ui/lib/ui_web/controllers/health_controller.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **ルート `mix precommit`（副作用なし）と GitHub Actions CI** `+3`
  > format check / warnings-as-errors / test。PostgreSQL service。本番シークレットなし。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

- **テスト DB 分離と Compose MIX_ENV 衝突解消** `+2`
  > `TEST_DATABASE_URL` / `_test` 置換。文書どおりの precommit が通る。
  > 対象ファイル: `config/runtime.exs`, `compose.yaml`

- **開発 Compose の安全な既定（localhost publish・restart・dry_run・`.dockerignore`）** `+2`
  > 対象ファイル: `compose.yaml`, `.dockerignore`, `bin/docker-entrypoint.sh`

---

## 横断評価層

- **資金保全回帰テスト（非送信・冪等・boot halt・risk 拒否）** `+4`
  > SpyExchange で呼び出し回数 0 を積極証明。`config/test.exs` で実ネット禁止。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`
  > 採用: Opus `+5` を重複抑制で `+4`（GPT `+3`）

- **ui → bitflyer 一方向依存と第3アプリ非分割** `+1`
  > Architecture 方針を維持。

- **Vision / Architecture と実装の接続、P0–P2 の自己改善サイクル** `+2`
  > 前回指摘のゲート・安全枠・engine 骨が短期間でコード化された。

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer | +44 |
| apps/ui | +4 |
| 実行基盤 / 設定 | +7 |
| 横断 | +7 |
| **合計** | **+62** |
