# docker-bitflyer 第2評価者 プラス点（2026-09-10_2）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

## 技術評価層 — apps/bitflyer

### market-data

- **鮮度付き ETS・再接続・非同期 gap-fill・stall watchdog が一つの安全経路を作る** `+3`
  > Feed は切断時の指数 backoff、接続時の再購読と REST gap-fill、WS 受信後の古い REST 応答による上書き防止、サイレントストール時の socket 再生成を実装する（`feed.ex:111-129, 190-221, 252-309, 353-398`）。Cache の受信時刻を Risk と health が共有し、「古い価格では発注しない」へ接続している。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

- **source timestamp と channel-product 対応を保持・検証する** `+2`
  > Normalize は ticker の取引所時刻を `source_timestamp` として残し、WS channel と message の product_code 不一致を拒否する（`normalize.ex:20-30, 48-65, 80-101`）。Risk は受信鮮度だけでなく壁時計との差も fail-closed で検査する（`risk.ex:205-246`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### strategy

- **Strategy → Risk → Executor の依存方向と live 安全既定をコードで強制する** `+4`
  > Runner は Strategy の command に provenance を付けて `Bitflyer.System.submit_order/1` だけを呼び（`strategy/runner.ex:350-397`）、System は必ず live fill 同期と Risk 認可を通す（`system.ex:351-368`）。live では Strategy 既定無効、FixedOnce 有効化拒否、5つの上限を環境変数必須にする（`runtime.exs:155-169`, `config/live_safety.ex:21-37, 50-77`）。前回の危険な FixedOnce live 既定は解決済みである。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **戦略 revision と注文由来を immutable に永続化する** `+3`
  > `StrategyParameterRevision` は trade mode・module・params hash・operator・適用時刻を保持し、update/destroy を公開しない（`strategy_parameter_revision.ex:22-88`）。Runner は起動時に revision を確定して Order へ revision ID・module・command hash を付ける（`runner.ex:110-127, 390-406`, `order.ex:125-143`）。後から「どの設定が注文を生んだか」を追える。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

### risk-manager

- **未同期を 0・空として扱わない fail-closed な認可網** `+4`
  > 認可順序は同期、鮮度、時計ずれ、注文量、建玉、価格乖離、頻度、日次損失、残高で固定される（`risk.ex:55-69`）。Position 読取失敗、OrderRate/DailyLoss/BalanceCache 未同期、必要通貨欠落はすべて `:unsynced` で拒否する（同 `263-287, 328-379, 390-436`）。前回の「日次損失 0・残高空で空振り」は一括約定経路では解消した。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **DailyLoss / BalanceCache の generation barrier は競合時も過大評価へ倒れない** `+4`
  > Fill 前に synced を外し generation と barrier を増やし、DB commit 後に同一 generation の reload だけを反映する（`daily_loss.ex:74-130, 221-335`）。BalanceCache も同型に加え、hold の再適用、部分約定 consume、取消時の残額返却を原子的な GenServer 境界に置く（`balance_cache.ex:115-220, 325-510, 580-614`）。reload 失敗は unsynced のままであり、改善計画 P0 #1/#2 の中心実装は堅い。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **AuthorizedOrder のワンショット境界で Risk 迂回を困難にする** `+3`
  > Risk 成功時だけ protected ETS に token を mint し、Executor は stored command・時刻・TTL を照合して `:ets.take` で一度だけ消費する（`authorized_order.ex:70-122`）。raw map、偽造 struct、再利用、期限切れを拒否する回帰もあり、単なる型名ではなく実行時 capability として成立している。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/test/bitflyer/risk/authorized_order_test.exs`

### order-executor / recovery

- **モード別出口・DB 一意冪等キー・残高 reserve を一つの Executor に集約する** `+4`
  > Executor は AuthorizedOrder だけを受け、`internal_order_id` の既存照会と DB identity 競合の双方で再送を防ぐ（`order_executor.ex:55-104, 253-296`）。残高 hold を pending 作成前に確保し、失敗種別に応じて解放・維持を分ける（同 `301-365`）。dry_run / paper / live は最後の dispatch だけを差し替え、Architecture のモード同経路原則に一致する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **submission_unknown と acceptance ID 永続化失敗を安全に止め、承認付きで回収できる** `+4`
  > timeout 等は rejected とせず `submission_unknown` にして circuit を開く（`order_executor/live.ex:178-196`）。回収は時刻窓・side・size・price、既使用 ID、候補件数超過を検査し、dry-run hash と操作者を要求する（`submission_recovery.ex:64-108, 240-309, 317-417`）。一意候補以外を自動確定せず、回収後も Ready にしない。前回の停止だけで出口がない状態は解決した。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`

