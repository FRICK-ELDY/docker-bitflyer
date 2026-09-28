# プラス点（統合）2026-09-29

対象コミット: `80c486f`（同日上書き）
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)
第1評価者: [opus-specific-strengths-2026-09-29.md](./opus/opus-specific-strengths-2026-09-29.md)
第2評価者: [gpt-specific-strengths-2026-09-29.md](./gpt/gpt-specific-strengths-2026-09-29.md)

同じ設計は 1 回だけ数える。朝の下書きから、閉じた HWM 窓を +5 に上げ、作業PCの ready 常駐を足した。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +72 点**

---

## 技術評価層 — apps/bitflyer

### 手数料・市場・認可

- **売買それぞれの実約定で手数料式を固定した** `+5`
  > 2026-09-28 の買い …6098 と売り …6123 の実差分が、base 手数料式と許容内で一致する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

- **全量売りを公表上限 0.15% の余白で先に拒む** `+3`
  > spot の売り拘束は `size + size × 0.0015`（`product.ex` L69-97）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`

- **Feed は ACK と鮮度で閉じ、ticker は LTP と板を分けた** `+4`
  > 未 ACK・切断・stall は再接続へ。板の異常は `book: nil` のまま LTP を残す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **発注前検査を一つの認可境界に集約した** `+4`
  > 鮮度、時計、サイズ、在庫、spread、頻度、日次損失、残高 probe を通り、未同期は fail-closed。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **認可が返る前に当日高値を DB へ落としきる** `+5`
  > 両者。非 suspend の enqueue は upsert と ack が終わるまで `:ok` を返さない（`peak_writer.ex` L153-170）。失敗は `{:error, :unsynced}`。回帰は PeakWriter を kill したあと `DailyLoss.reinit` で 160000 が残ることを固定する（`peak_writer_test.exs` の `write-behind success leaves the DB peak after both processes are discarded`）。SQL は `GREATEST` の 1 文。朝の強制終了窓はこの 1 件に吸収した。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs`

- **drain 失敗の停止を Postgres の外へ fsync し、次回起動が読む** `+4`
  > DB へ書けない停止をローカル印に残す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/drain_halt.ex`

- **live 成行買いの拘束を best ask × size にした** `+2`
  > paper は LTP のまま。板厚の超過は別途減点。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

### 発注と突合

- **認可トークンが Risk を迂回できない** `+4`
  > Executor は `AuthorizedOrder` だけを受け、トークンは一度だけ消費する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`

- **内部 ID の冪等と、送信結果不明を成功と推測しない** `+4`
  > shutdown timeout は `submission_unknown` にして circuit を開く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **突合が両向きの短い再試行のあと、説明できない差分で止まる** `+5`
  > Fill 先行と取引所先行を各 1 回に限り、なお説明できなければ halt する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **Game Day は永続停止を消さず、停止中は監督木を起動しない** `+4`
  > 停止の読取は Repo だけで、発注の直前にも再読する。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`

- **Ash は永続状態、短期の板と判定は ETS** `+3`
  > アプリは bitflyer と ui の 2 つのまま。金額は Decimal。高値が上がる認可だけが DB を待つ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`

**小計: +47 / -0 = +47点**

---

## 技術評価層 — apps/ui

- **発注可否と停止理由に責務を限った Status** `+2`
  > 操作は `Bitflyer.System` 経由。BasicAuth がある。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

**小計: +2 / -0 = +2点**

---

## 技術評価層 — 実行基盤 / 設定

- **live は明示設定が揃ったときだけ開く** `+4`
  > 既定は dry_run。live はキー、当日 confirm、Ready、spot、戦略許可、出金権限の拒否が揃わないと起動しない。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **本番イメージは非 root で、開発の bind mount と分かれている** `+3`
  > `Dockerfile.prod` は `USER app`。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

- **ローカルと CI が同じ mix precommit** `+3`
  > #3 実装後の実行は成功（bitflyer 1 doctest + 668、ui 38、失敗 0）。この上書き再評価では再実行していない。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

**小計: +10 / -0 = +10点**

---

## 横断評価層

- **資金を動かす境界に縦の反証がある** `+4`
  > 実測 commission、誤った quote_mark 売りの halt、HWM が認可後の kill でも残る回帰を含む。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`, `apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs`

- **telemetry は allowlist、Discord は発注を止めない** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **完了宣言は見方を先に書き換え、観測 1 行で閉じる** `+2`
  > P1 #5 は作業PC常駐へ見方を変えてから完了にした。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

- **Vision の範囲を二アプリのまま守っている** `+2`
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/ui/lib/ui_web/live/status_live.ex`

- **作業PCで ready を常駐させ、解除手順がある** `+2`
  > GPT。`BitflyerWatchReady` の登録、失敗ログ、`unregister-watch-ready-task.ps1` が揃う。証跡冒頭との食い違いは減点側。
  > 対象ファイル: `bin/register-watch-ready-task.ps1`, `bin/unregister-watch-ready-task.ps1`, `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

**小計: +13 / -0 = +13点**

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer | +47 |
| apps/ui | +2 |
| 実行基盤 / 設定 | +10 |
| 横断 | +13 |
| **合計** | **+72** |
