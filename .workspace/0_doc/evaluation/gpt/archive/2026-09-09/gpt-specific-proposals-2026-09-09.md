# docker-bitflyer 第2評価者 提案（2026-09-09）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

必須欠如として減点した risk、live lifecycle、shutdown、本番 release 等の修正そのものは重複掲載せず、その先の品質向上策を記す。

## 技術評価層 — apps/bitflyer

### strategy / risk

- **認可済み command を型で表現する** `0`
  > `Risk.authorize/2` が成功時に `%AuthorizedOrder{command, decision_id, limits_revision, authorized_at}` を返し、OrderExecutor はこの型以外を受け取らないようにすると、risk bypass をコンパイル時・関数境界で発見しやすい。decision ID は注文・telemetry・監査ログの相関にも使える。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **金額・数量・建玉合成のプロパティテスト** `0`
  > StreamData 等で Decimal の境界値、買い増し、縮小、全決済、ドテンを生成し、「上限超過を許可しない」「同じ fill を二度適用しない」「position size は正」を性質として検証すると、例示テストが拾いにくい資金計算バグを発見できる。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/`

### order-executor / recovery

- **Transactional outbox と submission state machine** `0`
  > 発注意図の永続化と送信要求を同一 transaction に置き、専用 worker が `prepared → submitting → acknowledged / unknown / rejected` を進める outbox にすると、BEAM crash・DB 一時断・外部 timeout の組合せを決定的に再開できる。将来の実 client 実装で最も価値が高い回復モデルになる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **状態機械のモデルベース障害試験** `0`
  > 発注前、送信中、取引所受注後、ID 永続化前、部分約定後の各点で process / DB / socket を落とし、再起動後に二重発注せず事実へ収束することを state-machine test で確認する。単体 mock の成功・失敗二値より Recoverable を強く証明できる。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`

### market-data

- **ticker 記録再生による契約テスト** `0`
  > bitFlyer の REST / WebSocket payload を秘密除外して fixture 化し、schema 変更、欠損、順序逆転、重複、極端値を replay する。実ネットへ接続しない CI のまま normalize と stale gate の互換性を継続確認できる。
  >
  > 対象ファイル: `apps/bitflyer/test/fixtures/`, `apps/bitflyer/test/bitflyer/market_data/`

## 技術評価層 — apps/ui

### 運用操作性

- **OperationalStatus の単一スナップショット API** `0`
  > DB、Readiness、live confirm、market age、Feed、最終突合、RiskState、未確定注文を一度に読む read model を bitflyer 側に置くと、StatusLive と `/ready` の判定ずれを防げる。UI は `trading_allowed?` と reasons を表示するだけになり、責務境界も明瞭になる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/ui/lib/ui_web/live/status_live.ex`

- **PubSub による状態変化の即時反映** `0`
  > readiness / circuit / feed disconnect / order lifecycle を Phoenix.PubSub へ投影し、5秒 polling を補完すると、halt を運用画面へ即時表示できる。定期 refresh は取りこぼし回復として低頻度で残せる。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui/application.ex`

## 技術評価層 — 実行基盤 / 設定

### production operations

- **バックアップ restore を CI 外の定期ジョブで実証する** `0`
  > バックアップの存在確認だけでなく、一時 PostgreSQL へ restore し、migration・突合 query・件数 checksum を通す。資金状態のバックアップは「復元できること」まで検証して初めて Recoverable の根拠になる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `.github/workflows/`

- **release の SBOM・署名・digest 固定** `0`
  > 本番 image 作成後に SBOM と provenance を生成し、Compose は tag ではなく digest で固定する。VLAN1 の本番PCへ投入した成果物とレビュー済み commit の対応を追跡できる。
  >
  > 対象ファイル: `Dockerfile`, `compose.prod.yaml`, `.workspace/2_todo/03-cd-prod-host.md`

## 横断評価層

### 可観測性 / 運用検証

- **paper Game Day と通知到達試験** `0`
  > WebSocket 切断、REST 429 / 5xx、DB 再起動、時刻ずれ、ディスク逼迫、通知先障害を定期的に注入し、発注停止・自動復帰または halted・通知到達を確認する。コードテストだけでは証明できない 24/365 の運用経路を検証できる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/dev.md`, `.workspace/0_doc/architecture/env/prod.md`

- **安全要件の traceability matrix** `0`
  > Vision の各原則を、実装ファイル、テスト、metric、runbook、live 解禁可否へ対応付ける。現在のような急速な実装期でも README の状態乖離や、実装済みだが運用未検証の項目を機械的に見つけやすくなる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/`

**提案件数: 11（0点）**
