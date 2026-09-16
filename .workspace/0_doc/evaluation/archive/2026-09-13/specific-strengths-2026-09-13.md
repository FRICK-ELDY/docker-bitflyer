# プラス点統合一覧 2026-09-13

根拠: [evaluation-2026-09-13.md](./evaluation-2026-09-13.md) /
[opus-specific-strengths](./opus/opus-specific-strengths-2026-09-13.md) /
[gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-13.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

採用方針: 同一テーマの重複加点を抑制。前回まとめの骨格（+102）は品質が維持されているものだけ残し、本サイクルで実証された新規実装を加算。手数料通貨の欠陥は減点側。Opus の +231 / GPT の +104 は統合して **+114**。

**加点合計（採用）: +114**

---

## 本サイクルで実証された新規実装

- **説明可能な差分だけ BalanceSnapshot tip を前進させる骨格** `+4`（両評価。GPT は fee 欠陥で +3。骨格自体は +4）
  > `LiveBalance.explain/4` が tip + Fill デルタ + 支払超過側の手数料許容で `getbalance` を説明し、成功時だけ advisory lock と transaction で append する。増加（入金）は幅内でも拒否。`Baseline` は初期化専用、`--rebaseline` は承認付き別経路。ゼロ手数料なら周期突合と再起動復帰がコード上通る。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **擬似取引所ハーネスによる発注→部分約定→突合→再起動の縦回帰** `+4`（両評価。単位の誤一致は減点側）
  > `LiveExchangeHarness` が `Exchange.Behaviour` をダブルし、`getbalance` を約定で動かす。`regression/live_balance_advance_test.exs` が Ready 維持と再初期化後の再突合を実経路で固定する。入金混入の halt もある。
  >
  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`, `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

- **購読成立を JSON-RPC `result: true` の ACK まで遅延させる** `+4`（両評価）
  > request id ごとに timeout を持ち、全 ACK 後だけ `connected?`。`false` / `null` / `channelError` / timeout は再接続。書込み成功を購読成立としない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **認可が Feed 接続を鮮度の前に見る（pid 付き snapshot）** `+3`（両評価）
  > `Risk.check_market_feed/2` が `check_freshness` の前（`risk.ex` L101）。`Feed.connection_snapshot/0` は `:persistent_term` の `{pid, connected?}` 一致。死んだ Feed の古い true を connected と読まない。Status STOPPED と実発注ゲートが揃った。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **spot 在庫を認可と突合で同じ不変条件へ寄せた** `+3`（両評価）
  > `SpotInventory` が買い Position − 未約定売りを一元計算。売建玉は `spot_short_position`、内部膨張は `spot_inventory_inflated`。ベースライン専用在庫は売らない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/spot_inventory.ex`, `apps/bitflyer/lib/bitflyer/startup/live_inventory.ex`

- **当日 HWM を DB 行として持ち、init/reload で高い方を採る** `+2`（接続の加点。周期 flush は減点側）
  > `DailyEquityPeak` の条件付き更新と unsynced fail-closed。再起動で peak が常に 0 に戻る前回の欠陥は閉じた。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **live 未約定 TTL を有限必須にし、期限切れで cancel→終端確認→hold 解放する** `+3`（両評価）
  > `BITFLYER_MAX_OPEN_AGE_MS` は live で必須・上限 7 日。未設定は起動停止。boot / `run_now` / 周期が aged cancel する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`

- **`getexecutions` を `before` で取り切り、ページ上限超過だけ fail-closed** `+3`（両評価）
  > 1 ページ最大 500。最終満杯ページは次が空/短いとき確定。部分集合を黙って採用しない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

---

## 維持された骨格（前回まとめから継続）

- **live 約定を execution 単位で記帳し、連続部分約定の価格を正しく保つ** `+5`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **DailyLoss の Fill 正本 + 世代/barrier** `+5`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **BalanceCache の hold 会計（reserve / 比例 consume / DISTINCT ON tip）** `+5`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **AuthorizedOrder（ワンショット・TTL・偽造再利用不可）** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`

- **fail-closed な認可網 + LiveSafety（Strategy 既定無効・FixedOnce 拒否・上限 env 必須）** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **モード別出口・冪等キー・submission_unknown + 承認付き回収** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **live 対象を spot allowlist に限定する二重ゲート** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`

- **Decode の構造 fail-closed / OrderRate 原子予約 / HaltCancelGate** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`

- **InFlight drain / FailureRate warm / WS stall watchdog / post-place fill_sync halt** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **鮮度付き Cache・再接続・gap-fill・source_timestamp / skew** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **TRADE_MODE 既定 dry_run・runtime fail-closed・CI=precommit・CD↔CI** `+4`
  > 対象ファイル: `config/runtime.exs`, `.github/workflows/ci.yml`

- **Strategy → System → Risk 依存強制 + revision provenance** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **Ash は永続状態限定・Decimal・起動突合 → 不整合 halt** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **公開 corpus + deps.audit ゲート + Status 情報密度** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **回帰テストの厚み（precommit 緑・599+38）** `+3`
  > 前回 483+38 から bitflyer +116。警告ゼロ。

- **文書が残差を自分から書く（Game Day / watch-ready）** `+1`
  > 過大宣言は HWM 完了条件と「別ホスト」完了条件に残る。正直さ自体は維持。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/game-day.md`

---

## 加点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| 本サイクル新規（tip 前進骨格 / ハーネス / ACK / Feed 認可 / 在庫 / HWM 行 / open age / ページング） | +26 |
| 前回まとめから維持した骨格 | +88 |
| **合計** | **+114** |

維持分は前回 +102 から、本サイクルへ移した OpenOrderPolicy の「有限 TTL」相当と文書加点の圧縮を差し引いた概算。同一モジュールの二重計上はしていない。
