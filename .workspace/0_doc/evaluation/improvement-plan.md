# 改善提案書（improvement-plan）

最終更新: 2026-09-13
根拠: [evaluation-2026-09-12.md](./evaluation-2026-09-12.md) / [specific-weaknesses-2026-09-12.md](./specific-weaknesses-2026-09-12.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

---

## 消化済み（2026-09-10_2 計画 → コード確認）

前回計画の P0 #1–#5、P1 #6–#10、P2 #11–#15 は**部品として**両評価者がコード再読で確認した（部分約定の execution 記帳、spot 限定、Decode 構造 fail-closed、OrderRate 原子予約、fill 同期整理、BalanceCache DISTINCT、FailureRate warm、Fill 証跡、Status/ready 観測統一、halt cancel-all、Equity 接続、外部監視手順、Status 密度、公開 corpus、deps.audit ゲート）。再掲しない。

**ただし「済」＝ live 解禁ではない。** 今回の評価で、約定後の残高 tip 不前進が新たに P0 へ上がった。HWM 非永続は P2 #11 の残差として P1 へ戻す。

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | live 残高正本の前進 | 突合成功時に取引所 `getbalance` から新しい `BalanceSnapshot` を append し比較基準を進める。厳密一致をやめ、内部 Fill 合計 + 手数料許容幅で説明できる差分だけ前進。説明不能は `balance_mismatch`。`Baseline` は初期化専用、承認付き `--rebaseline` を別経路 | 1 回以上の約定のあと周期突合と再起動の双方で Ready を維持できる。外部入出金では halt |
| 2 | 縦貫通回帰 | 擬似取引所ハーネス（`Exchange.Client`）で「発注 → 部分約定 2 回 → 残高変動 → 定期突合 → Ready → 再起動 → Ready」をテスト化する。実装: `LiveExchangeHarness` + `regression/live_balance_advance_test.exs` | fixture だけで tip 不前進を再現・防止できる |

---

## P1 — 停止からの出口と損失意味論の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 3 | HWM 永続化 | `(trade_mode, trading_day, peak)` を `DailyEquityPeak` に upsert（認可は ETS のみ。persist は Fill 後 / 突合 / resume。Ash は DailyLoss GenServer の外）。`DailyLoss.init` / `reload` / `reinit` で当日行を読む。同日は ETS と DB の高い方。失敗は unsynced fail-closed。実装: `daily_equity_peak.ex` + `daily_loss.ex` | 実現益後の含み損状態で再起動・突合 reload しても drawdown が消えない |
| 4 | live 手数料 | getexecutions の `commission` を `Fill.fee` に残し `realized_pnl = gross − fee`（建増しも手数料だけ負）。Decode 欠落・負は fail-closed。LiveBalance は記録済み fee を quote デルタから引き、NULL 行だけ 20bps。paper は価格内で `fee=0`。ハーネスは約定時に quote 残高から commission を引く。実装: `fill.ex` + `positions.ex` + `live_fills.ex` + `live_balance.ex` + `decode.ex` + `live_exchange_harness.ex`。回帰: `regression/live_balance_advance_test.exs`（非 0 commission → 突合 → DailyLoss / Equity） | 口座残高の変化と内部 equity が許容幅で一致 |
| 5 | spot 在庫突合 | `getbalance` の base **amount** と買い `Position.size` を通貨ごとに比較（絶対床のみ。平均単価は対象外）。live 売りは買い建玉 − 未約定売りまで（認可と突合で同じ `SpotInventory`）。Position なしのベースラインは売らない。売建玉は `spot_short_position`。超過（内部 > 取引所）だけ在庫膨張 halt。実装: `spot_inventory.ex` + `live_inventory.ex` + `risk.ex` + `reconcile.ex` | 手動売買や記帳ずれで内部 Position だけが膨らんだら halt。ベースライン売りとドテン short も拒否 |
| 6 | 認可に Feed 接続 | `Risk.authorize` が鮮度の前に `market_feed_gate` を見る。切断は `Feed.connection_snapshot/0`（`:persistent_term`。`status/0` は呼ばない）。MarketData 無効時はスキップ。注入は `allow_test_injections` のみ。実装: `feed.ex` + `risk.ex` | Status STOPPED / ready 503 のとき認可しない |

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 7 | 購読 ACK | JSON-RPC request id ごとに ACK / error / timeout。ACK は公式どおり `result: true` のみ。`false` / `null` / 欠落 / `channelError` は再接続。全 ACK まで `connected?` にしない。実装: `feed.ex` + `socket.ex` + `normalize.ex` + `socket/local.ex` | 書込み成功や失敗 ACK だけでは connected にしない |
| 8 | live 未約定期限 | `BITFLYER_MAX_OPEN_AGE_MS` を live で有限必須（上限 7 日。`LiveSafety` + `runtime.exs`）。期限切れは `cancel_aged_opens` → `Live.Cancel` 1 回同期 → 終端で hold 解放。未設定 live は全 open 取消＋認可拒否。`run_now` も aged 取消する。実装: `live_safety.ex` + `open_order_policy.ex` + `risk.ex` + `reconciler.ex` | ソース変更なしに GTC が無期限放置されない |
| 9 | executions ページング | `getexecutions` を `before`（execution id 降順）で取り切る。1 ページ最大 500（`count` は取引所上限で切る）。最終満杯ページは次が空/短ければ取り切り。超過のみ `:execution_pages_exhausted`。実装: `rest.ex` + `live_fills.ex` | 500 分割でも記帳できる。ページ上限超過だけ fail-closed |
| 10 | 別ホスト監視の実配備 | 作業 PC で `watch-ready.ps1` を走らせ、非 ready と到達不能を人が確認。証跡: [watch-ready-evidence.md](../architecture/env/watch-ready-evidence.md)。常駐は `register-watch-ready-task.ps1`（VLAN1 の `READY_URL`。取引ホストでは動かさない） | 非 ready / 到達不能の記録がある。VLAN1 本番を向けると取引ホスト死を外から検知できる |
| 11 | Game Day Stage 2 | paper で仮想建玉 → Feed 断 → halt → resume。private GET は件数と出金有無だけ。記録: [game-day.md](../architecture/env/game-day.md)。`BITFLYER_WS_URL` は dry_run / paper のみ（live は起動停止）。Discord 目視とホスト発注停止は運用残り | Stage 3 の前に紙で復旧が回る。発注 REST は呼んでいない |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 12 | 板・流動性ゲート | ticker bid/ask → 後に board sequence | 異常 spread で成行を拒否 |
| 13 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + compact | 24/365 で表肥大の判断基準がある |
| 14 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 15 | 軽微負債一括 | **毎サイクル 3 件まで必ず消す**: `ash.codegen --check`、開発 Dockerfile の USER、Sandbox mode、websockex 記録または移行、`apps/bitflyer/README.md`、Hex 外 scanner | 4 サイクル連続の `-1` が消える |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ canary・二者承認
- 板の本格購読・プロパティ / モデルベース試験の本格導入
- SBOM / 署名、裁量向け UI、複数取引所、ML 基盤、FX 証拠金（backlog）

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |
| FX 証拠金 | `.workspace/1_backlog/fx-collateral-adapter.md`（live は spot 限定で先行済み） |
| 本番 CD | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |
| Game Day | [game-day.md](../architecture/env/game-day.md) |

次回評価では、本計画の **P0** がコード上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live 実発注を進めた場合は重大減点とする。
