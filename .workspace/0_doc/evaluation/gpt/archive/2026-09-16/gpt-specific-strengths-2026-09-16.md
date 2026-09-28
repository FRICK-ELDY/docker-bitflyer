# docker-bitflyer 第2評価者 プラス点（2026-09-16）

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティス |
| +3 | 同規模・同種の平均を明確に上回る |
| +4 | プロダクション級 |
| +5 | 個人プロジェクトでは稀な卓越 |

## 技術評価層 — apps/bitflyer

### market-data

- **購読成立を JSON-RPC ACK まで遅延する** `+4`
  > request id ごとの ACK と timeout を管理し、`result: true` の全確認後だけ connected にする。false・error・timeout は再接続へ倒す（`feed.ex:309-448`, `normalize.ex:102-153`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **再接続・gap-fill・鮮度・時計ずれが発注拒否まで接続される** `+4`
  > Feed の backoff / stall watchdog と REST gap-fill、Cache TTL、取引所 source timestamp 検査を分離し、切断直後は TTL が残っていても Risk が拒否する（`risk.ex:320-425`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **bid/ask 正規化と成行 spread ゲートを fail-closed で追加した** `+3`
  > ticker は正の LTP/bid/ask と ask≥bid を必須化し、成行だけ `((ask-bid)/mid)*100` を `max_spread_pct` と比較する。欠落・crossed は Cache または認可で拒否される（`normalize.ex:1-46`, `risk.ex:548-575,830-893`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### strategy

- **Strategy → Risk → Executor の依存方向と provenance が明確** `+3`
  > Runner は revision ID、module、command hash を付け、取引所 API ではなく `Bitflyer.System.submit_order/1` だけへ渡す（`runner.ex:428-479`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **再起動重複と残高不足 tight loop の両方を抑える** `+3`
  > submitted ID の復元完了前と滞留 tick を捨て、`insufficient_balance` 後は銘柄単位の既定5秒 backoffを掛ける（`runner.ex:75-186,210-318,490-510`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### risk-manager

- **資金保全ゲートが多層かつ fail-closed** `+4`
  > Ready、FailureRate、Feed、鮮度、時計、サイズ、建玉、spot 売りカバー、価格、spread、頻度、日次損失、drawdown、残高を直列検査し、DB/ETS 読取失敗を 0 や空へ丸めない（`risk.ex:99-126`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **HWM の単調永続化と persisted_peak flush を実装した** `+4`
  > `(trade_mode, trading_day)` 一意行への高値だけの upsertに加え、ETS の `peak` と `persisted_peak` を分け、低い equity で呼ばれても未永続高値を flush できる（`daily_loss.ex:200-218,241-288,559-608`）。crash 前窓は弱点側に分離する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **spot fee を Position・残高・損益へ同じ通貨契約で接続した** `+3`
  > Fill に fee currency を残し、base fee の買い Position は `size-fee`、損益は quote mark、LiveBalance は通貨別 delta を計算する（`positions.ex:20-47,304-338`, `live_balance.ex:267-303`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

- **live 設定を開発既定から分離する** `+4`
  > live は spot 限定、FixedOnce 禁止、risk 上限と有限 open age を環境変数必須にし、当日 confirm と Ready を別ゲートにする（`runtime.exs:75-177`, `trade_mode.ex:80-135`）。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

- **BalanceCache probe と世代 barrier が認可・予約の安全性を上げる** `+3`
  > 認可は reserve と同一比較の非減額 probe を使い、正本減額は submit 時の原子 reserve に残す。Fill 中の reload は generation/barrier で古い値を synced にしない（`balance_cache.ex:112-148,300-399`, `risk.ex:667-718`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### order-executor / recovery

- **ワンショット認可と DB 一意性で二重発注を防ぐ** `+4`
  > Executor は `AuthorizedOrder` の consume を必須とし、`internal_order_id` 既存行は再送しない。並行 create 競合でも既存 Order を返す（`order_executor.ex:42-76,336-418`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **残高 tip を説明可能な差分だけ前進する** `+4`
  > tip 以降の Fill から通貨別 expected を作り、入金側差分を許容せず、成功時だけ advisory lock + transaction で append する（`live_balance.ex:139-193,453-510,519-573`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

- **execution 単位記帳・coverage・ページングが閉じる** `+4`
  > execution ID 一意制約、remote total と delta、取引所時刻、`before` ページングを組み合わせ、上限超過を部分成功にしない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **受注不明と受注後同期失敗を確定拒否から分離する** `+4`
  > timeout/切断は `submission_unknown`、受注 ID 永続後の fill sync 失敗は `order_accepted: true` として circuit を開く。「失敗だから再送」を許さない（`live.ex:47-107,201-219`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **有限未約定期限と終端確認後の hold 解放** `+3`
  > live は有限 open age を必須化し、boot/run_now/周期で aged cancel を行う。取消受付だけでは hold を解放しない（`order_executor.ex:133-170,489-516`, `reconciler.ex:64-135`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **グレースフル停止がゲート閉鎖と in-flight drain を行う** `+3`
  > `prep_stop/1` は先に Readiness を閉じ、submit/cancel を drainし、timeout leftovers を submission_unknown/circuitへ寄せる（`application.ex:52-144`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **モード差を Executor の出口に限定する** `+3`
  > Risk と Order 永続化を共通化し、dispatch だけを dry_run/paper/live に分岐する（`order_executor.ex:103-121,420-443`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

### datastore / cache / OTP

