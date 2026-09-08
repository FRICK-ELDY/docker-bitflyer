# docker-bitflyer 第2評価者 プラス点（2026-09-09）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがない卓越した実装 |

## 技術評価層 — apps/bitflyer

### market-data / cache

- **再接続・再購読・REST 穴埋め・stale 拒否が縦につながった** `+3`
  > Feed は WebSocket 切断を telemetry 化し、指数 backoff で再接続して全チャネルを再購読する。接続時の REST gap-fill は Task.Supervisor へ逃がし、開始後に届いた新しい WebSocket tick を古い REST 結果で上書きしない。ETS table 消失・miss・期限切れは `fresh?/3` が false とし、Risk の拒否へ接続されている。切断→再購読→穴埋めと stale risk 拒否をテストでも固定しており、前回の全面未実装から大きく進んだ。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`, `apps/bitflyer/test/bitflyer/market_data/feed_test.exs`

### TradeMode / Readiness

- **live を三重条件で fail-closed にした** `+3`
  > `TRADE_MODE` を atom に正規化し、許可値以外は runtime 起動時に raise する。取引所発注は current mode が live、UTC 当日の confirm、Readiness ready の三条件が揃う場合だけ許可される。dry_run / paper の非送信と各 halt 理由がテストで固定されている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trade_mode.ex`, `config/runtime.exs`, `apps/bitflyer/test/bitflyer/trade_mode_test.exs`

### 起動復元 / 突合

- **復元・モード別突合・永続 halt を実装した** `+3`
  > Startup.Reconcile は RiskState、建玉、最新残高、未確定注文を復元し、live では取引所 snapshot と Decimal で比較する。不一致・取引所不通・復元失敗は Readiness を即時 halt して RiskState に永続化し、成功しても既存 halt を自動解除しない。定期突合も起動時と同じ関数を使うため、復帰ロジックの二重化を避けている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/test/bitflyer/startup/reconcile_test.exs`

### risk-manager

- **単一の fail-closed 認可境界と永続サーキットを置いた** `+3`
  > `Risk.authorize/2` は command 妥当性、Ready、stale、注文サイズ、予測建玉を順番に検査し、建玉 DB 読取失敗を空扱いせず unsynced で拒否する。サーキットはメモリを先に halt してから DB に永続化し、解除は DB を先に更新してから Readiness を not_ready に戻す。この順序は部分失敗時も発注側を閉じる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

### order-executor

- **冪等キーとモード別出口を DB 制約まで実装した** `+3`
  > 内部注文 ID の DB unique identity を冪等キーとし、競合時も既存行を再読して二重 dispatch を避ける。dry_run は記録のみ、paper は取引所を呼ばず Order と Position を同一 transaction で更新し、live だけが exchange facade へ到達する。非送信・重複 intent・モード分離は spy を使ったテストで固定されている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/dry_run.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/test/bitflyer/order_executor_test.exs`

### datastore / Ash

- **復帰に必要な主要状態を Decimal で永続化した** `+3`
  > Order、Position、BalanceSnapshot、RiskState が Bitflyer.Trading Domain と PostgreSQL migration に追加された。価格・数量・残高は Decimal、内部注文 ID と銘柄×モードの identity は DB unique index になり、paper と live の建玉も分離される。Ash は永続状態に限定され、市場データ hot path は ETS に留まる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/priv/repo/migrations/20260908103016_add_trading_resources.exs`

### observe

- **取引 telemetry 語彙と秘密除外を正本化した** `+2`
  > market disconnect、risk rejection、order、reconcile、circuit、readiness、health のイベント名を `Bitflyer.Telemetry` に集約し、metadata は allowlist だけを通す。文字列 key は既存 atom のみに変換するため atom leak も避ける。UI metrics と Logger metadata が同じ語彙へ接続された。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `config/config.exs`, `apps/ui/lib/ui_web/telemetry.ex`

### OTP / Application 境界

- **取引基盤を監督ツリーに載せ UI と兄弟分離した** `+1`
  > Repo、Readiness、ETS owner、TaskSupervisor、Reconciler、Feed が bitflyer の supervisor 配下に入り、Phoenix Endpoint は別 Application の supervisor にある。UI 障害が取引木を直接再起動する構造ではない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

## 技術評価層 — apps/ui

### Phoenix / LiveView

- **運用閲覧に責務を限定し依存方向を維持** `+2`
  > StatusLive は bitFlyer API や Repo を直接呼ばず、`Bitflyer.System` の公開関数だけから状態を取得する。裁量発注 UI に踏み込まず、Endpoint と取引監督の境界を壊していない。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

### health

- **専用 `/health` が DB 断・halt を 503 にする** `+2`
  > Health は DB と Readiness の同一 snapshot を JSON 化し、DB エラー本文を公開レスポンスや telemetry metadata から除外する。Controller は unhealthy を telemetry と構造化ログに残し、Compose も `/health` を参照する。前回の「正常画面の HTTP 200だけを見る」問題は解決した。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`, `compose.yaml`

