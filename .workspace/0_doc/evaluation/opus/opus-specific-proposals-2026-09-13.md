# 第1評価者（Claude Opus 5）— 提案詳細 2026-09-13

対象コミット: `cfaf0a5`（`Merge pull request #103 from FRICK-ELDY/ops/p2-game-day-stage-2`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-12](./archive/2026-09-12/opus-specific-proposals-2026-09-12.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

提案は批判ではない。「無いこと」を減点で扱うべき項目は [weaknesses](./opus-specific-weaknesses-2026-09-13.md) に分けてある。ここに書くのは **次のステップ** であり、加点も減点もしない。**11 件**。

---

## 資金保全を厚くする

- **live 起動時に `getpositions` を 1 回だけ叩き、FX/CFD 建玉が空であることを機械で確認する** `0`
  > overview.md L112 は「同一 API キーに残る手動 FX/CFD 建玉は監視外（live 解禁前に口座を spot 専用にするか建玉を解消する）」と明記し、`Reconcile.compare_positions/2` は spot を除外、`Exchange.Rest.get_positions_for/1` は spot で REST を呼ばない。設計としては正しい。
  >
  > ただし現状これは **人の手順** である。手動 FX 建玉が残ったまま live を上げると、その建玉が強制決済されたときに JPY 残高が動き、`LiveBalance` は「説明できない差分」として halt する。fail-closed ではあるが、原因が「自分の知らない建玉」なので復旧に時間がかかる。
  >
  > 提案: live の起動突合で 1 回だけ `getpositions`（product_code 無しの全件、または `FX_BTC_JPY`）を呼び、結果が空でなければ `unsafe_account_state` で halt する。周期突合では呼ばない（レート制限と責務の観点から起動時だけでよい）。`skip_permissions?` と同じ形で `skip_foreign_positions?` を用意すればテストも既存の流儀に乗る。Vision の「本番に上げる前に検証する」を、チェックリストではなくコードにできる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **板・約定ストリームを購読して spread / 流動性ゲートを作る** `0`
  > 現在は `lightning_ticker_*` のみで、`Risk` の検査列に spread ゲートが無い（weaknesses に `-1` として計上済み）。それとは別に、**そこから先に伸ばせる価値** を提案として書く。
  >
  > 提案: (1) `Normalize.from_ticker/1` に `best_bid` / `best_ask` を足し、`Risk.check_spread/3` で `(ask − bid) / mid` が閾値を超える成行を拒否する。REST gap-fill でも取れる値なので WS 購読を増やさずに始められる。(2) 次に `lightning_executions_*` を購読して直近約定列を `Cache` に置き、`Paper.decide_fill/3` の約定サイズを直近出来高で頭打ちにする。paper の楽観バイアスが減り、Stage 2 の紙の検証が本番に近づく。(3) その後に `lightning_board_snapshot_*` / `lightning_board_*` の sequence 管理へ進む。段階を分ければ、板の整合管理という重い作業を後回しにできる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **取引所 API のレート制限をトークンバケットで明示的に守る** `0`
  > `Risk.OrderRate` は「1 分あたりの発注数」を守るが、これは自分のリスク上限であって bitFlyer の API レート制限ではない。現状、突合（60 秒ごとに `getpermissions` + ticker × 銘柄数 + `getchildorders` + `getexecutions` × ページ数 + `getbalance` × 最大 2 回）、`cancel_aged_opens`、`ensure_halt_cancels` の逐次 cancel、`LiveFills` の同期がそれぞれ独立に REST を叩く。P2 #9 のページングが入ったことで、1 回の突合が最大 20 リクエストまで伸びうるようになった。
  >
  > 提案: `Exchange.Rest` の手前に 1 つ GenServer（またはトークンバケットの ETS）を置き、private / public を分けて秒あたり・5 分あたりの上限を守る。超過時は `{:error, :rate_limited}` を返し、`FailureRate` とは別扱いにする（自分都合の待機であって取引所エラーではない）。HTTP 429 を受けたときの backoff もここに集約できる。現状 429 を特別扱いするコードが無いので、上限に当たったときの挙動が「連続エラー → circuit open」になるはずで、それは正しい止まり方だが原因の切り分けがしにくい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/http.ex`

---

## 検証を厚くする

- **金額・冪等キー・突合不変条件のプロパティベーステスト** `0`
  > 637 本のテストは例ベースで、境界値は人が選んでいる。`LiveBalance.explain/4` はプロパティが書きやすい形をしている。純関数で、入力（内部 tip・取引所残高・Fill 列・許容幅）と出力（`changed?` 行 / `balance_mismatch` / `balance_exchange_lag`）が閉じている。
  >
  > 提案: `StreamData` で次の不変条件を書く。(1) 任意の Fill 列に対し、取引所残高を「tip + Fill デルタ − 手数料（許容内）」で生成すれば必ず `{:ok, plan}` になる。(2) そこに任意の正の額を足せば必ず `balance_mismatch` になる（入金は幅内でも拒否）。(3) `explain` → `advance` → もう一度同じ `getbalance` で `explain` すると、2 回目は `changed? == false` になる（冪等性）。(4) `Positions.apply_fill` の建増し・部分決済・全決済を任意順で流し、`Σ realized_pnl = Σ(決済差) − Σ fee` が保たれる。(5) `SpotInventory.sell_covered?/4` と `LiveInventory.compare/4` が同じ入力で矛盾しない。
  >
  > いずれも「人が思いつかない組み合わせ」で壊れると資金に直結する場所である。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/startup/live_balance_test.exs`, `apps/bitflyer/test/bitflyer/order_executor/positions_test.exs`

- **過去 ticker を再生する `mix bitflyer.simulate`（paper リプレイ）** `0`
  > 現在の戦略検証手段は `FixedOnce`（1 回だけ成行）と手動の Game Day だけで、「戦略が 1 日動いたらどうなるか」を確かめる方法が無い。backlog の `trend-follow-strategy.md` を実装しても、評価する土台が無い。
  >
  > 提案: `Cache` に入る `{ltp, source_timestamp}` を JSONL で追記保存するオプション（`BITFLYER_TICK_LOG`、dry_run / paper のみ）を足し、`mix bitflyer.simulate --from ... --to ...` でそれを `Strategy.Runner` へ流す。executor は paper、Risk は本番と同じ経路。実 API を一切叩かずに、戦略・リスク上限・drawdown ゲートの相互作用を再現できる。`LiveExchangeHarness` と同じ発想（実経路にダブルを差す）を市場データ側にも適用するかたちで、既存構造への追加が小さい。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

- **`mix bitflyer.preflight` — live 解禁条件を機械可読にする** `0`
  > live に上げる前の条件は `game-day.md` の Stage 表、`prod.md`、improvement-plan の P0 表、`LiveSafety` の各検査に散っている。人が表を突き合わせて判断している。
  >
  > 提案: 1 コマンドで次を検査して表を出す。`TRADE_MODE` / `BITFLYER_LIVE_CONFIRM` の日付一致 / API キーの存在と `getpermissions` の出金なし / `product_codes` が全 spot / Risk 上限 6 種が env 由来 / `BITFLYER_MAX_OPEN_AGE_MS` が有限かつ 7 日以内 / `BalanceSnapshot` の必須通貨 tip 有無 / 未決済 Order の有無 / `RiskState.halted` / DB マイグレーション適用済み / 直近の Game Day 記録の日付。副作用ゼロ（発注 REST は呼ばない）。`--json` を付けて監視から引けるようにすれば、解禁判断そのものを証跡にできる。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/`, `.workspace/0_doc/architecture/env/game-day.md`

---

## 観測を厚くする

- **Prometheus exporter と SLO の定義** `0`
  > 現在の観測は「いまの状態」（Status UI / `/health/ready` / LiveDashboard）と「起きたこと」（構造化ログ / Discord）で、**率と推移** がホスト外に残らない。LiveDashboard のメトリクスはプロセス内メモリなので再起動で消える。
  >
  > 提案: `telemetry_metrics_prometheus_core` で `/metrics`（BasicAuth 配下、または loopback のみ）を出し、別ホストから scrape する。出す系列は絞る。`bitflyer_orders_total{mode,status}` / `bitflyer_risk_rejected_total{reason}` / `bitflyer_reconcile_mismatch_total{kind}` / `bitflyer_market_data_age_ms{product_code}` / `bitflyer_readiness{state}` / `bitflyer_daily_drawdown_jpy{mode}` / `bitflyer_feed_connected`。`internal_order_id` のような高カーディナリティのラベルは出さない。そのうえで SLO を 2 本だけ決める（例: 「`/health/ready` の 200 率 月次 99%」「reconcile_mismatch による halt 月 1 回以下」）。数値目標があると、次にどこへ投資すべきかが議論ではなくデータで決まる。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`, `apps/ui/lib/ui_web/router.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **Discord 到達の自己検査** `0`
  > Game Day Stage 2 の記録で唯一閉じなかったのが「Discord チャンネル到達の目視」である。HEARTBEAT はあるが、送信側が成功と判断しても実際に届いたかは人が見るしかない。
  >
  > 提案: 起動直後の 1 通目を self-test として送り、HTTP 応答コードと所要 ms を telemetry に出す（本文は「起動」だけ、URL は出さない）。さらに `System.observability_snapshot/0` に「最後に Discord へ 2xx で送れた時刻」を持たせ、Status UI の 1 行に出す。`last_discord_ok_at` が古ければ、人が見なくても通知経路の死が画面から分かる。Vision の「盲目運転は禁止」を通知経路にも適用するかたちになる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `apps/bitflyer/lib/bitflyer/system.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **ホスト exporter の別ホスト scrape（死活の二重化）** `0`
  > `watch-ready.ps1` は `/health/ready` を引く。これはアプリが生きていることの確認であって、ホストの資源状況（CPU / メモリ / ディスク / WSL2 の VmmemWSL）は見えない。24/365 で効いてくるのはむしろ後者である（Vision L122 が「WSL2 の時刻ずれ・メモリ抱え込み」をリスクとして挙げている）。
  >
  > 提案: 本番 PC に `windows_exporter` を入れ、作業用 PC1 から scrape する。最小構成なら Prometheus すら不要で、`watch-ready.ps1` と同じ形の PowerShell 探針が「ディスク空き < N GB」「メモリ使用率 > M%」を見て alert 行を吐くだけでもよい。上の Prometheus 提案と合わせると、取引プロセスとホストの両方を外から見る形が完成する。
  > 対象ファイル: `bin/`, `.workspace/0_doc/architecture/env/prod.md`

---

## 運用と拡張

- **`Fill` の日次ロールアップ Resource** `0`
  > 保持方針そのものは weaknesses に `-1` として計上したが、方針とは別に「集計の置き場所」を提案する。
  >
  > 提案: `DailyPnlRollup`（`trade_mode`, `trading_day`, `realized_net`, `fee_total`, `fill_count`, `volume`）を作り、JST 日付が変わったときに前日分を確定する。`DailyLoss.sum_realized/3` は当日ぶんだけを Fill から読み、前日以前はロールアップを読む。これで (1) 毎分の全行読みが当日分に限定され、(2) `fills` を剪定しても損益履歴が残り、(3) Status UI に「今週・今月の実現損益」を出せるようになる。`DailyEquityPeak` と同じ `(trade_mode, trading_day)` キーなので、テーブル設計も既存に揃う。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **戦略パラメータ変更の canary と二者承認** `0`
  > `StrategyParameterRevision` で履歴は残るが、適用は即時・全量である。`Baseline.import` が `--confirm` + `expected_hash` + `operator` の三点を要求しているのに対し、戦略パラメータは何も要求しない。資金に効く度合いは後者のほうが高いこともある。
  >
  > 提案: (1) 適用前に `mix bitflyer.strategy --dry-run` で差分と `revision_hash` を出す。(2) `--confirm --expected-hash=... --operator=...` で適用する（`Baseline` と同じ形にすれば実装が流用できる）。(3) 適用後 N 分 / M 約定は `max_order_size` を係数で絞る canary 期間を設け、その間に `FailureRate` か drawdown が動いたら自動で前リビジョンへ戻す。承認フローはすでに `Baseline` で確立しているので、横展開の形で入る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/mix/tasks/`

---

## 一覧

| # | 提案 | 分類 |
|:---:|:---|:---|
| 1 | live 起動時の `getpositions` 空検査 | 資金保全 |
| 2 | 板・約定ストリームと spread / 流動性ゲート | 資金保全 |
| 3 | API レート制限のトークンバケットと 429 backoff | 資金保全 |
| 4 | 金額・冪等キー・突合不変条件のプロパティベーステスト | 検証 |
| 5 | `mix bitflyer.simulate`（過去 ticker の paper リプレイ） | 検証 |
| 6 | `mix bitflyer.preflight`（live 解禁条件の機械可読化） | 検証 |
| 7 | Prometheus exporter と SLO 2 本 | 観測 |
| 8 | Discord 到達の自己検査と `last_discord_ok_at` | 観測 |
| 9 | ホスト exporter の別ホスト scrape | 観測 |
| 10 | `DailyPnlRollup`（日次ロールアップ Resource） | 運用 |
| 11 | 戦略パラメータの canary と二者承認 | 拡張 |

**提案数: 11 件（合計 0 点）**