- **永続状態を Ash/PostgreSQL、短期状態を ETS に分離する** `+3`
  > Order・Fill・Position・BalanceSnapshot・RiskState・HWM は Ash、鮮度・予約・barrier は ETS、価格数量は Decimal で Architecture と一致する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/lib/bitflyer/risk/`

- **残高 hold と Fill 集計の並行安全性が高い** `+3`
  > 発注前 reserve、部分約定比例 consume、終端 release と generation barrier を組み合わせ、認可と永続化の隙間を埋める（`balance_cache.ex:151-241,400-559`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **OTP 子を一障害で巻き込まない** `+2`
  > Repo、risk caches、Reconciler、Discord、Feed は `:one_for_one` の兄弟で、通知 HTTP も非同期である（`application.ex:14-47`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **Ash snapshot drift を precommit で固定した** `+2`
  > `ash.codegen --check` を共通ゲートに追加し、手書き migration と対応する tracked snapshot を同期した（`mix.exs:41-56`, `20260916101043_sync_handwritten_snapshots.exs:1-27`）。
  > 対象ファイル: `mix.exs`, `apps/bitflyer/priv/repo/migrations/20260916101043_sync_handwritten_snapshots.exs`, `apps/bitflyer/priv/resource_snapshots/repo/`

### observe

- **telemetry と構造化ログを allowlist で統一する** `+3`
  > 取引イベント語彙を固定し、secret 類を metadata から落とす（`telemetry.ex:11-67,97-159`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

- **liveness/readiness と Discord を発注経路から分離する** `+2`
  > `/health/live` と `/health/ready` を分け、Discord 未設定・送信失敗でも取引ロジックを止めない（`health_controller.ex:1-57`, `discord.ex:1-15,140-205`）。
  > 対象ファイル: `apps/ui/lib/ui_web/controllers/health_controller.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **BasicAuth 配下に運用内省を残す** `+2`
  > Status と LiveDashboard を同じ browser 認証配下に置き、Ecto/RequestLogger/破壊操作を無効化する（`router.ex:30-55`）。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`

## 技術評価層 — apps/ui

### Phoenix / LiveView・運用操作性

- **「今トレードしてよいか」を最上段で示す** `+3`
  > Orders ALLOWED/STOPPED、理由、mode、Ready、Feed、鮮度、建玉、未約定、損益、headroomを集約し、裁量 UI に逸脱しない（`status_live.ex:122-627`）。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **kill/resume/reconcile を認証配下で非同期実行する** `+2`
  > 操作中の二重入力を抑止し、resume は再突合成功時だけ成立する（`status_live.ex:38-117,195-249`）。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

## 技術評価層 — 実行基盤

### Docker / config

- **開発 bind mount と本番 release を分離する** `+3`
  > 本番は multi-stage、非 root、tini、DB非公開、app loopback公開、restart と liveness healthcheckを持つ（`Dockerfile.prod:1-79`, `compose.prod.yaml:16-89`）。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

- **runtime 設定が fail-closed で環境分離される** `+4`
  > 不正 mode、live key欠落、BasicAuth欠落、非公式 WS URL、live risk上限欠落を起動時に拒否する（`runtime.exs:75-205,270-307,355-406`）。
  > 対象ファイル: `config/runtime.exs`

### CI / CD / security

- **ローカルと CI が同じ precommit を使う** `+3`
  > format、warnings-as-errors compile/test、unused deps、Ash drift をルート alias に集約し、CIも PostgreSQL 上で同じコマンドを実行する（`mix.exs:41-56`, `ci.yml:15-72`）。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

- **Actions SHA pin・Hex audit・prod image buildを独立ゲート化する** `+2`
  > advisory、テスト、release image buildを分離し、Actions自体も commit SHA固定である（`ci.yml:73-153`）。
  > 対象ファイル: `.github/workflows/ci.yml`

- **出金権限付き live key を起動突合で拒否する** `+2`
  > balances/orders より前に permissions を検査し、withdraw/sendcoin を Ready にしない（`reconcile.ex:163-193`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

## 横断評価層

### テスト戦略・取引完成度・全体設計

- **資金保全の回帰が 668 tests + 1 doctest まで厚い** `+5`
  > 2026-09-16実測で bitflyer 630 tests + 1 doctest、ui 38 tests、0 failures。非ゼロ fee の部分約定、tip前進、ETS再初期化、反証、突合窓を自動試験する（`live_balance_advance_test.exs:109-285`, `commission_unit_guard_test.exs:21-153`, `reconcile_test.exs:1088-1275`）。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`, `apps/bitflyer/test/bitflyer/startup/reconcile_test.exs`

- **Vision / Architecture とコードの対応密度が高い** `+3`
  > Ready正本、spot限定、fee currency、突合窓、Feed ACK、有限open age、外部監視の未完まで文書と実装が対応する（`overview.md:99-196`）。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`

- **対象 SHA の CI 成功を CD が再検証する** `+3`
  > 明示タグ/手動だけで起動し、対象 SHA の最新 CI workflow 全体 success がなければ GHCR pushしない（`cd.yml:41-72`）。
  > 対象ファイル: `.github/workflows/cd.yml`

- **Game Day Stage 2 が paper Executor の縦経路になった** `+3`
  > Mix task が同一 BEAM で paper submit→建玉→Feed断中の認可拒否→Feed復帰後の再 submit→Discord HTTP 2xxを実行し、後始末も行う（`bitflyer.game_day_stage2.ex:1-75,90-228,310-420`）。実施記録も2026-09-16分がある（`game-day.md:160-177`）。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `.workspace/0_doc/architecture/env/game-day.md`

**加点合計: +110**
