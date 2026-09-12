# docker-bitflyer 第2評価者 マイナス点（2026-09-10_2）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

## 技術評価層 — apps/bitflyer

### order-executor / 日次損失

- **live の複数回部分約定で増分約定価格を誤り、建玉平均と日次損失を壊す** `-5`
  > `LiveFills.apply_order_info/3` は取引所の累積 `filled_size` から差分 `delta` を求める一方、`fill_price/3` は取引所が返す累積 `average_price` をそのまま差分約定の価格として採用する（`live_fills.ex:157-179`）。そして `delta_order.size = delta` を `Positions.apply_fill/2` に渡す（同 `220-233`）。例えば 0.01 BTC が 100 円、次の 0.01 BTC が 200 円で約定し累積平均 150 円になった場合、2回目の差分を 150 円で記録するため、内部平均は 125 円になる。本来は累積約定代金差から増分価格 200 円を復元すべきである。この誤差は `Fill.realized_pnl` 正本へ伝播し、改善計画 P0 #1 の「日次損失の実効化」は全量一括約定では直ったが、部分約定を含む本番経路では未解決である。既存テストは単発の部分約定しか通しておらず、累積平均が変化する連続部分約定を検証していない。
  >
  > 改善方針: Order または Fill に累積約定代金を保持し、`incremental_notional = remote_avg * remote_filled - local_notional`、`incremental_price = incremental_notional / delta` で差分価格を算出する。2回以上の部分約定、途中決済、再起動を挟むケースを縦貫通テストに追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/test/bitflyer/order_executor/live_fills_test.exs`

- **損失上限は実現損のみで、約定直後には停止せず次回認可まで超過状態を許す** `-3`
  > `DailyLoss` は当日 `Fill.realized_pnl` の合計だけを読み（`daily_loss.ex:381-393`）、含み損・資金調達料・手数料・証拠金維持率を見ない。さらに Fill 後の処理はキャッシュを reload するだけで、上限超過時にその場で circuit を開かない（`daily_loss_sync.ex:45-71`）。停止するのは次の `Risk.authorize/2` が `check_daily_loss/2` を通った時である（`risk.ex:345-363`）。README は「含み損は未計上」と正直になったが、Vision の「損失上限を超えたら取引を止める」には部分達成である。
  >
  > 改善方針: Fill コミット後の reload 結果で上限を再評価して即 halt し、live では collateral・未実現損益・手数料を含む account-equity 系ゲートを別に設ける。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/order_executor/daily_loss_sync.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### risk-manager

- **FX_BTC_JPY に現物 JPY/BTC 残高モデルを適用し、証拠金リスクを検査していない** `-5`
  > 既定銘柄は `FX_BTC_JPY`（`config/config.exs:26-36`）だが、買いでは `quote_currency` の JPY、売りでは `base_currency` の BTC を必要残高として比較・拘束する（`risk.ex:100-119, 390-436`）。bitFlyer FX/CFD の発注余力は現物 BTC 保有量ではなく collateral・レバレッジ・必要証拠金に依存する。README 自身も `getcollateral` / `getcollateralaccounts` を未実装と記す（`README.md:160-169`）。したがって BalanceCache の hold/reserve は原子的に動くものの、live の主対象に対する資金保全指標が違う。売り注文を現物 BTC 不足で誤拒否し、逆に証拠金維持率悪化を検出できない。
  >
  > 改善方針: Product 種別を spot / CFD に分け、CFD は `getcollateral` 等から証拠金・評価損益・必要証拠金を同期した専用 `CollateralCache` で認可する。現物残高 hold は spot 商品だけに限定する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `config/config.exs`

- **発注頻度の確認と記録が原子的でなく、並行認可で上限を超えられる** `-3`
  > Risk は `OrderRate.count/2` を読んで認可し（`risk.ex:328-343`）、その後 Executor が pending Order 作成成功時に `OrderRate.record/2` する（`order_executor.ex:263-289`）。count と record の間に予約がなく、複数プロセスが同時に `System.submit_order/2` を呼べば全件が同じ件数を見て通過できる。起動時 warm と `:duplicate_bag` は直ったが、実行時の check-then-act 競合は残る。
  >
  > 改善方針: `OrderRate.reserve/commit/release` を GenServer 内で原子的に行うか、認可トークン mint と頻度枠予約を同じ直列化境界へ置く。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

### exchange / reconciliation

- **Decode strict は数値だけで、未知 side・識別子欠落を黙って skip し実エクスポージャを落とす** `-4`
  > 数値の NaN/Inf は `:invalid_number` へ改善された。しかし `position/1` は product_code または side が不正なら `:skip`（`decode.ex:109-123`）、`open_order/1` も acceptance ID・product_code・side 不正を `:skip` にする（同 `125-149`）。この行は Reconcile の `net_positions/1` に届かないため、同モジュールが用意した未知 side の fail-closed 分岐も空振りする。取引所仕様変更や未知値で実建玉・未約定を snapshot から消し、内部も空なら誤 Ready になりうる。改善計画 P0 #5 の「構造欠落行は skip」は資金保全経路には甘い。
  >
  > 改善方針: reconcile に必要な private API 行は識別子・side・status の未知値も snapshot 全体の `:invalid_exchange_payload` にする。skip を許すなら、無関係行であることを product/status の明示 allowlist で証明する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **購読 ACK を追跡せず、socket 書込み成功を購読成功として数える** `-2`
  > Feed は `socket_client.subscribe/2` が `:ok` を返すと `subscribe_count` を増やすだけで（`feed.ex:231-250`）、JSON-RPC の response ID、error、timeout を管理しない。watchdog は任意フレーム到着で延長される（同 `131-139`）ため、別の応答・雑音フレームだけ届く接続では対象 ticker 未購読を「接続中」と見なし続け得る。Risk の ticker 鮮度で最終的には拒否するが、自動再購読の自己修復が保証されない。
  >
  > 改善方針: subscription ID ごとの ACK/timeout とチャネル集合を状態に持ち、未 ACK・error なら socket を再接続する。watchdog は設定銘柄ごとの有効 ticker 受信時刻も監視する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`

