# docker-bitflyer 第2評価者 プラス点（2026-09-13）

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティス |
| +3 | 同規模・同種の平均を明確に上回る |
| +4 | プロダクション級 |
| +5 | 個人プロジェクトでは稀な卓越 |

## 技術評価層 — apps/bitflyer

### market-data

- **購読成立を JSON-RPC ACK まで遅延させる** `+4`
  > `Feed` は request id ごとに timeout ref を持ち、全 ACK 後だけ `set_connected(true)` する（`feed.ex:309-379`）。`Normalize.rpc_response/1` は `result: true` だけを成功とし、false・null・error・`channelError` を拒否する（`normalize.ex:88-137`）。書込み成功と購読成立を分離した実装である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **再接続・gap-fill・鮮度・時計ずれが発注ゲートまで接続される** `+4`
  > `Feed` は指数 backoff と stall watchdog、WS 後着を壊さない非同期 gap-fill を持つ（`feed.ex:393-448, 501-540`）。`Risk` は Cache 鮮度だけでなく取引所 `source_timestamp` も検査する（`risk.ex:365-419`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### strategy

- **Strategy → Risk → Executor の依存方向と provenance が明確** `+3`
  > Runner は戦略出力に revision ID・module・command hash を付与し、必ず `Bitflyer.System.submit_order/1` へ渡す（`runner.ex:350-405`）。戦略から取引所 API を直接呼ぶ経路はない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **再起動時の submitted 復元と滞留 tick 排除** `+3`
  > DB から既送信 ID を復元するまで tick を無視し、ロード完了前に mailbox へ入った tick も monotonic timestamp で破棄する（`runner.ex:69-176, 415-438`）。再起動直後の重複意図を Executor の冪等性と二重に防ぐ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### risk-manager

- **資金保全ゲートが多層かつ fail-closed** `+4`
  > 認可列は Ready、FailureRate、Feed、鮮度、時計、注文量、建玉、spot 売り在庫、価格逸脱、原子頻度予約、日次損失、drawdown、残高の順で閉じる（`risk.ex:89-144`）。DB/ETS 読取失敗を空や 0 に丸めない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **HWM を永続化し再起動時に高い方を採る** `+4`
  > `(trade_mode, trading_day)` 一意の `DailyEquityPeak` を条件付き更新し、低い並行値の上書きを防ぐ（`daily_equity_peak.ex:80-198`）。`DailyLoss` は同日 ETS と DB の高い方を採り、読取・書込失敗を unsynced にする（`daily_loss.ex:240-278, 559-608`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **spot 在庫を認可と突合で同じ不変条件へ寄せた** `+3`
  > `SpotInventory` が「買い Position − 未約定売り」を一元計算し（`spot_inventory.ex:12-75`）、Risk は baseline 専用在庫の売却を拒否、Reconcile は内部膨張・short・売り超過を halt する（`risk.ex:463-500`, `live_inventory.ex:30-100`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/spot_inventory.ex`, `apps/bitflyer/lib/bitflyer/startup/live_inventory.ex`

- **Feed 切断直後に認可を閉じる** `+3`
  > `Risk.check_market_feed/2` は Status/ready と同じ classifier を使い、`Feed.connection_snapshot/0` の PID 一致付き persistent_term を読む（`risk.ex:312-352`, `feed.ex:43-67`）。Cache の TTL が残っていても発注しない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **live の設定値を開発既定から分離した** `+4`
  > live は risk 上限と有限 open age を環境変数で必須化し、FixedOnce と非 spot 銘柄を起動時に拒否する（`live_safety.ex:14-41, 47-71, 110-146`）。`BITFLYER_LIVE_CONFIRM` と Ready も別ゲートである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **ホットパスの ETS barrier が古い値での再同期を防ぐ** `+3`
  > DailyLoss は invalidate generation と barrier を持ち、突合 reload が in-flight Fill を飛び越えて synced に戻すことを拒む（`daily_loss.ex:91-155, 493-540`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

### order-executor / recovery

- **AuthorizedOrder と DB 一意性による二重防止** `+4`
  > Executor はワンショット `AuthorizedOrder` だけを受け、`internal_order_id` の既存行を再送しない。並行 create 競合でも既存 Order を返す（`order_executor.ex:43-76, 336-399`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **説明可能な残高差分だけ tip を前進する骨格** `+3`
  > `LiveBalance` は tip 以降の Fill から expected amount を作り、増加側差分を許容せず、成功時のみ advisory lock と transaction で snapshot を append する（`live_balance.ex:139-193, 423-479, 495-526`）。手数料通貨の欠陥は弱点側に別記するが、ゼロ手数料経路と競合制御は有効である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

- **execution 単位記帳・coverage・ページングが閉じる** `+4`
  > execution ID 一意制約、remote total と delta の二重 coverage、取引所時刻、`before` ページングを組み合わせる（`live_fills.ex:228-407`, `rest.ex:112-238`）。上限超過は `execution_pages_exhausted` で黙って部分集合を採用しない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **受注不明と受注後同期失敗を成功・確定拒否から分離** `+4`
  > timeout/切断は `submission_unknown` で circuit を開き、受注 ID 永続化後の fill sync 失敗も `order_accepted: true` を返して halt する（`live.ex:47-107, 201-219`）。損失に直結する「失敗だから再送」を許さない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **有限未約定期限と取消後の終端確認** `+3`
  > live は 7 日以下の `BITFLYER_MAX_OPEN_AGE_MS` を必須化し、Reconciler が boot/run_now/周期で aged cancel を起動する（`open_order_policy.ex:50-60, 124-145, 240-297`, `reconciler.ex:64-126`）。取消受付だけでは hold を解放せず、終端観測を待つ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`

