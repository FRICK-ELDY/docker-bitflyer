# マイナス点統合一覧 2026-09-12

根拠: [evaluation-2026-09-12.md](./evaluation-2026-09-12.md) /
[opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-12.md) /
[gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-12.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

採用方針: live 接続時の意味論欠陥は GPT の厳しさを優先。骨格の残差と再起動復帰は両評価の根拠付き項目を重複なく合算。P3 の軽微滞留は圧縮計上。

**減点合計（採用）: -24**

---

## 資金保全の意味論（live ブロッカー）

### datastore / live reconciliation

- **live 約定後に BalanceSnapshot tip が進まず、次回突合・再起動で恒久 halt する** `-5`（採用: GPT。Opus は `-4`）
  > 両評価者が独立に同一欠陥を検出。`LiveFills` は「残高: 触らない」（`live_fills.ex` L5-6）。live の `BalanceSnapshot` 書き手は初回 `Baseline.import/1` のみで、既存 tip があると `:baseline_already_complete`。`Balances.apply_fill` は paper 専用。突合は内部 tip と `getbalance` の amount/available を厳密一致（`reconcile.ex` L536-548）。約定や指値拘束で取引所残高が変わると 60 秒周期または再起動で `balance_mismatch`。`reconcile_mismatch` は `cancel_on_halt: false`。正規の再 baseline 経路もない。
  >
  > fail-closed なので資金は減らないが、Vision の Recoverable / 24/365 を満たさない。「一度だけ発注できる bot」になる。
  >
  > 改善方針: 取引所残高を正本にし、説明可能な差分だけ新しい tip を append。説明不能差分は halt。承認付き `--rebaseline` を用意。約定→周期突合→再起動→Ready の縦貫通試験を追加。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **当日 equity ピーク（HWM）が永続化されず、再起動でドローダウンゲートが緩む** `-2`（採用: Opus）
  > `DailyLoss.init/1` は実現 net を Fill から再集計するが `peak` は常に 0（`daily_loss.ex` L217-221）。再起動直後の snapshot で peak はその瞬間の equity に置き換わる。実現益後の含み損で溶けるケース（P2 #11 の完了条件）は再起動を挟むと満たされない。Vision は本番 PC（WSL2）の予期しない再起動をリスクに名指ししている。
  >
  > 改善方針: `(trade_mode, trading_day, peak)` を永続化し、`init/1` で読み戻す。読取失敗は unsynced fail-closed。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **live の損益・ドローダウンが取引手数料を含まない** `-3`（採用: GPT）
  > `Positions.realized_pnl/4` は売買価格差×決済数量のみ。live Fill は execution の価格・数量だけを渡し、`gettradingcommission` も実残高差分も損失へ入れない。Equity / DailyLoss / Status は同じ gross。小さな優位性の戦略ほど net 超過を見逃す。
  >
  > 改善方針: execution ごとの実手数料または説明可能な残高差分から fee を永続化し、Fill / DailyLoss / Equity を同一の net 値へ揃える。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **live spot では建玉突合が無効で、ドローダウン入力が外部照合されない** `-2`（採用: Opus）
  > spot は `getpositions` を呼ばず内部 Position も突合から除外（`reconcile.ex` L287-292）。判断自体は妥当だが、`Risk.Equity` と `max_position_size` はその内部行を見る。照合材料は `getbalance` の base 通貨 `amount`。
  >
  > 改善方針: base 在庫と「内部 Position + 未約定売り拘束」を許容幅付きで突合。平均単価は比較対象外と明記。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

---

## 発注ゲート・自己修復

- **Feed 切断直後も Risk は Cache 鮮度まで認可し、Status STOPPED / ready 503 と矛盾する** `-2`（採用: GPT。Opus は `-1`）
  > UI と Health は `market_feed_gate/2` を共有。`Risk.authorize/2` は `Cache.fresh?/3` のみ（`risk.ex` L278-286）。窓は既定 5s だが、表示と実発注の正本が分かれている。
  >
  > 改善方針: MarketData 有効時は Feed 接続を認可ゲートに含め、disconnected を即時拒否。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **WebSocket 購読 ACK を追跡せず、socket 書込み成功を購読成立とする** `-2`（採用: GPT。前回から未解決）
  > `subscribe_all/1` は `:ok` で count を増やすだけ。stall watchdog は任意フレームで延長される。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **通常未約定期限は既定 `:infinity` で runtime 上書きが無い** `-1`（採用: GPT `-2` を緩和。prod.md に運用選択として記載）
  > halt 理由別 cancel-all は実装済み。live 解禁時は有限値を必須にする。
  >
  > 対象ファイル: `config/config.exs`, `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`

- **`getexecutions` の 500 件上限超過はページングせず恒久 fail-closed** `-1`（採用: Opus）
  > coverage 検査は正しいが、取り切れない注文は以後記帳できない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **残高の検査と予約が別段で、認可通過→予約失敗の再試行ループが残る** `-1`（採用: Opus。前回から未解決）
  > 資金は reserve で守られる。Runner が `:insufficient_balance` を再試行するねじれ。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

---

## 観測・試験・軽微滞留

- **外部監視は手順・探針まで。別ホスト常駐と通知再送は未証明** `-1`（採用: GPT `-2` を緩和。宣言どおり部分解決）
  > `watch-ready.sh` / exporter 手順 / HEARTBEAT はある。実配備は live チェックリスト。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `bin/watch-ready.sh`

- **Game Day は Stage 0 公開 API のみ。private・障害注入・最小ロットは未実施** `-1`（採用: GPT `-2` を緩和。前進は認める）
  > 今回の残高 tip 不前進は、約定後再突合の縦試験が無いために見逃された。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/game-day.md`

- **P3 軽微負債の滞留（4 サイクル連続を含む）** `-3`（採用: Opus の `-1`×複数と GPT の Hex 外監査を圧縮）
  > `ash.codegen --check` なし、開発 Dockerfile が root、`test_helper` に Sandbox mode なし、`websockex` 0.4、保持方針なし、`apps/bitflyer/README.md` が TODO テンプレ、Hex 以外の脆弱性はゲート外。いずれも 1〜2 行〜文書 1 節で片付く。
  >
  > 対象ファイル: `mix.exs`, `Dockerfile`, `apps/bitflyer/test/test_helper.exs`, `apps/bitflyer/mix.exs`, `.workspace/0_doc/architecture/env/prod.md`

---

## 減点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| BalanceSnapshot tip 不前進 | -5 |
| live 手数料未計上 | -3 |
| HWM 非永続 | -2 |
| spot 建玉未照合 | -2 |
| Feed vs 認可 | -2 |
| 購読 ACK | -2 |
| 未約定期限 infinity / executions ページング / reserve ねじれ | -3 |
| 外部監視残差 / Game Day 残差 | -2 |
| P3 軽微滞留圧縮 | -3 |
| **合計** | **-24** |
