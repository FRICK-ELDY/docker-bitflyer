# docker-bitflyer 第2評価者 マイナス点（2026-09-12）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | 損失・二重発注・状態不整合を起こしうる明確な欠陥 |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥 |

## 技術評価層 — apps/bitflyer

### datastore / live reconciliation

- **live 約定後の残高正本を前進させる経路がなく、次回突合・再起動で恒久 halt する** `-5`
  > live 約定は execution 単位で Order・Fill・Position を更新する一方、`LiveFills` は「残高: 触らない」と明記する（`live_fills.ex:3-7`）。live の `BalanceSnapshot` を作る実装は初回 `Baseline.import/1` だけで、通常約定後の append はない。それにもかかわらず突合は内部 tip と取引所 `getbalance` の `amount` / `available` の完全一致を要求する（`reconcile.ex:486-548`）。したがって一度約定して BTC/JPY 残高が変わると、60秒周期または再起動後の突合は `balance_mismatch` で停止する。baseline は「tip が無い通貨だけ」を対象とするため（`baseline.ex:3-8`）、既存 tip の安全な更新経路にもならない。これは安全側停止ではあるが、Vision の「状態を失わず再開」「24時間365日」を満たさず、live は一約定ごとに運用不能になる。
  >
  > 改善方針: execution と手数料から期待残高差分を作り、取引所 snapshot と一致した場合だけ新しい `BalanceSnapshot` tip を同一の監査トランザクションで append する。外部入出金等の説明不能差分は従来どおり halt し、承認付き re-baseline 経路を別に設ける。約定→周期突合→再起動→Ready の縦貫通試験を追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

### risk-manager / 損失意味論

- **live の損益・ドローダウンが取引手数料を含まず、測っている equity が口座残高と一致しない** `-3`
  > `Positions.realized_pnl/4` は売買価格差×決済数量だけであり（`positions.ex:153-163`）、live Fill には execution の価格・数量しか渡さない（`live_fills.ex:465-492`）。`Risk.Equity` も `DailyLoss` の realized net と内部 Position×LTP のみを合成する（`equity.ex:50-75`）。paper は fee bps を価格へ織り込むが、live は `gettradingcommission` も実残高差分も損失へ反映しない。小さな優位性の戦略ほど、gross は上限内でも net が超過しうる。
  >
  > 改善方針: execution ごとの実手数料または取引所残高差分から fee を永続化し、Fill の net realized PnL、DailyLoss、Equity、Status を同じ net 値へ統一する。手数料通貨が BTC の場合も JPY mark へ換算する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

### market-data / 発注ゲート

- **Feed 切断直後も Risk はキャッシュ期限まで認可し、Status の STOPPED と実発注可否が一致しない** `-2`
  > `OperationalStatus` は Feed 接続を含む共通 classifier で STOPPED にする一方、自身の moduledoc が「`Risk.authorize/2` は Cache 鮮度のみ」「切断直後〜stale まで authorize が通りうる」と明記する（`operational_status.ex:10-15`）。実際、`System.submit_order/2` は fill 同期後に直接 `Risk.authorize/2` を呼び（`system.ex:382-396`）、Risk の鮮度検査は `Cache.fresh?/3` のみである（`risk.ex:278-286`）。表示と `/health/ready` を統一した P1 #9 は解決したが、発注経路の正本はまだ別である。
  >
  > 改善方針: MarketData 有効時は `OperationalStatus.market_feed_gate/2` 相当を Risk または TradeMode の直前ゲートにも入れ、Feed process 不在・disconnected を即時拒否する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **WebSocket 購読 ACK を追跡せず、socket 書込み成功を購読成立として扱う** `-2`
  > `subscribe_all/1` は `socket_client.subscribe/2` が `:ok` なら `subscribe_count` を増やすだけで（`feed.ex:232-249`）、JSON-RPC response id、error、ACK timeout、銘柄別成立集合を持たない。stall watchdog も接続上のフレームで更新されるため、対象 ticker の購読だけ失敗した状態の自己修復を保証できない。最終的に鮮度で発注拒否する点は安全だが、24/365 の復旧性は不足する。
  >
  > 改善方針: request id ごとに ACK/error/timeout を管理し、全設定チャネルの ACK が揃うまで Feed を connected-ready としない。銘柄別の最終有効 tick でも再購読を駆動する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`

### order lifecycle

- **未約定期限機構は実装されたが既定 `:infinity` かつ runtime 設定経路がなく、無人運用では無効** `-2`
  > `cancel_aged_opens/1` と周期呼出しは存在するが、設定は `max_open_age_ms: :infinity`（`config/config.exs:20-24`）で、`runtime.exs` に環境変数上書きがない。`OpenOrderPolicy` も `:infinity` なら即 `:ok` を返す（`open_order_policy.ex:50-69, 140-144`）。halt 理由別 cancel-all は前進したが、通常運転中の GTC 注文はソース変更・再ビルドなしには無期限で残る。
  >
  > 改善方針: `BITFLYER_MAX_OPEN_AGE_MS` または戦略・注文単位 TIF を起動時検証付きで追加し、live では有限値を必須にする。期限到来→取消→終端確認→hold 解放を縦貫通で固定する。
  >
  > 対象ファイル: `config/config.exs`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`

