# マイナス点統合一覧 2026-09-10_2

根拠: [evaluation-2026-09-10_2.md](./evaluation-2026-09-10_2.md) /
[opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-10_2.md) /
[gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-10_2.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

採用方針: 資金保全の意味論欠陥は GPT の厳しさを優先。骨格・運用負債は両評価の根拠付き項目を重複なく合算。

**減点合計（採用）: -44**

---

## 資金保全の意味論（live ブロッカー）

### order-executor / 日次損失

- **live の複数回部分約定で増分約定価格を誤り、建玉平均と日次損失を壊す** `-5`（採用: GPT。Opus は `-2`）
  > `LiveFills` は `filled_size` 差分を取る一方、`fill_price` は累積 `average_price` をそのまま差分 Fill に掛ける（`live_fills.ex` L157-190, L220-232）。連続部分約定で内部 VWAP・`Fill.realized_pnl`・DailyLoss・突合平均がずれる。単発部分約定テストでは検出されない。
  >
  > 改善方針: `filled_notional` 差分、または `exchange_execution_id` 単位の取込 + unique。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **損失上限は実現損のみで、Fill 直後に即 halt しない** `-3`（採用: GPT）
  > DailyLoss は `Fill.realized_pnl` 合計のみ。reload はするが上限超過での即 circuit は次回 authorize 待ち（`daily_loss_sync.ex`）。含み損・証拠金維持率は未計上（README も partial）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/order_executor/daily_loss_sync.ex`

### risk-manager

- **既定 `FX_BTC_JPY` に現物 JPY/BTC 残高モデルを適用し、証拠金を見ていない** `-5`（採用: GPT。Opus は `-3`）
  > 買いは quote JPY、売りは base BTC を拘束（`risk.ex` L107-118）。残高正本は `getbalance` のみ。FX の正本は collateral。売り誤拒否と証拠金不足の見逃しが両立しうる。
  >
  > 改善方針: Product を spot/CFD 分岐し、CFD は `getcollateral` + 必要証拠金。または live 対象を spot に限定。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `config/config.exs`

- **OrderRate の check と record が非原子的で、並行認可で上限を超えられる** `-3`（採用: GPT）
  > Risk が count、Executor が pending 成功時に record。予約がない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### exchange / reconciliation

- **Decode は数値 strict だが、未知 side・識別子欠落を skip し実エクスポージャを落とせる** `-4`（採用: GPT）
  > `position/1`・`open_order/1` 等が不正 side 等で `:skip`（`decode.ex`）。Reconcile の未知 side fail-closed に届かない。内部も空なら誤 Ready になりうる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

---

## 発注経路・同期

- **live 発注あたり open-order 同期が二重で、レート制限→FailureRate halt を自招きしうる** `-2`（採用: Opus）
  > `System.submit_order` と `OrderExecutor.do_submit` の双方が `sync_live_fills`（`system.ex` / `order_executor.ex`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **place 直後の fill 同期失敗を握り、発注成功を返す** `-2`（採用: GPT）
  > `Live.place/2` は sync 失敗でも `{:ok, updated}`（`live.ex`）。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **未約定の期限・halt 時 cancel-all 方針がない** `-2`（採用: GPT）
  > Order に TIF/expires がなく、理由別の全取消ポリシーも未実装。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`

- **購読 ACK を追跡せず、socket 書込み成功を購読成功と数える** `-2`（採用: GPT）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

---

## データストア・OTP 周辺

- **`BalanceCache.load_latest` が BalanceSnapshot を全件読（limit なし）** `-2`（採用: Opus）
  > append-only テーブルを突合周期で全読。同モジュール他経路は limit/DISTINCT あり。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **`Fill.exchange_execution_id` が常に nil / unique なし** `-1`（採用: Opus）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **`Fill.filled_at` がホスト壁時計（取引所 exec_date 未使用）** `-1`（採用: Opus）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **FailureRate に再起動復元がなく、クラッシュループで連続障害カウンタが空振り** `-1`（採用: Opus）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`

- **残高検査と reserve が別ステップ（認可近似）** `-1`（採用: Opus）
  > 資金は reserve で守られるが、Runner 再試行ループのねじれが残る。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **永続データの保持・剪定方針がない** `-1`（採用: Opus）
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **Fill→Order が文字列参照のみで FK なし** `-1`（採用: Opus）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`

---

## UI / 観測 / 横断

- **24/365 の外部監視・永続メトリクス・通知到達保証が未実装** `-3`（採用: GPT）
  > ConsoleReporter / LiveDashboard は同一ホスト内。prod 要件の別ホスト監視が未閉。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **Status ALLOWED が Feed 切断を直接見ず、`/health/ready` と不一致** `-1`（採用: GPT）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

- **実 API 契約試験・連続部分約定 / CFD 意味論の回帰が薄い** `-2`（採用: GPT）
  > precommit 緑を live 安全の証明にできない。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/order_executor/live_fills_test.exs`

- **deps.audit が非ゲート、GitHub/Actions supply chain が未覆い** `-1`（採用: GPT）
  > 対象ファイル: `.github/workflows/ci.yml`

- **ticker のみ / websockex 0.4 継続 / Status 情報密度 / 生 Ecto balances 等** `-1`×若干（採用: Opus の軽微群をまとめて `-2`）
  > 板未購読 `-1`、websockex `-1`、Status に建玉/損益なし `-1`、`Reconcile.read_latest_balances` 生 Ecto 無コメント `-1` のうち、まとめでは運用影響の大きい Status 密度と ticker 限定を **`-2`** に圧縮計上（他は提案・P3 へ）。

---

## 減点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| 部分約定 VWAP | -5 |
| FX スポット残高 | -5 |
| Decode 構造 skip | -4 |
| 実現損のみ・遅延 halt | -3 |
| OrderRate 競合 | -3 |
| 外部監視未閉 | -3 |
| 二重 sync / post-place 握り / 注文期限 / 購読 ACK | -8 |
| BalanceCache 全件読 | -2 |
| 実 API / 意味論テスト不足 | -2 |
| UI・板等の軽微圧縮 | -2 |
| execution_id / filled_at / FailureRate / reserve ねじれ / 剪定 / FK / audit | -7 |
| **合計** | **-44** |
