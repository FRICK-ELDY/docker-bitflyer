# マイナス点統合一覧 2026-09-13

根拠: [evaluation-2026-09-13.md](./evaluation-2026-09-13.md) /
[opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-13.md) /
[gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-13.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

採用方針: live 接続時の意味論は GPT の厳しさを優先。再起動復帰と突合レースは両評価の根拠付き項目を合算。P3 軽微滞留は圧縮。まとめ側でも `fill.ex` / `live_balance.ex` / `risk.ex` / `reconcile.ex` と公式手数料ページを再読した。

**減点合計（採用）: -16**

---

## 資金保全の意味論（live ブロッカー）

### datastore / live reconciliation

- **BTC_JPY の `commission` を quote（JPY）と決め打ちしており、公式の手数料単位と矛盾する** `-4`（採用: GPT。Opus は未計上）
  > コードは「spot は quote 通貨。BTC_JPY は JPY」と断定する（`fill.ex` L9）。`Positions.net_realized/2` は `gross − fee` を JPY として引き、`LiveBalance.fill_delta/2` は fee を quote 側にだけ載せ、base の expected は `size` 全量である（`live_balance.ex` L272–297）。ハーネスも quote 残高から commission を引く（`live_exchange_harness.ex` L6, L195–224）。
  >
  > 公式手数料表は Lightning 現物を「約定数量 × 0.01〜0.15%、単位は通貨ペアで異なる / Unit varies by Crypto Assets」とし、販売所 Bitcoin は明示的に **Unit: BTC** である（[手数料一覧](https://bitflyer.com/ja-jp/s/commission) / [Fees and Taxes](https://bitflyer.com/en-jp/s/commission)、2026-09-13 確認）。API の `getexecutions.commission` 自体は単位を書いていない。Game Day の `--private` は balances/positions までで、fee-bearing execution は未検証（`game-day.md` L145–153）。
  >
  > 単位が BTC なら、買い後の取引所 BTC は `size − commission`、内部 Position と expected base は `size` のまま。通常 0.01〜0.15% は BTC 絶対床（1 sat）を超えるため、次の突合は `balance_mismatch` または `spot_inventory_inflated` で halt する。DailyLoss への控除も 0.0000015 JPY 相当になり実質未計上。縦回帰は誤った単位同士の一致を証明している。
  >
  > 改善方針: 非ゼロ `commission` の private GET で単位を確定する。BTC なら base amount / Position / JPY mark 損益へ一貫して反映し、ハーネスと「誤った通貨なら必ず失敗する」反証を足す。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/test/support/live_exchange_harness.ex`

- **認可だけで上がった HWM は周期 flush 前の再起動で消え、drawdown が緩む** `-2`（両評価。性質は Opus の周期間シナリオ）
  > `DailyEquityPeak` と init/reload の高い方採用は入った。しかし認可は `persist: false`（`risk.ex` L602–607）。`prepare_peak` は「ETS peak より高い」ときだけ persist する（`daily_loss.ex` L448–465）。周期 enforce のあいだに認可が peak を上げ、その後 equity が下がると DB に載らず、再起動後は古い peak になる。Vision が名指しした本番 PC（WSL2）再起動で踏みうる。
  >
  > 改善方針: persist 点（Fill 後 / 突合 / resume）で `peak > persisted_peak` なら flush。認可上昇の回帰を置く。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **突合窓は「内部 Fill 先行」だけ再取得し、「取引所先行」は即 halt する** `-2`（採用: Opus。まとめ側で `reconcile.ex` 再読）
  > live 突合は `sync_live_fills` → `getbalance` の順（`reconcile.ex` L159–168）。`balance_exchange_lag`（取引所 amount が tip のまま）だけ 1 回再取得する（L285–307）。同期完了後〜`getbalance` 応答までの数百 ms に約定が入ると、取引所だけが進み `fee_explained?` で入金扱いになり `balance_mismatch`。`reconcile_mismatch` は `cancel_on_halt: false`。安全側だが無人連続運転と両立しない。
  >
  > 改善方針: 対称に fill 再同期を 1 回入れるか、`getbalance` を fill 同期の前に取り向きを片側へ固定する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

---

## 発注ゲート・観測・試験

- **別ホスト監視は同一物理ホストのドリルまで。ホスト死は外から見えない** `-1`（GPT `-2` を緩和。証跡前進を認める）
  > `watch-ready.ps1` と非 ready / 到達不能の記録はある。文書自身が同じ PC と未登録を認める（`watch-ready-evidence.md` L17–19）。overview の「取引ホストの外」は未成立。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`

- **Game Day Stage 2 は SQL 建玉と ready 代替で、Executor / submit を通していない** `-1`（GPT `-2` を緩和。Feed 断→resume の前進は認める）
  > 記録自身が「paper 建玉は SQL」「halt 後の submit は未実施」「Discord 目視未閉じ」と書く（`game-day.md` L151–152）。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/game-day.md`

- **残高の検査と予約が別段で、認可通過→予約失敗の再試行が残る** `-1`（採用: Opus。前回から未解決）
  > `check_available_balance` は Cache を読むだけ。正本は `BalanceCache.reserve`。`Runner` は `:insufficient_balance` を再試行する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **ticker 一本で spread / 流動性ゲートが無い** `-1`（採用: Opus。前回から未解決）
  > `Normalize.from_ticker/1` は `ltp` と `source_timestamp` のみ。成行の実効価格を守る入力が無い。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

---

## 軽微滞留・供給網

- **P3 軽微負債の滞留（5 サイクル連続を含む）** `-3`（採用: Opus の `-1`×複数と GPT の drift/README を圧縮）
  > `ash.codegen --check` なし、開発 Dockerfile が root、`test_helper` に Sandbox mode なし、`websockex` 0.4 の記録なし、保持方針なし、`apps/bitflyer/README.md` が TODO。improvement-plan が「毎サイクル 3 件必ず消す」と書いたうえで消化 0 件。
  >
  > 対象ファイル: `mix.exs`, `Dockerfile`, `apps/bitflyer/test/test_helper.exs`, `apps/bitflyer/README.md`

- **Hex 以外の依存・コンテナ OS は脆弱性ゲート外** `-1`（採用: GPT）
  > `mix deps.audit` は Hex advisory のみ。GitHub tag 依存とイメージ OS は対象外と README が自認する。
  >
  > 対象ファイル: `README.md`, `.github/workflows/ci.yml`

---

## 減点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| commission 通貨の決め打ち | -4 |
| HWM 周期間 flush 欠落 | -2 |
| 突合窓の非対称 | -2 |
| 外部監視残差 / Game Day 残差 | -2 |
| reserve ねじれ / ticker 一本 | -2 |
| P3 軽微滞留圧縮 | -3 |
| Hex 外監査 | -1 |
| **合計** | **-16** |