## 技術評価層 — observe / 実行基盤

### 可観測性

- **外部監視は手順と探針までで、実配備・永続時系列・通知再送は閉じていない** `-2`
  > `prod.md:99-181` は別ホスト ready pull、exporter、Discord heartbeat を具体化し、`bin/watch-ready.sh` もある。ただし文書自身が「別ホストのジョブが実際に動いているかは live チェックリスト」とする（`prod.md:130`）。アプリ metrics の外部 scrape は未導入で、Discord は `Task.start/1` の一回送信、失敗時はログのみ（`discord.ex:166-187`）。ホスト死検知の設計はできたが、24/365 の到達保証はまだ運用証跡がない。
  >
  > 改善方針: 本番外ホストの常駐 monitor/exporter scrape を IaC または運用証跡として管理し、アラート到達試験を定期実行する。重要通知は有限 retry と別経路へ送り、欠落をメトリクス化する。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `bin/watch-ready.sh`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

### テスト戦略 / API 契約

- **契約試験と Game Day は Stage 0 の公開 API だけが実施済みで、private snapshot・障害復旧・最小ロットは未証明** `-2`
  > Contract は公開 ticker/executions/markets と任意 private snapshot を検査する（`contract.ex:84-127`）が、コミット済み corpus は公開3種だけである。実施記録も Stage 0、`--private` skipped、障害注入なし、ready/復帰対象外（`game-day.md:100-116`）。今回の live 残高 tip 不前進は private snapshot と約定後再突合の試験が無いため見逃された。fixture より前進したが、「実 API contract / Game Day 完了」は部分解決である。
  >
  > 改善方針: 秘密を保存せず private GET の日時・結果要約を署名付き証跡にし、paper Stage 2 を実施する。残高正本修正後に最小ロット約定→手数料→周期突合→再起動を Stage 3/4 として記録する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `apps/bitflyer/priv/contract/corpus/`, `.workspace/0_doc/architecture/env/game-day.md`

### セキュリティ / supply chain

- **Hex 以外の依存脆弱性は監査ゲート外** `-1`
  > Actions は commit SHA 固定、Dependabot も導入済みで前回より改善した。一方 `mix deps.audit` は Hex advisory のみで、GitHub tag 依存の `heroicons` / `daisyui`（`apps/ui/mix.exs:51-61`）やコンテナ OS を脆弱性判定しないことを README も明記する（`README.md:110-117`）。
  >
  > 改善方針: lock/コンテナ/SBOM を対象にした scanner を追加し、critical/high の扱いと例外期限を定義する。
  >
  > 対象ファイル: `apps/ui/mix.exs`, `.github/workflows/ci.yml`, `README.md`

**減点合計: -19**
