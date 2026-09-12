# プラス点統合一覧 2026-09-12

根拠: [evaluation-2026-09-12.md](./evaluation-2026-09-12.md) /
[opus-specific-strengths](./opus/opus-specific-strengths-2026-09-12.md) /
[gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-12.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

採用方針: 同一テーマの重複加点を抑制。前回まとめの骨格（+90）は品質が維持されているものだけ残し、本サイクルで実証された新規実装を加算。Opus の +203 / GPT の +84 は統合して **+102**。

**加点合計（採用）: +102**

---

## 本サイクルで実証された新規実装

- **live 約定を execution 単位で記帳し、連続部分約定の価格を正しく保つ** `+5`（両評価。Opus は本クラス初の満点）
  > `getexecutions` の全量と remote filled、未知 execution 合計と delta の二重 coverage。各 execution の実価格・ID・取引所時刻を同一 DB トランザクションへ。`(trade_mode, exchange_execution_id)` 部分一意。連続部分約定・途中決済・DB reload の回帰あり。前回の累積 VWAP 誤用は解決。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **live 対象を spot allowlist に限定する二重ゲート** `+4`
  > 既定 `BTC_JPY`。`LiveSafety.assert_live_products!/1` が起動を止め、`Risk.check_live_product/2` が認可を止める。FX collateral は backlog へ退けた判断も正しい。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **Decode の構造 fail-closed（未知 side / 識別子欠落で snapshot 全体失敗）** `+3`
  > `:skip` allowlist は空。Reconcile は `invalid_exchange_payload` で halt。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

- **OrderRate の原子的予約（reserve / commit / release）** `+3`
  > GenServer 内で prune + count + slot。並行認可でも per-minute を超えない回帰あり。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`

- **OpenOrderPolicy + HaltCancelGate（理由別 cancel-all・in-flight / backoff）** `+3`
  > 起動 / CircuitSync / halt_trading の 3 経路。再開でも `ensure_halt_cancels`。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`

- **Equity ドローダウン（realized + Position×LTP、HWM、認可 / Fill 後 / 周期 / resume）** `+2`
  > 実装と接続は強い。ピーク永続化は減点側。ここでは「ゲートが空振りしない接続」だけ加点。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **Status 情報密度（建玉・未約定・当日損益・halt 復帰手順）** `+2`
  > UI は `System.exposure/0` のみ。運用画面だけで exposure が分かる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/exposure.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **公開 API 匿名 corpus + `mix bitflyer.contract` + deps.audit ゲート分離** `+3`
  > CI は実ホストを叩かない。advisory 検出時のみ fail。Actions SHA pin / Dependabot。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `.github/workflows/ci.yml`

---

## 維持された骨格（前回まとめから継続）

- **DailyLoss の Fill 正本 + 世代/barrier** `+5`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **BalanceCache の hold 会計（reserve / 比例 consume / DISTINCT ON tip）** `+5`
  > 全件読は解消。`latest_tips/1` へ集約。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **AuthorizedOrder（ワンショット・TTL・偽造再利用不可）** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`

- **fail-closed な認可網 + LiveSafety（Strategy 既定無効・FixedOnce 拒否・上限 env 必須）** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **モード別出口・冪等キー・submission_unknown + 承認付き回収** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`

- **baseline import（二段階承認・hash・Ready 非変更）** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **InFlight drain / FailureRate warm / WS stall watchdog / post-place fill_sync halt** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`, `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`

- **鮮度付き Cache・再接続・gap-fill・source_timestamp / skew** `+4`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **Strategy → System → Risk 依存強制 + revision provenance** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **Ash は永続状態限定・Decimal・起動突合 → 不整合 halt** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **TRADE_MODE 既定 dry_run・dev/prod 分離・CI=precommit・CD↔CI** `+4`
  > 対象ファイル: `config/runtime.exs`, `.github/workflows/ci.yml`

- **文書がコードと一致し、未達の残差を自分から書く** `+2`
  > P1 #9 / P2 #12 の残差明記。過大宣言はほぼ無い（HWM 永続化のみ乖離）。
  >
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

- **回帰テストの厚み（precommit 緑・483+38）** `+3`
  > 前回 352+35 から増加。モード分岐・halt・coverage・spot 拒否の再現が多い。

---

## 加点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| 本サイクル新規（execution 記帳 / spot 二重 / Decode / OrderRate / Policy / Equity / Status / contract·audit） | +25 |
| DailyLoss / BalanceCache / AuthorizedOrder / 認可網·LiveSafety | +18 |
| Executor / unknown / baseline / drain·FailureRate·stall | +11 |
| market-data / strategy | +7 |
| datastore / 起動復帰 / config·CI | +7 |
| 文書正直さ / テスト厚み | +5 |
| その他（permissions・paper FillPricing・Discord・Umbrella 方針等の残余） | +29 |
| **合計** | **+102** |

「その他」は両評価で加点されたが上表で個別見出しにしなかった項目の合算枠。前回の +13 残余に、本サイクルで厚くなった halt cancel・Fill 証跡・Exposure・watch-ready 手順などを含む。
