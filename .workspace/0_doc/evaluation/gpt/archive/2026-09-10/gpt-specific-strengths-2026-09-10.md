# docker-bitflyer 第2評価者 プラス点（2026-09-10）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

## 技術評価層 — apps/bitflyer

### market-data / cache

- **再接続・REST 穴埋め・鮮度付き ETS が一続きになっている** `+3`
  > `Feed` は切断を telemetry 化し指数 backoff で再接続する。接続時の REST gap-fill は `Task.Supervisor` へ逃がし、開始後に届いた WS tick を古い REST 結果で上書きしない。`put_tick/4` は Cache、telemetry、Strategy 通知を一つの入口に集約している（`feed.ex:150-179, 211-264, 286-297`）。
  >
  > コード例: `received_at >= gap_fill_started_at` なら gap-fill を捨てる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

### strategy

- **Feed → Strategy → Risk → Executor の縦貫通骨格が実装された** `+2`
  > `Strategy` behaviour、純関数の `FixedOnce`、駆動役 `Runner` が分離された。Runner は起動時に既存注文 ID を読み、ロード前 tick と滞留 tick を捨て、成功済み ID を再送しない（`runner.ex:64-123, 145-189, 343-365`）。戦略から取引所 API を直接呼ばない依存方向も保たれている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy.ex`, `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### risk-manager

- **発注前検査を単一の fail-closed 経路へ集約した** `+4`
  > `Risk.authorize/2` は同期、鮮度、注文量、予測建玉、価格逸脱、頻度、日次損失、残高を順に検査する（`risk.ex:43-70`）。建玉ロード失敗は空扱いせず `:unsynced`、LTP 欠落も `:stale` とする（`risk.ex:191-193, 225-229`）。公開 submit は常に Risk を呼び、旧 `authorize?: false` を渡しても迂回できない（`order_executor.ex:43-60`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

### order-executor

- **submission 不明と受注 ID 永続化失敗を即時 halt へ倒した** `+4`
  > timeout・切断等は `rejected` ではなく `submission_unknown` に更新し、永続 RiskState と Readiness のサーキットを開く（`live.ex:130-147`）。受注成功後の `exchange_order_id` 更新失敗も critical ログの後に `:persist_failed` で halt する（`live.ex:45-85`）。回帰テストは注文状態、永続 halt、後続 REST が増えないことまで固定している（`order_executor_test.exs:376-440, 477-530`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/test/bitflyer/order_executor_test.exs`

- **DB 一意キーと事前永続化による冪等境界が明確** `+3`
  > `internal_order_id` は Ash identity で一意、executor は REST より先に pending 行を作り、競合時も既存行を返す（`order.ex:133-135`, `order_executor.ex:179-214`）。同一 ID の再 submit は `:idempotent` となり、paper 建玉も live REST も二重適用されない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **署名付き private REST と取消・照会・約定反映が実装された** `+3`
  > Req を使い、署名対象と同じ query/body を送る。自動 retry は無効化され、POST の 5xx・transport error は submission unknown 側へ渡る（`rest.ex:248-282`, `rest/http.ex:11-30`）。取消前後と発注前に約定を同期し、差分だけを Position にトランザクション反映する（`live_fills.ex:21-37, 220-263`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/exchange/auth.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`

- **paper 約定を同一トランザクションで整合更新する** `+3`
  > market は LTP、limit は交差時だけ約定し、Order・Position・BalanceSnapshot を同一 Repo transaction で更新する（`paper.ex:16-67, 70-100`）。残高 append は通貨順の PostgreSQL advisory transaction lock で直列化し、同時 buy/sell の lost update と deadlock を防いでいる（`balances.ex:24-49, 71-81`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`, `apps/bitflyer/test/bitflyer/order_executor_test.exs`

### datastore / OTP

- **永続状態を Ash/PostgreSQL、ホット状態を ETS に限定している** `+2`
  > Order、Position、BalanceSnapshot、RiskState を `Bitflyer.Repo` に閉じ、ticker と readiness、発注頻度は ETS に置く。価格・数量は Resource 上で Decimal かつ正値制約がある（例: `order.ex:97-117`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`, `apps/bitflyer/lib/bitflyer/readiness.ex`

