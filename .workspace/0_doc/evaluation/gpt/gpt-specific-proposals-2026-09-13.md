# docker-bitflyer 第2評価者 提案（2026-09-13）

| 点数 | 基準 |
|:---:|:---|
| 0 | 現状の欠陥とはせず、実装すれば価値が上がる次段階 |

## 技術評価層 — apps/bitflyer

### market-data / risk-manager

- **板・spread・取引所 health の流動性ゲート** `0`
  > 現状は ticker LTP と指値乖離を安全網にしている。`getboardstate`、best bid/ask、spread、板厚を Risk 入力へ追加すれば、薄商い・BUSY 時の market order をより安全に拒否できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/market_data/`

- **private execution WebSocket を早期検知へ併用** `0`
  > REST `getexecutions` を正本のまま維持しつつ、private order event を同期トリガーにすれば、部分約定から Position/hold/DailyLoss 反映までの遅延を短くできる。イベント欠落時は現在の周期 REST に戻す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

### strategy

- **live-approved strategy の canary と段階上限** `0`
  > FixedOnce を live 禁止にした判断は正しい。次は strategy revision ごとに paper soak、最小上限、期間、ロールバック条件を持たせ、`BITFLYER_STRATEGY_ENABLED` の一発切替より段階的に解禁するとよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

## 横断評価層

### テスト戦略

- **残高会計のプロパティ／モデルベース試験** `0`
  > side、部分約定順序、fee 通貨、丸め、複数 open、再起動位置を生成し、「取引所 amount = baseline + execution delta」「同じ execution は一度だけ」を状態機械で検証すると、今回のような fixture 同士の誤一致を減らせる。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

### 可観測性

- **Prometheus/OpenTelemetry と明示 SLO** `0`
  > ConsoleReporter と LiveDashboard に加え、ready 率、Feed disconnect、reconcile mismatch、注文同期遅延をホスト外へ蓄積し、SLO とアラート閾値を決めると 24/365 の傾向を説明できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `compose.observe.yaml`

- **重要通知の有限 retry と dead-letter 証跡** `0`
  > Discord は発注非依存でよい。一方、halt/mismatch の delivery failure を有限 backoff で再試行し、最終欠落をローカル spool または別監視へ残すと通知経路の観測性が上がる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

### datastore / 運用

- **Fill・snapshot の retention/compact 方針** `0`
  > 24/365 では execution と BalanceSnapshot が増え続ける。監査保持期間、日次集約、削除しない期間、VACUUM/容量 alert を先に文書化すると長期運用判断が明確になる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

### security / supply chain

- **SBOM・署名・provenance の配布連鎖** `0`
  > release image の SBOM、cosign 署名、GitHub artifact attestation を digest 配布へ接続すれば、「CI を通ったソースと本番 image が同じ」をより強く証明できる。
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `Dockerfile.prod`

**提案数: 8**
