# docker-bitflyer 第2評価者 提案（2026-09-16）

| 点数 | 基準 |
|:---:|:---|
| 0 | 現状の欠陥とはせず、実装すれば価値が上がる次段階 |

## 技術評価層 — apps/bitflyer

### market-data / risk-manager

- **板厚・取引所 health / board state ゲート** `0`
  > bid/ask spread まで入った次は、`getboardstate`、`gethealth`、板スナップショットの一定量までの厚みを成行認可へ加えると、狭い見かけ spread でも数量を吸収できない局面を拒否できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **private execution WebSocket を同期トリガーに併用** `0`
  > REST `getexecutions` を正本に維持しつつ、private event を即時同期トリガーにすれば、部分約定から Position/hold/DailyLoss 反映までの遅延を短縮できる。イベント欠落時は現行周期 REST に戻す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

### strategy

- **live-approved revision の canary と段階上限** `0`
  > revision ごとに paper soak期間、初期限度、失敗時ロールバック条件を持たせ、`BITFLYER_STRATEGY_ENABLED` の一括切替より段階的に解禁するとよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

## 横断評価層

### テスト戦略

- **残高会計のプロパティ／状態機械試験** `0`
  > side、部分約定順、fee通貨、丸め、複数open、再起動位置を生成し、「取引所 amount = baseline + execution delta」「execution は一度だけ」を状態機械で検証すれば、実装とハーネスが同じ誤りを共有するリスクを下げられる。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

### 可観測性

- **Prometheus / OpenTelemetry と SLO** `0`
  > ready率、Feed切断時間、reconcile mismatch、約定同期遅延をホスト外へ時系列保存し、SLOとアラート閾値を定義すると24/365の傾向を説明できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `compose.observe.yaml`

- **重要通知の有限 retry と delivery 証跡** `0`
  > halt/mismatch 通知を有限 backoff で再試行し、最終失敗をローカル spool または別監視へ残すと、HTTP Task の一回失敗で重要通知を失う確率を下げられる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

### security / release

- **SBOM・署名・provenance を digest 配布へ接続** `0`
  > release image の SBOM、cosign署名、artifact attestationを Compose digest固定へつなげれば、CIを通ったソースと本番 image の同一性をより強く説明できる。
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `Dockerfile.prod`

### 運用

- **Windows / WSL2 の長時間 soak を定型化** `0`
  > 本番想定の Windows 11 + WSL2 で、時刻補正、Docker再起動、Windows Update後、ネットワーク断復帰を含む72時間以上の paper soakを記録すると、コード単体では見えないホスト固有リスクを早期に潰せる。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `.workspace/0_doc/architecture/env/game-day.md`

**提案数: 8**