- **live 起動突合と fail-closed Readiness が実装されている** `+4`
  > live は約定同期後に DB を再読し、残高・建玉・未約定を取引所 snapshot と比較する（`reconcile.ex:149-187`）。必須通貨 baseline が無ければ空リストを成功扱いしない（`reconcile.ex:244-279`）。Readiness は起動時 `:not_ready`、ETS 消失時も `:not_ready`、halted から直接 ready に戻せない（`readiness.ex:145-171, 244-248`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/readiness.ex`

- **停止ゲートと再突合付き手動 resume が用意された** `+2`
  > `Application.prep_stop/1` は終了前に新規発注ゲートを閉じる（`application.ex:44-67`）。`Startup.Resume` は永続 halt がある場合だけ再突合し、成功後に限り Circuit を閉じて Ready にする（`resume.ex:22-89`）。release では同一 BEAM へ RPC する運用手順も記載されている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`, `apps/bitflyer/lib/mix/tasks/bitflyer.resume.ex`

## 技術評価層 — observe / apps/ui

### 可観測性

- **telemetry 語彙・allowlist・非同期 Discord 通知を統合した** `+3`
  > 取引イベント名は `Bitflyer.Telemetry` に集約され、Logger metadata は秘密を含まない allowlist のみ（`telemetry.ex:23-55, 89-143`）。Discord は発注木の兄弟 GenServerで、未設定・送信失敗でも取引を止めず、URL をログに出さない（`discord.ex:117-163`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **liveness と readiness を分離し blind operation を外形検知できる** `+3`
  > `/health/live` はプロセス生存、`/health/ready` は DB・Readiness・Feed 接続・全銘柄鮮度を判定する（`health.ex:60-71, 218-228`）。Compose は liveness だけで再起動し、WS 断は readiness 503 とするため、不要な再起動と盲目運転検知を分離している。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`, `compose.prod.yaml`

### UI / セキュリティ

- **Status UI と本番 BasicAuth・公開面最小化が実装された** `+3`
  > UI 最上部に ALLOWED/STOPPED、理由、モード、Readiness、Feed、tick age を表示する（`status_live.ex:69-210`）。prod は BasicAuth 資格情報が無ければ起動せず、LiveView on_mount でも session を検査する（`runtime.exs:170-210`, `router.ex:31-38`）。本番 Compose のホスト公開は loopback 既定である。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/plugs/basic_auth.ex`, `apps/ui/lib/ui_web/hooks/basic_auth.ex`, `config/runtime.exs`, `compose.prod.yaml`

## 技術評価層 — 実行基盤 / 横断評価

### Docker / config / CI/CD

- **三重 live ゲートと秘密情報の fail-closed 設定** `+4`
  > `TRADE_MODE=live`、UTC 当日の `BITFLYER_LIVE_CONFIRM`、Readiness が揃うまで実発注しない。live の API key/secret 欠落は test 以外で起動停止し、それ以外のモードは `Unavailable` client を既定にする（`runtime.exs:80-157`）。`.dockerignore` は `.env*`、Git、作業文書を build context から除外する。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`, `.dockerignore`

- **非 root release、digest 配布、backup/rollback の本番形がある** `+3`
  > `Dockerfile.prod` は multi-stage release で runner を非 root 化し、tini で signal を転送する（`Dockerfile.prod:42-79`）。CD は明示タグまたは手動だけで GHCR へ push し digest を出力する（`cd.yml:1-29, 63-80`）。本番 Compose は DB 非公開、app loopback 公開、45 秒停止猶予を設定している。
  >
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`, `.github/workflows/cd.yml`, `bin/deploy-prod.sh`, `bin/backup-db.sh`

- **テストと単一品質ゲートが安全要件を回帰固定している** `+4`
  > ルート `mix precommit` は unused deps、format、warnings-as-errors compile/test を両アプリへ適用する（`mix.exs:43-54`）。CI も PostgreSQL service 上で同じ入口を実行する。資金保全回帰は冪等、モード分離、突合 halt、risk 拒否、submission unknown、ID 永続化失敗、残高 baseline、risk 迂回を縦貫通で検証する（`capital_preservation_test.exs:1-15`）。
  >
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`, `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

### プロジェクト全体設計

- **Vision と実装境界をつなぐ運用文書が充実した** `+2`
  > Architecture は Readiness 正本、3 モード、health 分離、通知、UI 認証を具体化し、prod 文書は停止・resume・release RPC・backup/restore・digest rollback を実行単位で記述している。自己改善計画の P0〜P3 と対象コードの対応も追跡可能である。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/prod.md`, `.workspace/0_doc/evaluation/improvement-plan.md`

**加点合計: +49**