### order lifecycle

- **未約定の期限・halt 時 cancel-all 方針がなく、注文が無期限に残りうる** `-2`
  > cancel API と定期突合はあるが、Order に time-in-force / expires_at / cancel_requested_at がなく（`trading/order.ex:78-150`）、サーキット理由別の「新規停止のみ／未約定全取消」もない。prod 文書も「必要なら全取消方針を設定」と将来形である（`architecture/env/prod.md:66-72`）。無人運用では pending の滞留を自動的に exposure 管理へ接続できていない。
  >
  > 改善方針: open age と取消状態を永続化し、Reconciler が期限超過を検出して取消・結果突合・通知まで行う。halt 理由ごとの cancel-all policy を明示する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`

- **place 直後の fill 同期失敗をログだけで握り、発注成功を返す** `-2`
  > `Live.place/2` は acceptance ID 永続化後に `sync_fills_after_place/2` を呼ぶが戻り値を捨て、同期失敗でも `{:ok, updated}` を返す（`live.ex:49-54, 92-117`）。次回認可前または60秒周期の突合で再試行されるものの、その間は Position・DailyLoss が古い。高速な外部呼出しや別経路が加わると認可窓が開く。
  >
  > 改善方針: post-place sync 失敗時は少なくとも Readiness を not_ready/halt にし、同期成功まで新規認可を閉じる。成功応答と「発注済み・状態同期待ち」を別結果にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

## 技術評価層 — apps/ui / observe

### 運用 UI

- **Status の ALLOWED 判定が Feed 切断を直接含まず ready probe と不一致** `-1`
  > `snapshot/1` は feed を取得するが `classify/4` に渡さず（`operational_status.ex:53-71`）、ALLOWED は readiness・live confirm・cache freshnessだけで決める（同 `151-169`）。切断直後から cache stale まで、Feed は disconnected なのに Orders は ALLOWED と表示しうる。一方 `/health/ready` は feed 接続を必須にしており（`health.ex:218-228`）、運用上の正本が二つある。
  >
  > 改善方針: `OperationalStatus` と `Health` で同一の readiness classifier を共有し、Feed 有効時は接続も orders gate に含める。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

### 可観測性

- **24/365 の外部監視・永続メトリクス・通知到達保証が未実装** `-3`
  > ConsoleReporter と LiveDashboard はプロセス内・stdout の観測であり、ホスト停止、再起動ループ、ディスク逼迫、NTP 断を同じホストから検知できない。prod 文書はこれらを監視要件に掲げるが具体的な監視構成を示さない（`architecture/env/prod.md:48-54, 76-89`）。Discord も送信失敗時の durable queue / retry / dead-letter を持たない。Vision の「人が張り付かない」「アラートで説明」はまだ運用構成として閉じていない。
  >
  > 改善方針: 別ホストの `/health/ready` 監視、ホスト exporter、ログ・メトリクス永続基盤、通知 retry と通知経路自身の heartbeat を本番 Compose 外も含めて定義する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `config/runtime.exs`, `.workspace/0_doc/architecture/env/prod.md`

## 技術評価層 — 実行基盤 / 横断評価

### CI・セキュリティ

- **依存脆弱性監査が非ゲートで、GitHub 依存と Actions supply chain を覆わない** `-1`
  > CI の `mix deps.audit` は `continue-on-error: true`（`.github/workflows/ci.yml:65-109`）で、README も Hex のみが対象と明記する（`README.md:107-116`）。`heroicons` / `daisyui` は GitHub tag 依存（`apps/ui/mix.exs:51-63`）、Actions も commit SHA 固定ではない。可視化は前進だが、既知脆弱性があっても配布ゲートは緑になりうる。
  >
  > 改善方針: advisory 検出とツール障害を分離し、検出時だけゲートを落とす。Dependabot/Renovate、GitHub dependency review、Actions SHA pin、SBOM を追加する。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `apps/ui/mix.exs`, `README.md`

### テスト / 取引完成度

- **実 API 契約と本番形の段階試験がなく、fixture が誤モデルを固定している** `-2`
  > precommit は 1 doctest + bitflyer 352 tests + ui 35 tests を通過し回帰は厚いが、private REST はスタブ・fixture 内で完結する。今回の累積平均価格と FX collateral の欠陥は、実レスポンス意味論・商品モデルを模したテストが無いため検出されなかった。実 API read-only contract、記録済み匿名レスポンス、最小ロット Game Day の証跡がないため、テスト緑を live 安全の証明にはできない。
  >
  > 改善方針: 承認付き read-only contract job、匿名化した実レスポンス corpus、2回以上の部分約定、CFD collateral、通信切断注入を追加し、最小ロットの段階解禁記録を残す。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/exchange/rest_test.exs`, `apps/bitflyer/test/bitflyer/order_executor/live_fills_test.exs`, `apps/bitflyer/test/fixtures/exchange/`

**減点合計: -33**
