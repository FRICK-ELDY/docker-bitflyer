# docker-bitflyer 第2評価者 プラス点（2026-09-29）

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティスに沿う良い設計 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る |
| +4 | プロダクションレベルの取引基盤と比べても遜色ない |
| +5 | 個人プロジェクトとして卓越している |

## 技術評価層 — apps/bitflyer

### market-data

- **ACK・再接続・鮮度を一体化した fail-closed Feed** `+4`
  > Feed は購読書込みだけで connected にせず全 ACK を待ち（`feed.ex:160-176`）、未 ACK、error、切断、silent stall を再接続へ送る（同 `:180-239`）。接続状態は PID 付き `:persistent_term` で読み、プロセス交代の隙間も切断扱いにする（同 `:42-67`）。Ticker は LTP と book を二層化し、crossed / 欠落板だけを nil にして LTP の鮮度・時計検査を維持する（`normalize.ex:1-13,123-136`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

### risk-manager

- **発注前検査を資金保全順に集約した Risk 境界** `+4`
  > Feed、鮮度、時計、サイズ、建玉、spot 売りカバー、価格逸脱、成行 spread、原子的頻度予約、日次損失、HWM、残高 probe を一つの認可境界へ集約している。板欠落は成行だけ `bid_ask_missing` で拒否し（`risk.ex:569-595`）、頻度注入は本番では無視して実予約を使う（同 `:599-635`）。日次損失の未同期も認可せず fail-closed である（同 `:639-656`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **HWM write-behind の再送・単調更新・通常停止 drain** `+3`
  > writer は同一日・モードの高値だけを pending に残し（`peak_writer.ex:376-418`）、upsert 失敗や DailyLoss 停止時も再送する（同 `:290-347`）。DB は `INSERT ... ON CONFLICT ... GREATEST` の一文で低い後着値を拒む（`daily_equity_peak.ex:81-130`）。別 DB 接続の競合テストも最高値 150000 を確認する（`daily_equity_peak_upsert_test.exs:14-28,32-63`）。強制終了窓は別途減点したため、ここでは実装済み範囲だけを評価する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`, `apps/bitflyer/test/bitflyer/trading/daily_equity_peak_upsert_test.exs`

### order-executor

- **認可トークンで Risk 迂回を構造的に防ぐ** `+4`
  > Executor は raw map ではなく opaque な `AuthorizedOrder` だけを受け、トークンは protected ETS から `take` して一度だけ消費する（`authorized_order.ex:1-9,50-56,107-132`）。System の公開 submit は shutdown gate、live fill 同期、Risk 認可、Executor の順を固定する（`system.ex:381-398`）。単なる呼出規約でなく型とワンショット状態で依存方向を強制している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **モード分岐を出口へ閉じ込め、paper/dry_run の実 REST を遮断する** `+4`
  > `dry_run` / `paper` / `live` の dispatch は Executor 内の三出口だけで分かれ（`order_executor.ex:420-423`）、runtime は live かつ資格情報ありの場合だけ REST client を差し込む（`runtime.exs:110-153`）。`TRADE_MODE` の既定は dry_run、不正値は起動失敗、live は UTC 当日 confirm と Ready の両方を要求する（`trade_mode.ex:53-63,80-134`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

- **内部 ID 冪等性と送信結果不明の回復設計** `+4`
  > pending 作成前に `internal_order_id` を検索し、作成競合でも既存行を返して二重 REST を防ぐ（`order_executor.ex:337-399`）。shutdown timeout は未確定 submit を `submission_unknown` にして circuit を開く（`application.ex:148-160`）ため、成功か失敗かを推測して再送しない。通常停止時の回帰も gate 閉鎖、in-flight drain、unknown 化を固定する（`application_shutdown_test.exs:80-179`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/test/bitflyer/application_shutdown_test.exs`

### startup / reconcile

- **取引所事実との突合と両向き窓救済が高水準** `+5`
  > live 起動は永続状態復元、停止状態、権限、時計、Fill 同期、残高・spot 在庫・未約定比較を通す（`reconcile.ex:77-117,163-174,176-243`）。Fill 先行は getbalance 再取得、取引所先行は Fill 再同期→内部再読→snapshot 再取得を各1回に限定し、なお説明不能なら mismatch にする（同 `:290-350`）。exchange-ahead の回復と、再同期後も説明不能な入金を拒否する回帰がある（`reconcile_test.exs:1168-1217,1267-1291`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/test/bitflyer/startup/reconcile_test.exs`

- **実測 commission を会計・在庫・反証回帰へ接続した** `+4`
  > 2026-09-28 の買い・売り実測は JPY 1円、BTC 1 satoshi 以内で base 手数料式と一致し、旧 quote-mark 式は許容外である（`commission-unit-evidence.md:43-63`）。回帰は正しい BTC fee を通すだけでなく、JPY 決め打ち・旧売り残高・膨張 Position を mismatch にする（`commission_unit_guard_test.exs:20-65,69-132`）。一次証跡と反証可能なテストが結び付いたため、前回の `-3` は解消と判断する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`, `apps/bitflyer/test/bitflyer/regression/commission_unit_guard_test.exs`

### datastore / cache / observe / OTP

- **Ash を永続状態、ETS を短期状態に限定する境界** `+3`
  > Trading Domain は注文、建玉、Fill、残高、baseline 監査、戦略 revision、RiskState、日次 peak に限定する（`trading.ex:1-20`）。金額・数量は Order、Position、Fill、BalanceSnapshot で decimal 属性である。アプリは bitflyer と ui の2つだけで、第3アプリも存在しない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

