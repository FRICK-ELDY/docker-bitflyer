# プラス点（統合）2026-09-29

対象コミット: `afc46bb`
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)
第1評価者: [opus-specific-strengths-2026-09-29.md](./opus/opus-specific-strengths-2026-09-29.md)
第2評価者: [gpt-specific-strengths-2026-09-29.md](./gpt/gpt-specific-strengths-2026-09-29.md)

同じ設計は 1 回だけ数える。点数は、両方の根拠をまとめたうえで、より説明できる側を採用した。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +69 点**

---

## 技術評価層 — apps/bitflyer

### 手数料会計

- **売買それぞれの実約定で手数料式を固定した** `+5`
  > 両者一致。2026-09-28 の買い execution …6098 と売り …6123 の実差分が、base 手数料式と JPY 1 円・BTC 1 satoshi 以内で一致し、旧売り式は許容外と証跡にある。回帰は同じ数値で `explain` を通す。Opus の `+5` を採用する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`, `apps/bitflyer/test/bitflyer/startup/live_balance_test.exs`

- **全量売りを公表上限 0.15% の余白で先に拒む** `+3`
  > Opus。spot の売り拘束は `size + size × 0.0015` で、約定前の実 commission が無いぶん不足側に倒す（`product.ex` L69-97）。実測の不足を認可へ翻訳している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`

### market-data / risk

- **Feed は ACK と鮮度で閉じ、ticker は LTP と板を分けた** `+4`
  > GPT の Feed `+4` と Opus の ticker 2 層 `+3` は同じ境界。未 ACK・切断・stall は再接続へ行き、crossed や欠落の板は `book: nil` のまま LTP を残す。成行だけが `bid_ask_missing` で止まる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **発注前検査を一つの認可境界に集約した** `+4`
  > GPT。鮮度、時計、サイズ、在庫、spread、頻度、日次損失、残高 probe を通り、未同期は fail-closed。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **HWM はホットパスの外で書き、低い後着で peak を下げない** `+4`
  > Opus の write-behind `+4` と GREATEST `+3`、GPT の write-behind `+3` を 1 件にまとめた。受理までを待ち、pending は成功まで捨てず、upsert は `ON CONFLICT ... GREATEST` の 1 文である。強制終了の残窓は減点側に分けた。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **drain 失敗の停止を Postgres の外へ fsync し、次回起動が読む** `+4`
  > Opus。DB へ書けない停止をローカル印に残し、起動時に RiskState へ戻す（`drain_halt.ex` の書き込みと復元）。DB 障害とメモリ消失を同じ箱に入れていない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/drain_halt.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **live 成行買いの拘束を best ask × size にした** `+2`
  > Opus。paper は LTP のまま手数料を二重に載せない。板厚の超過は拘束しないとコメントがあり、その残差は減点側にある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

### order-executor / 起動

- **認可トークンが Risk を迂回できない** `+4`
  > GPT。Executor は `AuthorizedOrder` だけを受け、トークンは一度だけ消費する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **内部 ID の冪等と、送信結果不明を成功と推測しない** `+4`
  > GPT。作成競合は既存行を返し、shutdown timeout は `submission_unknown` にして circuit を開く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **突合が両向きの短い再試行のあと、説明できない差分で止まる** `+5`
  > GPT。Fill 先行は残高の再取得、取引所先行は Fill 再同期を各 1 回に限り、なお説明できなければ mismatch で halt する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/test/bitflyer/startup/reconcile_test.exs`

- **Game Day は永続停止を消さず、停止中は監督木を起動しない** `+4`
  > Opus。停止の読取は Repo だけで、paper 発注の直前にも再読する。`halted_at` 不変のテストがある。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `apps/bitflyer/test/bitflyer/game_day_stage2_test.exs`

### datastore

- **Ash は永続状態、短期の板と判定は ETS** `+3`
  > 両者。注文・建玉・Fill・残高・RiskState・日次 peak に限定し、金額は Decimal。アプリは bitflyer と ui の 2 つのまま。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`

**小計: +46 / -0 = +46点**

---

## 技術評価層 — apps/ui

### 運用操作性

- **発注可否と停止理由に責務を限った Status** `+2`
  > GPT。画面は運用端末であり、操作は `Bitflyer.System` 経由。browser と LiveView の両方に BasicAuth がある。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/router.ex`

**小計: +2 / -0 = +2点**

---

## 技術評価層 — 実行基盤 / 設定

### config / Docker / CI

- **live は明示設定が揃ったときだけ開く** `+4`
  > Opus と GPT のゲート加点を 1 件にした。既定は dry_run。live はキー、当日 confirm、Ready、spot、戦略許可、出金権限の拒否が揃わないと起動しない。paper と dry_run は発注 REST を差さない。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/exchange/permissions.ex`

- **本番イメージは非 root で、開発の bind mount と分かれている** `+3`
  > GPT。`Dockerfile.prod` は `USER app`。本番 Compose は DB を外へ出さず、公開の既定は loopback。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

- **ローカルと CI が同じ mix precommit** `+3`
  > 両者。unused lock、format、warnings-as-errors、ash.codegen --check、test。CI は PostgreSQL 上で同じ alias を実行し、deps.audit と本番イメージビルドは別ジョブ。Actions は commit SHA ピン。2026-09-29 の実行は成功（bitflyer 1 doctest + 667、ui 38、失敗 0）。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

**小計: +10 / -0 = +10点**

---

## 横断評価層

### テストと観測と文書

- **資金を動かす境界に縦の反証がある** `+4`
  > GPT。実測 commission、誤った quote_mark 売りの halt、exchange-ahead の救済と説明不能入金の拒否が、モック 1 個ではなく永続状態と Reconciler を通る。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

- **telemetry は allowlist、Discord は発注を止めない** `+3`
  > 両者。通知 HTTP は Task、Webhook URL は失敗理由から外す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **完了宣言に、見方を満たす観測 1 行を必須化した** `+2`
  > Opus。ルールは improvement-plan と評価手順の両方にある。今回の再読で、完了主張と見方の矛盾による却下は 0 件だった。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.cursor/rules/evaluation.mdc`

- **Vision の範囲を二アプリのまま守っている** `+2`
  > GPT。ui から取引所 API を直接叩かず、第 3 アプリも無い。裁量 UI にも踏み込んでいない。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/ui/lib/ui_web/live/status_live.ex`

**小計: +11 / -0 = +11点**

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer | +46 |
| apps/ui | +2 |
| 実行基盤 / 設定 | +10 |
| 横断 | +11 |
| **合計** | **+69** |