### 運用操作性

- **Ready 状態と停止理由を画面へ出した** `+2`
  > mode と DB だけだった前回から、`not_ready` / `ready` / `halted:reason` を同じ正本から表示するようになった。主要 DOM ID と halt reason の LiveView test もあり、最低限の停止理由は運用者が確認できる。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/test/ui_web/live/status_live_test.exs`

## 技術評価層 — 実行基盤 / 設定

### CI / precommit

- **ローカルと GitHub Actions の品質ゲートを統一した** `+3`
  > Umbrella ルートの `precommit` は test 環境で unused deps、format check、warnings-as-errors compile、warnings-as-errors test を両アプリに実行する。GitHub Actions は PostgreSQL 16 service と専用 test DB を用意し、同じ `mix precommit` を PR / main push で呼ぶ。評価時のコンテナ実行は 85 + 10 tests、失敗 0 で通過した。
  >
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

### Docker Compose / DX

- **開発 Compose の再現性と安全な既定が揃う** `+3`
  > app / db、localhost 限定 publish、DB health dependency、restart policy、名前付き deps / build volume、任意 `.env`、dry_run 既定が一貫する。entrypoint は常駐時だけ DB 待ちと Ash setup を実行し、単発 mix を素通しする。`docker compose config --quiet` も成功した。
  >
  > 対象ファイル: `compose.yaml`, `bin/docker-entrypoint.sh`, `Dockerfile`

### 環境分離 / ビルドコンテキスト

- **test DB 分離と `.dockerignore` を実装した** `+2`
  > test は `TEST_DATABASE_URL` を優先し、未設定でも development DB 名を `_test` へ寄せる。`.dockerignore` は `.env*`、Git、workspace、deps、build、鍵類を除外し、将来の production COPY に秘密やローカル成果物を混入しにくくした。
  >
  > 対象ファイル: `config/runtime.exs`, `.env.example`, `.dockerignore`

## 横断評価層

### テスト戦略

- **資金保全の縦貫通回帰を CI で固定した** `+3`
  > 前回の生成テスト中心から、重複 intent、paper/live 分離、永続 halt、stale、上限拒否、非送信、突合不一致、ETS 消失、telemetry sanitization まで拡充された。`capital_preservation_test.exs` は部品テストとは別に安全要件の縦貫通を固定している。評価時は bitflyer 85 tests + doctest、ui 10 tests が全成功した。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`, `apps/bitflyer/test/`, `apps/ui/test/`

### プロジェクト全体設計

- **資金保全中心の設計が短期間でコードと検証へ接続された** `+3`
  > Vision / Architecture は Safety first、Recoverable、Observable、Environment split、Least privilege、Idempotent actions を具体化している。今回は TradeMode、Readiness、永続状態、突合、stale risk、冪等 executor、health、telemetry、CI がその語彙どおりに実装され、前回の「文書だけ」という最大の隔たりを大きく縮めた。
  >
  > 対象ファイル: `.workspace/0_doc/vision.md`, `.workspace/0_doc/architecture/overview.md`, `apps/bitflyer/lib/bitflyer/`

**加点合計: +41**
