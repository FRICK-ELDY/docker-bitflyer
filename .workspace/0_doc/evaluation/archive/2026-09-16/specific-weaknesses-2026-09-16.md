# マイナス点 統合一覧 2026-09-16

| 点数 | 基準 |
|:---:|:---|
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | 損失・二重発注・不整合を起こしうる |
| -4 | 資金保全・24/365・復帰を損なう |
| -5 | 根幹を揺るがす致命的欠陥 |

根拠: [opus-weaknesses](./opus/opus-specific-weaknesses-2026-09-16.md) / [gpt-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-16.md)。まとめ側でも対象ファイルを再読した。

**採用減点合計: -15**

---

## 技術評価層 — apps/bitflyer

### order-executor / live 会計

- **commission の内部モデルは直ったが、売買別の実残高一次証跡が無い** `-3`
  > Opus `-2` / GPT `-3`。コード再読で両評価の事実は一致。`Product.fee_currency/1` → Position inventory / LiveBalance / realized は BTC 建てで一貫。証跡は API に単位なし・実非ゼロ execution 未配置を自ら認め、売りは `BTC: −S` / `JPY: +S·P−C·P` の推定である（`live_balance.ex` L290-303、`commission-unit-evidence.md`）。モデルが違えば初回売り後に `balance_mismatch` で halt しうる。資金喪失より「人が張り付くまで止まる」リスク。**採用 `-3`（GPT）**。P0 #1 は「コード完了・実証待ち」に戻す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

- **ハーネスと本番が同一手数料式を共有し、反証が「自モデルからの逸脱」に留まる** `-1`
  > Opus のみ。`LiveExchangeHarness.apply_execution_balances/3` は `LiveBalance.fills_delta/2` と同型。緑は内部整合の証明。**採用 `-1`**。
  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`

### risk-manager

- **認可で上がった HWM は次の flush 前 crash で失われうる** `-2`
  > GPT `-2`（認可直後〜周期/Fill 前）。Opus `-1`（mark stale 時に `record_peak` まで届かない）。いずれも `persist: false` 認可の残差。flush 機構自体は入った。**採用 `-2`（残窓を一本化）**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **成行の残高拘束が LTP のまま（bid/ask 未使用）** `-1`
  > Opus のみ。Cache に bid/ask があるのに live 成行買いは `ltp × size`（`risk.ex`）。過小拘束の余地。**採用 `-1`**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **`DailyEquityPeak` の衝突検出が `inspect` 文字列に依存** `-1`
  > Opus（継続）。fail-closed だが並行経路で過剰停止しうる。**採用 `-1`**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

### market-data

- **板 crossed / ゼロで ticker 丸ごと破棄し、異常が鮮度切れに化ける** `-1`
  > Opus のみ。spread ゲート導入の副作用。Observable 上の切り分けが弱い。**採用 `-1`**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

### 診断ツール

- **Game Day Stage 2 がグローバル `RiskState` を `clear_circuit` で消し、`mark_ready` を押す** `-2`
  > Opus のみ。コード再確認: `game_day_stage2.ex` で `Risk.clear_circuit()` が 4 回、`Readiness.mark_ready()` が複数回。`RiskState` はモード無し単一行。開発/本番 DB 分離なら即事故ではないが、停止理由という最重安全装置を診断が無条件解除できる。**採用 `-2`**。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

---

## 可観測性 / 実行基盤

- **別ホスト監視が VLAN1 本番に未配備** `-2`
  > 両評価合意。`watch-ready-evidence.md` は 2026-09-13・localhost・常駐未登録のまま。**採用 `-2`**。live 解禁の出口条件。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

- **開発コンテナ root / websockex 未記録 / Hex 外 scanner 欠如 / 隔離 restore 証跡なし** `-2`
  > Opus（Dockerfile・websockex）と GPT（scanner・restore）を **P3 滞留として `-2` に圧縮**。個別の資金経路欠陥ではないが複数サイクル連続。
  > 対象ファイル: `Dockerfile`, `apps/bitflyer/mix.exs`, `.github/workflows/ci.yml`, `.workspace/0_doc/architecture/env/prod.md`

---

## プロセス

- **improvement-plan が自ら定めた完了条件を満たさない項目を「完了」にしている** `-1`
  > Opus `-2`。P0 #1 の「実応答 or 単位明記 fixture」と証跡の矛盾は事実。波及は大きいがコード欠陥ではないため **採用 `-1`**（圧縮）。完了宣言に根拠 1 行を必須化し、満たせないものは「部分完了」に戻す。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

---

## 採用しなかった / 提案へ移した項目

| 項目 | 評価者 | まとめ判断 |
|:---|:---|:---|
| 戦略が FixedOnce のみ | Opus `-1` | Vision が戦略を後続に送っている。**提案**（薄い live 戦略 1 本）へ |
| Fill retention 未定 | GPT `-1` | Opus が当日境界を再確認し減点から提案へ。**提案**を維持 |
| HWM write-behind の実装細部 | GPT 提案寄り | 減点は上記 crash 窓 `-2` に含め、実装案は improvement-plan へ |

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| commission 一次証跡 | -3 |
| 外部監視未配備 | -2 |
| HWM 残窓 | -2 |
| Game Day 副作用 | -2 |
| ハーネス独立性 / 成行拘束 / 板異常 / inspect | -4 |
| P3 滞留圧縮 | -2 |
| 完了宣言精度 | -1 |
| **合計** | **-15** |