- **両建て外部建玉をネット化し、列挙順依存を除いた** `+3`
  > Reconcile は同一銘柄の buy/sell を符号付き size と notional に集約してから内部ネット Position と比較する（`startup/reconcile.ex:280-377`）。未知 side・不正平均を受け取れた場合は mismatch にし、両建て時はエクスポージャの side+size を必須比較する（同 `380-467`）。前回の片側上書きによる誤 Ready は対象コード上で解決済みである。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/test/bitflyer/startup/reconcile_test.exs`

- **初回 baseline は二段階承認・監査行・transaction lock を備える** `+3`
  > baseline import は live 限定で、dry-run の残高 hash と再取得結果の一致、操作者、必須通貨欠落だけの補完を要求する（`startup/baseline.ex:50-98, 122-149, 151-227`）。永続化は advisory transaction lock 下で BalanceSnapshot と BaselineImport を同時に書き、Ready は変更しない（同 `247-360`）。人手 SQL に頼った前回状態を解消している。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/baseline.ex`, `apps/bitflyer/lib/bitflyer/trading/baseline_import.ex`

### datastore / OTP

- **永続状態を Ash/PostgreSQL に限定し、価格・数量を Decimal で統一する** `+3`
  > Order・Position・Fill・BalanceSnapshot・RiskState・StrategyParameterRevision が `Bitflyer.Trading` に集約され、各 Resource は `Bitflyer.Repo` を使う。市場 tick と認可キャッシュは ETS で、ホットパスから Ash を避ける設計も明示される（`risk.ex:8-12`）。Vision の Recoverable と Architecture の境界に素直である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/trading/`

- **起動は not-ready から復元・権限・時計・約定・突合・cache 同期を通してのみ Ready** `+4`
  > live Reconcile は API 権限、ticker 時計ずれ、未反映約定、内部再読、取引所 snapshot、建玉・残高・未約定比較を順番に実行する（`startup/reconcile.ex:140-157`）。Reconciler は cache が同期済みの場合だけ Ready にし、失敗時は先にメモリ halt、次に RiskState 永続化を行う（`startup/reconciler.ex:100-218`）。起動シーケンスが安全側で閉じている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **SIGTERM 前の gate close・in-flight drain・unknown 化を実装した** `+3`
  > `prep_stop/1` は Readiness を閉じてから InFlight を drain し、timeout 時は ID 未確定 pending を `submission_unknown` にして circuit を開く（`application.ex:50-143`）。Compose の45秒猶予と子5秒 shutdown も対応し、前回の「ゲートだけ閉じて進行中を待たない」は解決した。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`, `compose.prod.yaml`

### observe

- **telemetry 語彙と秘密情報 allowlist を中央化した** `+3`
  > 9種のドメインイベントと metadata allowlist を `Bitflyer.Telemetry` に固定し、文字列キーは existing atom だけへ変換する（`telemetry.ex:11-62, 92-149`）。API secret・署名・webhook URL を allowlist に入れず、構造化ログと metrics の語彙を揃えている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

## 技術評価層 — apps/ui / 実行基盤

### Phoenix / 運用 UI

- **運用 UI を Status・kill・再突合・resume に限定し、認証境界を持つ** `+3`
  > StatusLive は発注可否、モード、Readiness、Feed、鮮度、DB を表示し、非同期の kill/resume/reconcile だけを提供する（`status_live.ex:20-98, 143-368`）。裁量発注 UI へ踏み込まない。browser と LiveView session の双方を BasicAuth で守り、health だけを匿名 API に分離する（`router.ex:3-38`）。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/router.ex`

### Docker / config / CI・CD

- **開発 bind mount と本番 release・非 root・loopback 公開を分離した** `+3`
  > 本番 Dockerfile は multi-stage release、tini、非 root user を使い（`Dockerfile.prod:1-78`）、本番 Compose は DB を非公開、app のホスト bind を loopback、restart と healthcheck を明示する（`compose.prod.yaml:15-85`）。秘密は runtime env に限定され、既定 trade mode は dry_run である。
  >
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`, `config/runtime.exs`

- **ローカルと CI の品質ゲートを mix precommit に統一し、CD を同一 SHA の CI に結合した** `+4`
  > precommit は unused deps、format、warnings-as-errors compile、warnings-as-errors test を一入口にする（`mix.exs:42-54`）。CI は PostgreSQL と本番 image build を含み（`.github/workflows/ci.yml:14-40, 111-134`）、CD は対象 SHA の最新 ci.yml 全体が success の場合だけ GHCR push する（`cd.yml:41-72`）。digest 固定の運用導線もある。
  >
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `compose.prod.yaml`

## 横断評価層

### テスト / ドキュメント

- **資金保全の縦貫通回帰が厚く、今回の品質ゲートも全成功した** `+4`
  > 回帰は Risk 迂回、重複 intent、モード分離、reconcile halt、submission_unknown、persist失敗、DailyLoss、BalanceCache hold/consume/release を System 入口から検査する（`capital_preservation_test.exs:280-1167`）。実行した `docker compose run --rm -e MIX_ENV=test app mix precommit` は bitflyer 1 doctest + 352 tests、ui 35 tests、0 failuresで成功した。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`, `mix.exs`

- **Vision・Architecture・README・本番手順がコードの安全操作へ具体的に接続する** `+2`
  > baseline、submission recovery、kill、resume、release rpc、backup/restore、digest rollback が具体的なコマンドと禁止事項で文書化される（`architecture/env/prod.md:100-208, 221-289`）。README も risk を partial、含み損未計上、audit の非保証まで明記し、以前の過大表示を是正した（`README.md:21-43, 107-116`）。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `README.md`

**加点合計: +66**
