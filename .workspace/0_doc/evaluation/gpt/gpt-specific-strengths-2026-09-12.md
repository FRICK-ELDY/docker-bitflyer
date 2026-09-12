# docker-bitflyer 第2評価者 プラス点（2026-09-12）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティスに沿う良い設計 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る |
| +4 | プロダクションレベルと比較して遜色ない |
| +5 | 個人プロジェクトとして卓越した実装 |

## 技術評価層 — apps/bitflyer

### market-data

- **鮮度付き ETS・再接続・gap-fill・source timestamp が一つの安全経路を作る** `+3`
  > Feed は指数 backoff、非同期 REST gap-fill、WS 到着後の古い REST 応答による上書き防止、stall watchdog を持つ（`feed.ex:190-221, 252-309, 353-398`）。Normalize が取引所時刻を保持し、Risk が受信鮮度と時計ずれをともに fail-closed で検査する（`risk.ex:278-331`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **Status と readiness が Feed 接続・全銘柄鮮度の同一 classifier を共有する** `+2`
  > `OperationalStatus.market_feed_gate/2` は MarketData 有効時に Feed available/connected と全銘柄 fresh を順に検査し（`operational_status.ex:105-132`）、Status の注文可否と `/health/ready` が同じ判定を使う。前回の表示上 ALLOWED と ready 503 の矛盾は解決した。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

### strategy

- **Strategy → Risk → Executor の依存方向と live 安全既定を強制する** `+4`
  > Strategy は `System.submit_order/2` を通り、System は live fill 同期→Risk 認可→AuthorizedOrder 消費の順を崩さない（`system.ex:373-396`）。live は Strategy 既定無効、FixedOnce 禁止、6つの Risk 上限を環境変数必須にする（`live_safety.ex:11-39, 84-178`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **戦略 revision と注文由来を immutable に永続化する** `+3`
  > StrategyParameterRevision は mode/module/params hash/operator/適用時刻を保持し、Runner は revision ID・module・command hash を Order へ残す。後から「どの設定が注文を生んだか」を追跡できる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

### risk-manager

- **未同期を 0・空として扱わない多段 fail-closed 認可** `+4`
  > 認可は command/product/readiness/failure-rate/鮮度/時計/数量/建玉/価格/頻度/損失/drawdown/残高を順に通す（`risk.ex:70-126`）。Position、FailureRate、OrderRate、DailyLoss、BalanceCache の読取不能を安全値へ丸めず拒否する。live 商品も `Product.spot?/1` で二重に限定する（同 `215-235`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **DailyLoss / BalanceCache の generation barrier と hold は競合時も過大利用へ倒れない** `+4`
  > Fill 前に invalidate、DB 処理後に同一 generation の reload を行い、失敗時は unsynced を維持する。BalanceCache は reserve/consume/release と snapshot 再読後の hold 再適用を GenServer 境界へ置く（`balance_cache.ex:580-612`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **AuthorizedOrder のワンショット capability で Risk 迂回を困難にする** `+3`
  > protected ETS の token は command・時刻・TTL を照合して一度だけ take され、偽造・再利用・期限切れを拒否する。破棄時は OrderRate 予約も解放する（`authorized_order.ex:42-46, 115-166`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **発注頻度を authorize 時に原子的予約し、失敗経路で確実に返す** `+3`
  > `OrderRate.reserve/3` は count・prune・slot insert を一つの GenServer call で行う（`order_rate.ex:153-176`）。pending 永続化で commit、認可後失敗・冪等 hit・shutdown・token expiry で release し、並行認可でも上限を超えない回帰がある。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **realized + unrealized の日次 HWM drawdown を認可・約定後・周期・resume に接続する** `+3`
  > `Equity` は `drawdown = peak - equity_pnl` を実装し（`equity.ex:50-75`）、未知 side や mark stale を 0 にしない。Risk 認可、Fill 後、Reconciler boot/periodic、Resume の全経路に接続される（`daily_loss_sync.ex:26-34`, `reconciler.ex:72-121`, `resume.ex:182-194`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/equity.ex`, `apps/bitflyer/lib/bitflyer/order_executor/daily_loss_sync.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`

### order-executor / recovery

- **モード別出口・DB 一意冪等キー・残高 reserve を単一 Executor に集約する** `+4`
  > Executor は AuthorizedOrder だけを受け、`internal_order_id` の事前照会と DB identity 競合の双方で再送を防ぐ。dry_run/paper/live は最後の dispatch だけを替え、paper/live も同じ Risk 経路を通る。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **live 約定を execution 単位で原子的に記帳し、連続部分約定の価格を正しく保つ** `+4`
  > `getexecutions` の全量と remote filled、未知 execution の合計と delta の双方を照合し（`live_fills.ex:365-410`）、各 execution の実価格・ID・取引所時刻を Order/Position/Fill の同一 DB transaction に反映する（同 `415-492`）。`(trade_mode, exchange_execution_id)` 部分一意制約もあり、前回の累積 VWAP 誤用は解決した。連続2回、途中決済、DB reload、不整合 baseline の回帰がある（`live_fills_test.exs:248-320, 641-720`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/priv/repo/migrations/20260912130000_add_fills_execution_evidence.exs`

- **submission_unknown・baseline・権限・Decode を推測で埋めず停止と承認付き復旧へ寄せる** `+4`
  > timeout は rejected にせず submission_unknown、回収は候補曖昧性と snapshot hash・operator を要求する。baseline も二段階 hash 承認で、Ready を直接上げない。private Decode は未知 side/status・ID欠落を payload 全体の error にする（`decode.ex:3-28, 133-223, 351-377`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`, `apps/bitflyer/lib/bitflyer/startup/baseline.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