- **allowlist telemetry と非同期 Discord 通知** `+3`
  > 取引イベント語彙を一元化し、Logger / telemetry metadata は既存 atom の allowlist だけを通す（`telemetry.ex:12-68,100-159`）。Discord は発注経路から独立し、HTTP を Task 化、URL を失敗理由から除去し、起動直後と定期 heartbeat を持つ（`discord.ex:1-15,158-217`）。通知失敗で発注処理を止めない observe 境界が明確である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **兄弟監督と停止時の安全な drain** `+4`
  > bitflyer と ui は別 Application supervisor であり（`application.ex:13-45`, `apps/ui/lib/ui/application.ex:8-23`）、通知 worker も `:one_for_one` の兄弟である。停止時は Ready を先に閉じ、in-flight submit/cancel、HWM writer の順に drain し、失敗は unknown または永続 halt に倒す（`application.ex:59-143`）。UI 停止側も先回りして gate を閉じる（`apps/ui/lib/ui/application.ex:34-42`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

**小計: +38 / -0 = +38点**

## 技術評価層 — apps/ui

### Phoenix / 運用操作性

- **発注可否を中心に据えた限定的な運用 UI** `+2`
  > Status は発注可否、停止理由、建玉、未約定、損益、復帰操作に責務を限定し、画面にも “This is not a trading UI” と明記する（`status_live.ex:1-6,122-193`）。データ・操作は `Bitflyer.System` 経由で、bitFlyer API や Repo を直接呼ばない（同 `:48-80,637-649`）。browser と LiveView mount の両方に BasicAuth を置き、health だけを匿名 API として分離する（`router.ex:3-38`）。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/router.ex`

**小計: +2 / -0 = +2点**

## 技術評価層 — 実行基盤 / 設定

### Docker Compose / Dockerfile

- **開発 bind mount と非 root release を分離した本番構成** `+3`
  > 本番は multi-stage release、uid 1000 の非 root `USER app`、tini、ソース非 mount である（`Dockerfile.prod:1-79`）。本番 Compose は DB を外部公開せず、アプリ公開も既定 loopback、秘密は env、イメージは digest 指定可能、halt marker と DB を volume 化する（`compose.prod.yaml:16-39,49-100`）。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

### config / security

- **live を明示設定の積でしか開けない安全既定** `+4`
  > runtime は dry_run を既定にし、live でキー、当日 confirm、専用 risk 上限、有限 open age、spot 銘柄、承認済み戦略を要求する（`runtime.exs:74-177`）。起動突合は空権限も拒否し、withdraw / sendcoin 権限を fail-closed にする（`permissions.ex:1-31`）。単一フラグで実弾へ移れない設計は資金保全に直結する。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/exchange/permissions.ex`

### CI

- **ローカルと CI の品質ゲートを一本化** `+3`
  > `mix precommit` は unused lock、format、warnings-as-errors compile、Ash snapshot drift、warnings-as-errors test を一つに束ねる（`mix.exs:42-57`）。CI は PostgreSQL を起動して同 alias を実行し、Hex advisory と本番 image build も独立 job で検査する（`ci.yml:16-72,74-153`）。Actions も commit SHA 固定である。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

**小計: +10 / -0 = +10点**

## 横断評価層

### テスト戦略

- **損失を生む境界に縦回帰と反証テストを集中している** `+4`
  > 発注→部分約定→突合→再起動→売却を実ハーネスで通し、非ゼロ commission、tip 前進、説明不能入金、誤った quote-mark モデルの halt を固定する（`live_balance_advance_test.exs:106-197,241-299,363-408`）。単体モックだけでなく永続状態・ETS・Reconciler を跨ぐため、資金保全回帰として強い。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

### Game Day / Recoverable

- **paper の障害注入が本番同型の縦経路を通る** `+3`
  > Stage 2 は `System.submit_order/2` で paper 建玉を作り、Feed 断拒否、復帰後再発注、Discord probe を行う（`bitflyer.game_day_stage2.ex:1-22,88-119`）。永続 halt は Repo だけで先読みし、停止中は監督木を起動せず、paper 発注直前にも再読する（同 `:60-76,217-258`）。停止時に `halted_at` を変えない回帰もある（`game_day_stage2_test.exs:52-73,128-136`）。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `apps/bitflyer/test/bitflyer/game_day_stage2_test.exs`

### セキュリティ・公開面

- **秘密情報と管理面の露出を最小化** `+3`
  > 本番 DB は compose 内部だけ、HTTP は既定 loopback、Status / Dashboard は BasicAuth、health は監視用の最小匿名面である（`compose.prod.yaml:16-25,55-59`, `router.ex:20-51`）。telemetry metadata は allowlist、Webhook URL はログから redaction されるため、運用観測と秘密保護を両立している。
  > 対象ファイル: `compose.prod.yaml`, `apps/ui/lib/ui_web/router.ex`, `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

### プロジェクト全体設計

- **Vision の非目標を守る二アプリ構成と改善証跡** `+2`
  > apps は `bitflyer` と `ui` の2つだけで、取引ドメインから UI への逆依存や裁量発注 UI を持たない。Architecture はモード、起動順、残高正本、health の意味を実装行動まで定義し、今回の commission 証跡や完了条件も日付・反証を持つ。文書だけでなく対応コードを再読して一致を確認できた範囲を評価した。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/ui/mix.exs`, `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

**小計: +12 / -0 = +12点**

## 合計

**加点合計: +62点**
