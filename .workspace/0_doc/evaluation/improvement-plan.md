# 改善提案書（improvement-plan）

最終更新: 2026-09-12
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
| 4 | live 手数料 | execution ごと、または説明可能な残高差分から fee を永続化し Fill / DailyLoss / Equity / Status を同一 net へ | 口座残高の変化と内部 equity が許容幅で一致 |
| 5 | spot 在庫突合 | `getbalance` の base `amount` と「内部 Position + 未約定売り拘束」を許容幅付きで比較。平均単価は対象外と明記 | 手動売買や記帳ずれで内部 Position だけが膨らんだら halt |
| 6 | 認可に Feed 接続 | `Risk.authorize` が `market_feed_gate` 相当を見る。切断直後は Cache 鮮度に依存しない | Status STOPPED / ready 503 のとき認可しない |

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 7 | 購読 ACK | request id ごとの ACK/error/timeout。未 ACK なら再接続 | 書込み成功だけで connected にしない |
| 8 | live 未約定期限 | `BITFLYER_MAX_OPEN_AGE_MS` を live で有限必須。期限→取消→終端確認→hold 解放 | ソース変更なしに GTC が無期限放置されない |
| 9 | executions ページング | `before` カーソルで取り切り。ページ数上限超過のみ fail-closed | 500 分割でも記帳できる |
| 10 | 別ホスト監視の実配備 | `watch-ready.sh` を取引ホスト外で常駐させた証跡。非 ready 検知を人が確認 | 同一ホスト死を外部が検知した記録がある |
| 11 | Game Day Stage 2 | paper 障害注入と復帰。private GET は秘密を残さず結果要約のみ | Stage 3 の前に紙で復旧が回る |

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
