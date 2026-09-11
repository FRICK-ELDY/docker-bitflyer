# 改善提案書（improvement-plan）

最終更新: 2026-09-12
根拠: [evaluation-2026-09-10_2.md](./evaluation-2026-09-10_2.md) / [specific-weaknesses-2026-09-10_2.md](./specific-weaknesses-2026-09-10_2.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

---

## 消化済み（2026-09-10 計画 → コード確認）

前回計画の P0 #1–#5、P1 #6–#10、P2 #11–#15、P3 #16–#19 は**部品として**コード再読で確認した（DailyLoss/BalanceCache 接続、両建て net、LiveSafety、Decode 数値 strict、baseline/recover、FailureRate/stall/InFlight、metrics/permissions/OrderRate warm/CD、FillPricing/AuthorizedOrder/kill、残骸削除）。再掲しない。

**ただし「済」＝ live 解禁ではない。** 今回の評価で、部分約定価格・FX 証拠金・Decode 構造 skip が新たに P0 へ上がった。

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | 部分約定の増分価格 | Order に `filled_notional`（または同等）を持ち、`incremental = remote_avg×remote_filled − local_notional` で差分価格を算出。または `getexecutions` を execution ID 単位で Fill 化し `(trade_mode, exchange_execution_id)` unique。2回以上の部分約定・途中決済の縦貫通テスト | 連続部分約定でも Position VWAP / realized_pnl / DailyLoss が取引所と一致 |
| 2 | FX 証拠金 or spot 限定 | **今回は B:** live を spot（`BTC_JPY`）に限定し README/config を一致。**A（getcollateral）は backlog へ** → [.workspace/1_backlog/fx-collateral-adapter.md](../../1_backlog/fx-collateral-adapter.md) | spot 限定なら既定プロダクトが spot（B 完了条件） |
| 3 | Decode 構造 fail-closed | **完了:** 未知 side/status・識別子欠落は payload error → snapshot 失敗 → reconcile halt。`:skip` は allowlist のみ。`decode_rows` は未知戻りも fail-closed | 未知 side fixture（FX positions / spot open_orders）で Ready にならず halt |
| 4 | OrderRate 原子的予約 | **完了:** authorize 時 `OrderRate.reserve`、成功 `commit` / 失敗・未使用 `release`。並行認可で per-minute 超過不可 | 並行 N 認可でも per-minute を超えない |
| 5 | live fill 同期の整理 | **完了:** 認可前 sync のみ（`do_submit` 再同期削除）。post-place sync 失敗は `:fill_sync_failed` で halt（成功と分離）。`sync_open_orders` 最小間隔＋突合は `:force` | 1発注あたりの private REST が過剰にならず、同期失敗で盲目継続しない |

---

## P1 — 停止からの出口と自己修復の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 6 | BalanceCache.load_latest | **完了:** `DISTINCT ON (currency)` + `captured_at/id DESC`（全件読廃止）。`Reconcile.read_latest_balances` と同型 | 突合周期で全表スキャンしない |
| 7 | FailureRate 再起動復元 | **完了:** rejected Order 窓から warm。起動失敗は unsynced（authorize / evaluate fail-closed） | クラッシュループで連続障害カウントが消えない |
| 8 | Fill 証跡 | **完了:** live は execution 単位 Fill。`(trade_mode, exchange_execution_id)` unique、`filled_at` は取引所時刻優先、`order_id` FK | 同一 execution の二重 Fill を DB が拒否 |
| 9 | Status / ready 統一 | **完了:** Feed 接続を `OperationalStatus.market_feed_gate/2` に含め、Health `/ready` と同一 classifier。残差: `Risk.authorize` は Cache 鮮度のみ（切断直後の短時間は観測 STOPPED でも認可しうる） | 切断直後に ALLOWED と ready が矛盾しない |
| 10 | 未約定期限 / halt cancel-all | open age・TIF・理由別全取消ポリシーを文書化のうえ実装 | halt 後に放置 open が残らない運用が可能 |

---

## P2 — 観測と契約の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | 含み損 / equity ゲート | realized+unrealized（または collateral 評価）の第2閾値。stale 時方針を明示 | 建玉持ち越しでもドローダウンで止まる |
| 12 | 外部監視 | 別ホストからの `/health/ready`、ホスト exporter、通知 heartbeat。prod.md に具体構成 | 同一ホスト死を外部が検知できる |
| 13 | Status 情報密度 | 建玉・未約定・当日損益・halt 解消手順を StatusLive に | 運用画面だけで exposure が分かる |
| 14 | 実 API contract / Game Day | read-only 契約ジョブ、匿名レスポンス corpus、最小ロット段階解禁の記録 | fixture 以外の意味論検証がある |
| 15 | deps.audit ゲート分離 | advisory 検出時のみ fail。Actions SHA pin / Dependabot | 既知脆弱性で配布が止まらない状態を解消 |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 16 | 板・流動性ゲート | ticker bid/ask → 後に board sequence | 異常 spread で成行を拒否 |
| 17 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + compact タスク | 24/365 で表肥大の判断基準がある |
| 18 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 19 | 軽微負債一括 | websockex 移行方針、生 Ecto balances コメント、Sandbox mode、ash.codegen check 等 | 繰り返し指摘が消える |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ UI・revision canary
- 板の本格購読・プロパティ / モデルベース試験の本格導入
- SBOM / 署名、裁量向け UI、複数取引所、ML 基盤

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |
| FX 証拠金（P0 #2 案 A） | `.workspace/1_backlog/fx-collateral-adapter.md`（P0 #2 は B で先行） |
| 本番 CD | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |

次回評価では、本計画の **P0** がコード上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live 実発注を進めた場合は重大減点とする。