- **起動突合と post-place fill 同期が受注済み／未送信を区別して halt する** `+4`
  > 起動は権限→時計→fill→内部再読→取引所 snapshot→比較の順で、未知 payload は `invalid_exchange_payload` へ分ける（`reconcile.ex:148-157, 252-268`）。発注後 fill sync 失敗は `order_accepted: true` を付けた別エラーとして `fill_sync_failed` halt にする（`live.ex:49-74`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **halt 理由別 cancel-all と再起動後再試行に背圧を持たせる** `+3`
  > `OpenOrderPolicy` は理由別方針、in-flight lock、worker monitor、失敗 backoff、永続 halt 再適用を実装する（`open_order_policy.ex:1-27, 82-130, 184-220`）。単発の best-effort で終わらず、open が消えるまで再試行可能である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`, `apps/bitflyer/lib/bitflyer/risk/open_order_policy/halt_cancel_gate.ex`

### datastore / OTP

- **永続状態を Ash/PostgreSQL、短期状態を ETS に限定し Decimal を貫く** `+3`
  > Order・Position・Fill・BalanceSnapshot・RiskState・Revision は `Bitflyer.Trading` と `Bitflyer.Repo` に閉じ、tick・頻度・残高 hold は ETS/GenServer に置く。価格・数量・損益は Decimal である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/trading/`

- **起動は not-ready から復元・突合・cache 同期を通してのみ Ready** `+4`
  > Reconciler は不整合時に先にメモリ Readiness を halt し、その後 RiskState を永続化する（`reconciler.ex:210-269`）。永続化に失敗しても稼働中の発注ゲートは閉じる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/readiness.ex`

- **SIGTERM 前の gate close・in-flight drain・unknown 化を実装する** `+3`
  > `prep_stop/1` は新規発注を閉じ、進行中 submit/cancel を待ち、timeout 時は ID 不明 pending を submission_unknown にして halt する。Compose の猶予と shutdown 予算も対応する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`, `compose.prod.yaml`

### observe

- **telemetry 語彙と秘密情報 allowlist を中央化する** `+3`
  > 取引イベントと metadata allowlist を `Bitflyer.Telemetry` に固定し、API secret・署名・Webhook URL を構造化ログ対象から外す。Discord の失敗理由も URL を redact する（`discord.ex:208-218`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **ホスト外 ready pull と通知 heartbeat の具体的な運用導線を用意する** `+2`
  > `/health/live` と `/health/ready` を再起動判定と盲目運転検知に分け、別ホスト探針、Linux/Windows exporter、Discord 起動直後＋定期 heartbeat を具体化した（`prod.md:99-181`）。未配備でも、前回の「構成未定」から実行可能な手順へ進んだ。
  >
  > 対象ファイル: `bin/watch-ready.sh`, `compose.observe.yaml`, `.workspace/0_doc/architecture/env/prod.md`

- **公開実 API corpus と発注禁止の read-only Contract を品質ゲートへ入れる** `+2`
  > ticker/executions/markets の実応答 corpus を意味論検証し、private は permissions と reconcile snapshot の GET だけに限定する（`contract.ex:3-8, 84-127`）。禁止 POST を明示し、実ホスト接続を CI に持ち込まない境界も妥当である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `apps/bitflyer/priv/contract/corpus/`

## 技術評価層 — apps/ui / 実行基盤

### Phoenix / 運用 UI

- **発注可否・exposure・復帰手順と認証付き操作を一画面に限定する** `+4`
  > StatusLive は注文可否、Feed、建玉、未約定件数/最古 age、残高、realized/unrealized/drawdown、halt 理由別手順を5秒ごとに非同期更新する（`status_live.ex:1-119, 168-420`）。kill/resume/reconcile 以外の裁量発注機能を持たず、Vision の非目標を守る。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

### Docker / config / CI

- **開発 bind mount と本番 release・非 root・loopback 公開を分離する** `+3`
  > 本番は multi-stage release、tini、非 root、DB 非公開、app loopback bind、restart、liveness healthcheck を持つ。秘密は runtime env に限定され、trade mode は dry_run 既定である。
  >
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`, `config/runtime.exs`

- **同一 precommit・本番 image build・SHA pin・advisory gate を CI/CD に結合する** `+5`
  > CI は PostgreSQL 上の `mix precommit`、本番 image build、deps audit を分離実行する。Actions は commit SHA 固定（`ci.yml:43-55, 81-94, 139-149`）、audit は advisory 検出時に fail、Dependabot は mix/Actions を更新する。CD は同一 SHA の CI 全体成功を要求する。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `.github/dependabot.yml`, `mix.exs`

## 横断評価層

### テスト / 文書

- **資金保全の故障注入と回復経路を含む522件の自動試験が全成功する** `+5`
  > Docker 正規経路の `mix precommit` は bitflyer 1 doctest + 483 tests、ui 38 tests、0 failures。部分約定、execution 重複、予約競合、drawdown、halt cancel worker 死、Decode 未知値、submission_unknown、shutdown race を含み、単純な happy path に留まらない。
  >
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`, `mix.exs`

- **Vision・Architecture・README・本番手順が安全操作へ具体的に接続する** `+2`
  > spot 限定、live confirm、baseline/recover、kill/resume、外部監視、digest rollback、Game Day をコマンドと禁止事項まで記述する。既定 `BTC_JPY` は config・README・Architecture で一致する（`config/config.exs:57-65`, `README.md:30-40`, `overview.md:111-114`）。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/prod.md`, `README.md`

**加点合計: +84**