- **グレースフル停止が新規発注停止と in-flight drain を行う** `+3`
  > `prep_stop/1` は Readiness を閉じて submit/cancel を drain し、timeout leftovers を submission_unknown 化して circuit を開く（`application.ex:52-144`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **モード差を Executor の出口に限定する** `+3`
  > Risk と Order 永続化を共有し、dispatch だけを dry_run/paper/live に分岐する（`order_executor.ex:103-121, 421-443`）。paper から live REST を呼ばない回帰も precommit に含まれる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

### datastore / cache / OTP

- **永続状態を Ash/PostgreSQL、短期状態を ETS に分離** `+3`
  > Order・Fill・Position・BalanceSnapshot・RiskState・HWM は Ash、鮮度・予約・barrier は ETS で、価格・数量は Decimal を使う。Architecture の境界と一致する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/lib/bitflyer/risk/`

- **残高 hold と Fill 集計の並行安全性が高い** `+3`
  > 発注前 hold、部分約定比例 consume、終端 release と DailyLoss generation barrier を組み合わせ、認可値と永続化の隙間を埋める（`order_executor.ex:445-518`, `daily_loss.ex:91-155`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **OTP 子が一障害で全体を巻き込まない** `+2`
  > Repo、risk caches、Reconciler、Discord、Feed を `:one_for_one` の兄弟として起動し、Discord HTTP も非同期化する（`application.ex:14-47`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

### observe

- **telemetry と構造化ログを allowlist で統一** `+3`
  > イベント語彙を固定し、文字列キーも existing atom のみ許可して secret 類を metadata から落とす（`telemetry.ex:11-67, 97-159`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

- **health/readiness と Discord を発注経路から分離** `+2`
  > liveness と readiness を分け、Discord は webhook 未設定・送信失敗でも取引ロジックを止めない（`discord.ex:1-15, 163-205`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`

- **本番でも BasicAuth 配下の LiveDashboard を残す** `+2`
  > Ecto、RequestLogger、破壊操作を無効にしつつ Processes/ETS/Applications とドメイン metrics を確認できる（`router.ex:40-55`）。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`

## 技術評価層 — apps/ui

### Phoenix / LiveView・運用操作性

- **「今発注可能か」を最上段で一意に示す運用 UI** `+3`
  > Orders ALLOWED/STOPPED、reason、mode、Ready、Feed、鮮度、建玉、未約定 age、損益、headroom を同じ画面へ集約する（`status_live.ex:168-627`）。裁量発注 UI へ逸脱していない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **kill/resume/reconcile を非同期かつ認証配下で提供** `+2`
  > 操作中の二重入力を抑止し、resume は再突合成功時だけ成立する（`status_live.ex:21-117, 195-249`）。prod は BasicAuth 必須、health だけ匿名である（`runtime.exs:270-307`, `router.ex:20-38`）。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/router.ex`

## 技術評価層 — 実行基盤

### Docker / config

- **開発 bind mount と本番 release を明確に分離** `+3`
  > `Dockerfile.prod` は multi-stage、非 root、tini、secret 非同梱。Compose は DB 非公開、app loopback 公開、restart と liveness healthcheck を持つ（`Dockerfile.prod:1-79`, `compose.prod.yaml:41-87`）。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

- **runtime 設定が fail-closed で環境分離される** `+4`
  > 不正 TRADE_MODE、live key 欠落、BasicAuth 欠落、非公式 WS URL、live risk 上限欠落を起動時に拒否する（`runtime.exs:75-176, 179-205, 270-307`）。
  > 対象ファイル: `config/runtime.exs`

### CI / CD / security

- **ローカルと CI が同じ副作用なし precommit を使う** `+3`
  > format check、warnings-as-errors compile/test、unused deps をルート alias へ集約し、CI も PostgreSQL 上で同じコマンドを呼ぶ（`mix.exs:41-55`, `ci.yml:15-72`）。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

- **Actions SHA pin・Hex audit・prod image build を独立ゲート化** `+2`
  > PR/main で advisory、テスト、release image を別ジョブ検証し、Actions は commit SHA 固定である（`ci.yml:73-153`）。
  > 対象ファイル: `.github/workflows/ci.yml`

- **live key の出金権限を起動突合で拒否** `+2`
  > `Reconcile` は残高や注文より先に `getpermissions` を検査し、unsafe permission を Ready にしない（`reconcile.ex:158-188`）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

## 横断評価層

### テスト戦略・設計文書・取引完成度

- **資金保全の縦回帰が 637 tests + 1 doctest まで厚くなった** `+5`
  > ハーネス経由で発注、2 回部分約定、周期突合、Readiness、ETS 再初期化、再突合まで走らせる（`live_balance_advance_test.exs:101-159`）。2026-09-13 実測は bitflyer 599 tests + 1 doctest、ui 38 tests、0 failures。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

- **Vision/Architecture とコードの対応が高密度** `+3`
  > Ready 正本、spot 限定、残高前進、Feed ACK、有限 open age、外部監視の意味論が Architecture に明文化され、実装箇所まで対応する（`overview.md:99-196`）。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`

- **対象 SHA の CI 成功を CD が再検証する** `+3`
  > GHCR push 前に対象 SHA の最新 CI workflow 全体成功を要求し、Compose は digest 固定を推奨する。配布と起動を同一視しない設計である。
  > 対象ファイル: `.github/workflows/cd.yml`, `.workspace/0_doc/architecture/ci-cd.md`

**加点合計: +104**
