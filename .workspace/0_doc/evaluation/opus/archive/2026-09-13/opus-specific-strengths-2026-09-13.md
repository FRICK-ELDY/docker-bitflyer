# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-13

対象コミット: `cfaf0a5`（`Merge pull request #103 from FRICK-ELDY/ops/p2-game-day-stage-2`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-12](./archive/2026-09-12/opus-specific-strengths-2026-09-12.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。すべての判定は当該コードの再読に基づく。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +231 点**

前回の +203 から 28 点増えた。増分の中心は **live の意味論を「取引所を正本にする」へ反転させた 3 本の新規モジュール**（`LiveBalance` 547 行 / `LiveInventory` 152 行 / `SpotInventory` 110 行）と、それを **擬似取引所ハーネス経由の縦貫通回帰**（`LiveExchangeHarness` 255 行 + `live_balance_advance_test.exs` 432 行）で固定したことである。テストは 521 本から **637 本**（bitflyer 599 + doctest 1 / ui 38）に増えた。

---

## 技術評価層 — apps/bitflyer

### market-data

- **購読 ACK を公式どおり `result: true` に限定し、全 ACK が揃うまで `connected?` にしない** `+4`
  > WebSocket の「書き込めた」を「購読できた」と誤認する実装は多いが、ここは JSON-RPC の request id 単位で追跡する。`next_request_id/1` で id を採番し、`track_pending/4` が `{product_code, channel, timer, ref}` を保持し、全 `pending_acks` が空になったときだけ接続を確立扱いにする。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/feed.ex L375-379
  > defp maybe_finish_subscribe(%{pending_acks: pending} = state) when map_size(pending) == 0 do
  >   state |> set_connected(true) |> arm_stall_watchdog()
  > end
  > ```
  >
  > 判定側の `Normalize.rpc_response/1` も厳しい。`result` が `true` 以外（`false` / `null` / キー欠落）は `:subscribe_rejected`、`channelError` は `:channel_error`、`id` は `"1"` のような文字列も整数へ正規化したうえで非正値を拒否する（normalize.ex L120-160）。未 ACK は `subscribe_ack_timeout_ms`（既定 5s）で `handle_disconnect(state, :subscribe_ack_timeout)` に落ち、再購読からやり直す。`ref` 照合つきなので遅延到着した旧タイマーで現行接続を落とさない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **接続状態を `:persistent_term` に `{pid, connected?}` で置き、pid 不一致を切断として fail-closed する** `+4`
  > 認可ホットパスから `GenServer.call(Feed, :status)` を呼ぶと、`gap_fill` 中のブロックに巻き込まれる。そこで `connection_snapshot/0` を分けたのは妥当な判断だが、優れているのは **pid まで一緒に置いた** ところである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/feed.ex L54-68
  > case Process.whereis(@name) do
  >   nil -> %{available?: false, connected?: false}
  >   pid when is_pid(pid) ->
  >     connected? =
  >       case :persistent_term.get(connection_key(), :missing) do
  >         {^pid, true} -> true
  >         _ -> false
  >       end
  > ```
  >
  > `Process.exit(pid, :kill)` 後に名前が再登録されてから `init/1` が新しい値を publish するまでの隙間、`whereis` と `get` のあいだのずれ、どちらも「古い pid の true」が残るが、pid 照合で切断扱いになる。`terminate/2` でも `connected?: false` を publish する。名前付きテスト Feed は `publish_connection(_state)` の fallthrough で書き込まないので、テスト用プロセスが本番グローバル状態を汚さない。ここまで詰めた接続フラグは珍しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **サイレントストール watchdog と gap-fill の時刻逆転防止** `+3`
  > 「切断イベントは来ないが値が来ない」を検出するため、最終フレームから `stall_timeout_ms`（未設定時は `market_data_max_age_ms × 3`）無通信なら socket を落として再接続する。`arm_stall_watchdog/1` は `make_ref()` を毎回発行し、`{:stall_watchdog, ref}` の ref 一致でのみ発火する（feed.ex L234-247, L522-540）。鮮度窓の 3 倍という設定は「Risk の stale 判定より watchdog が先に走らない」ための意図的な余白で、根拠がコメントに残っている。
  >
  > REST 穴埋めも非同期 Task にしつつ、`gap_fill_started_at` より新しい WS 値があれば適用をスキップする（`maybe_apply_gap_fill/4`）。「遅れて返ってきた REST が新しい WS を上書きする」という、実装してみないと気付かない不具合を先回りしている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **指数バックオフ再接続と、mailbox に残った `:reconnect` の無効化** `+3`
  > `reconnect_delay/3` は `base * 2^min(attempt, 10)` を `reconnect_max_ms` で頭打ちにする。加えて `handle_info(:reconnect, state)` が「既に接続済み、または socket が生きている」場合に何もしない（feed.ex L223-232）。タイマーをキャンセルしても mailbox に届き済みのメッセージは消えないという BEAM の性質を踏まえた防御で、コメントにも理由が残っている。socket は `link` + `trap_exit` で監視し、Feed 終了時のリークを防ぐ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **`Socket.Client` behaviour による差し替え可能性と、`Socket.Local` の網羅度** `+3`
  > 実装は `Socket`（WebSockex）と `Socket.Local`（テスト用）の 2 本。`Socket.Local` は `result: true` の正常 ACK だけでなく、`error` 応答、書込み失敗（`WriteFailSocket`）まで再現できる。`feed_test.exs` が 513 行増えたのはこの土台があるからで、外部ネットワークに触れずに ACK・timeout・channelError・再接続を全部テストで固定できている。依存ライブラリを差し替える際のコストもここで下がっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`, `apps/bitflyer/lib/bitflyer/market_data/socket/local.ex`

- **channel と product_code の突合、`source_timestamp` 欠落の fail-closed** `+3`
  > `from_ws_frame/1` は `params.channel` が `MarketData.ticker_channel(product_code)` と一致しない限り `:error` を返す（normalize.ex L61-79）。取引所が別銘柄のメッセージを混ぜてきたときに、別銘柄の価格で発注する事故を防ぐ。`cast_source_timestamp/1` はオフセット無し ISO8601 を UTC とみなす一方、パースできない値は `:error` にして正規化ごと落とす。値が欠落した場合は `nil` を通すが、その `nil` は `Risk.check_source_timestamp/3` の第 2 節が `:missing_source_timestamp` で必ず拒否する。「欠落を許すのは正規化層、拒否するのは認可層」という責務分離が明示されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### strategy

- **内部コマンドのみを生成し、取引所 API を一切触らない依存方向** `+2`
  > `apps/bitflyer/lib/bitflyer/strategy/` 配下は `fixed_once.ex` / `revision.ex` / `runner.ex` の 3 本のみで、`Exchange` への参照が無い。overview.md L155「strategy から API を直接叩かない」がコードで担保されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/`

- **`Runner` の intent 状態機械と throttle** `+2`
  > accept / retry / settle を明示的に持ち、拒否理由ごとに再試行可否を分ける（`@retryable_limit_kinds`）。`strategy intent settled without accept (no further retry)` のように「これ以上試さない」もログに残る。無限リトライで発注枠を焼かない設計になっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **戦略パラメータの適用履歴を永続化する** `+2`
  > `StrategyParameterRevision` があり、logger metadata にも `:strategy_parameter_revision_id` が allowlist されている（config.exs L203）。「いつどのパラメータで動いていたか」が事故調査で再構成できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `config/config.exs`

- **live で開発用戦略 `FixedOnce` の有効化を起動時に拒否する** `+3`
  > `TRADE_MODE=live` かつ `BITFLYER_STRATEGY_ENABLED=true` かつ module が `FixedOnce` のとき、`ArgumentError` で起動を止める。メッセージには「observe-only live なら env を未設定のままにせよ」という代替まで書いてある（live_safety.ex L92-99）。「開発既定が本番に載る」という最も起きやすい事故を、実行時チェックではなく **起動不能** で潰している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### risk-manager

- **認可が Status / `/health/ready` と同一の `market_feed_gate` を鮮度の前に通る** `+3`
  > 前回「画面が STOPPED と言っているのに注文が通る」窓を指摘したが、今サイクルで閉じた。`Risk.authorize/2` の検査列に `check_market_feed` が `check_freshness` より前に入り（risk.ex L101-102）、`Health.classify_ready/4` / `OperationalStatus.classify/5` と **同じ `OperationalStatus.market_feed_gate/2`** を呼ぶ。3 つの消費者が 1 つの関数を共有するので、以後ずれようがない。拒否理由も `feed_disconnected` / `feed_unavailable` / `stale_market_data` に統一されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

- **HWM の永続化を、条件付き update で単調増加として表現した** `+3`
  > `DailyEquityPeak` は `(trade_mode, trading_day)` の identity と custom_index を持ち、更新は `peak < ^peak` を条件にした `bulk_update` で行う。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L184-190
  > # 無条件 update だと 150 の直後に 120 が書き戻り、再起動後の drawdown が緩む。
  > |> Ash.Query.filter(id == ^row.id and peak < ^peak)
  > |> Ash.bulk_update(:update, %{peak: peak}, return_errors?: true, stop_on_error?: true)
  > ```
  >
  > read-modify-write の競合で低い値が高い値を上書きしないことを、アプリ側のロックではなく **DB の述語** で保証している。`daily_loss_test.exs` L205-232 に並行 upsert のテストが 2 本ある。Ash 経由でこの水準の競合設計をしている個人プロジェクトは稀である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **spot の売りカバー条件を、認可と突合で同一モジュールから引く** `+4`
  > `SpotInventory` が `buy_claimed/1`（買い建玉の通貨別合計）、`sell_holds/1`（未約定売り残）、`sell_covered?/4`、`first_short_spot/1` を持ち、`Risk.authorize` の `check_spot_sell_cover`（risk.ex L485-502）と `LiveInventory.compare` の両方がここを呼ぶ。
  >
  > 「認可で通る条件」と「突合で不整合とみなす条件」が別実装だと必ずずれる、というのは取引システムで最もよくある事故のひとつで、それを 110 行の純関数モジュールに切り出して塞いでいる。しかも意味論の切り分けが正確である。ベースラインだけに乗っている通貨（Position 無し）は「平均単価が無く、売ると内部 short になる」ので売らせない。売建玉が残っていれば `spot_short_position` で halt。売り残を Position に足すと二重計上になるので足さない。どれもコメントで理由が残っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/spot_inventory.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/startup/live_inventory.ex`

- **発注頻度の原子予約と、後続検査の失敗で必ず release する構造** `+3`
  > `reserve_order_rate/2` で枠を取ったあと、`check_daily_loss` → `check_daily_drawdown` → `check_available_balance` のどれで落ちても `OrderRate.release(reservation)` を通る（risk.ex L123-146）。`with` を諦めてネストした `case` にしているのは可読性を捨てて確実性を取った判断で、コメントも無しに正しく書けている。「予約したまま拒否して枠を焼く」は見落としやすい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **すべてのリスク ETS が unsynced を持ち、未同期なら認可を拒否する** `+3`
  > `OrderRate`（`:order_rate_unsynced`）、`FailureRate`（`:failure_rate_unsynced`）、`DailyLoss`（`:daily_loss_unsynced`）、`BalanceCache`（`:balance_unsynced`）、`Position` 読取失敗（`:position_load_failed`）。どれも「読めなかったら空とみなす」ではなく「読めなかったら発注しない」に倒れる。`Equity` も `hwm_persist_failed` で unsynced を返す。fail-closed が例外なく貫かれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **テスト注入を `allow_test_injections` でゲートし、本番経路では黙って無視する** `+3`
  > `:positions` / `:balances` / `:daily_loss` / `:recent_order_count` / `:market_data` / `:feed` のすべてで、`test_injections_allowed?/0` が false なら **注入を削除して本物を読み直す**。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L552-555
  > else
  >   # 本番経路では注入を無視し実予約する（原子性迂回を防ぐ）
  >   reserve_order_rate(limits, Keyword.delete(opts, :recent_order_count))
  > end
  > ```
  >
  > 「テスト用の抜け道が本番で踏まれる」を設定 1 つで封じており、しかも `{:error, :not_allowed}` ではなく正規経路へ落とすので、うっかり呼んでも安全側に着地する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **`Equity` の stale 方針を呼び出し経路ごとに分けた** `+4`
  > 建玉があるのに mark（ticker LTP）が無いとき、何をすべきかは経路で変わる。`authorize` / `Startup.Resume` は fail-closed（拒否）、周期 `enforce/1` は **halt しない**（切断だけで永続 halt にしない）、建玉が無ければ未実現 0、未知 `side` は 0 にせず `:unsynced`。この 4 分岐が moduledoc に明記され（equity.ex L19-28）、コードでも `{:error, :stale, _}` と `{:error, :unsynced, _}` を区別して返している。
  >
  > 「安全側」が常に「止める」ではない、という設計判断をここまで言語化して実装しているのは、実運用を想定した人でないと書けない。加えて `snapshot(record_peak: false)` を用意して、表示用の読取が HWM を動かさないようにしている（exposure.ex L255）。観測が状態を変えないという分離も効いている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/equity.ex`, `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **live の未約定 TTL を有限必須にし、7 日という上限まで設けた** `+3`
  > `BITFLYER_MAX_OPEN_AGE_MS` は live で必須。未設定・空・非正・`:infinity`・7 日超は `require_max_open_age_ms!/1` が `ArgumentError` で起動を止める（live_safety.ex L113-133）。「有限だが実質無期限（年単位）を拒否する」という上限まで置いたのが良い。設定の抜けだけでなく、**設定を無効化する書き方** も塞いでいる。
  >
  > 万一すり抜けても `aged_open_cutoff/0` が live のとき `DateTime.utc_now()` を cutoff にして全 open を取消し（open_order_policy.ex L248-255）、`Risk.check_live_open_age/1` が `:max_open_age_required` で認可を拒否する（risk.ex L258-271）。起動・取消・認可の三重である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `config/runtime.exs`

- **時計ずれを認可と live 起動突合の両方で検査する** `+2`
  > `Risk.check_source_timestamp/3` を `authorize` から呼ぶだけでなく、live の突合前にも全 `product_code` の ticker を REST で取って同じ関数に通す（reconcile.ex L192-238）。署名 API の時刻依存を踏まえた検査で、`source_timestamp` 欠落は常に拒否する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **halt 時 cancel-all の背圧・in-flight ロック・monitor・cleared 管理** `+4`
  > `HaltCancelGate` という専用 GenServer が ETS を所有し、`try_begin` / `finish` / `watch` / `mark_cleared` / `cleared?` を提供する。`CircuitSync` が 2 秒ごとに halt を再適用しても cancel-all が連打されないよう、失敗後は `halt_cancel_retry_backoff_ms`（既定 30s）まで抑え、in-flight ロックは `halt_cancel_in_flight_stale_ms`（既定 600s）で失効する。非同期 Task は Gate が monitor するので、`finish` 前に死んでもロックが残らない。open が空なら `:cleared` を立てて以後 DB 読取だけで no-op になる。
  >
  > `safe_gate_call/1` が `:exit` を捕まえて `:unavailable` に倒すので、Gate 自体が落ちていても cancel が例外で連鎖しない。この密度の「再試行制御」を halt 経路に置いている個人プロジェクトは見たことがない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`

### order-executor

- **内部注文 ID による冪等 submit と `InFlight` 追跡** `+3`
  > 発注は内部 ID で冪等に送り、進行中の submit / cancel は `InFlight` が持つ。`prep_stop` から drain できるのはこの台帳があるからである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`

- **`TRADE_MODE` の分岐が executor の出口だけで、strategy と risk は同一経路を通る** `+3`
  > overview.md L101 の「同じ経路を通さないペーパーは、本番で初めて壊れる」が実装で守られている。`Risk.authorize` は 3 モードすべてで同じ検査列を通り、モード差は `check_live_product` / `check_live_open_age` / `check_spot_sell_cover` / `paper_unit_price` の各分岐に閉じている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **live 手数料を execution `commission` から記帳し、損益・残高・DailyLoss を同一の net に揃えた** `+4`
  > 4 層が 1 本の数字で繋がっている。(1) `Decode.execution/2` が `commission` を必須・0 以上で要求し、欠落・負は `:invalid_number` で fail-closed（decode.ex L249-260）。(2) `LiveFills` が `execution_fee/1` で再検査して `Fill.fee` に残す（live_fills.ex L475-505）。(3) `Positions` が `realized_pnl = gross − fee` を計算し、建増しでも手数料ぶんだけ負の realized を立てる（positions.ex L201 の `net_realized/2`）。(4) `LiveBalance.fill_delta/2` が記録済み fee を quote デルタに織り込み、fee が NULL の旧行だけ 20bps 許容を残す（live_balance.ex L267-321）。
  >
  > 「手数料をどこか 1 箇所で足して他は無視」ではなく、**損益と残高の両方で同じ fee を使う**ところまで揃えた。しかも `fee` が NULL の過去行という移行問題を許容幅の分岐で扱い、回帰テストでは `balance_fee_tolerance_bps: "0"` に落として「記録済み fee だけで説明できること」を検証している（live_balance_advance_test.exs L73-78）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **execution 単位の Fill と `(trade_mode, exchange_execution_id)` 部分一意** `+4`
  > 部分約定を execution 明細ごとに 1 行として記帳し、取引所の execution id で重複を弾く。再送・再同期・突合で同じ約定が二度載らないことを DB 制約で保証しており、「冪等を願う」ではなく「冪等を強制する」形になっている。`filled_at` も `exec.executed_at` を優先してホスト壁時計に依存しない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **`ensure_execution_coverage` による記帳漏れの fail-closed** `+3`
  > 取引所が返す `filled_size` と、明細から合算した数量が一致しなければ記帳しない。「一部しか取れていない明細で建玉を更新する」ことを構造的に禁じている。ページングを入れた今でも、取り切れなかった場合の最後の砦として残っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **`getexecutions` の `before` ページングと、最終満杯ページの確認** `+3`
  > 単にページングしただけでなく、終了条件が丁寧である。ページが `page_size` 未満なら取り切り。上限ページ（既定 20）に達しても最終ページが満杯なら **もう 1 ページだけ引いて**、空か短ければ取り切りとみなす。まだ満杯なら `:execution_pages_exhausted` で fail-closed。`merge_executions/2` が `MapSet` で id 重複を除くので、ページ境界で新しい約定が入り込んでもずれない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **`submission_unknown` という中間状態と、そこからの recover 経路** `+3`
  > 「送ったか分からない」を `rejected` にも `pending` にも寄せず、独立した状態として持つ。`prep_stop` の drain timeout でもこの状態へ落として circuit を開く。Status UI にも警告色で出て、halt 復帰手順は「Resume せず `mix bitflyer.recover`」と案内する。二重発注を最も生みやすい経路に、専用の状態・専用の手順・専用の画面表示を割り当てている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **paper の不利化 fill pricing と、認可時の拘束額の整合** `+3`
  > paper は成行・指値とも不利方向へ slippage / fee を加味して約定する。それだけなら普通だが、`Risk.quote_notional/2` が **同じ `FillPricing` を使って拘束額を計算する**（risk.ex L730-737）。「認可では素の LTP で拘束し、約定では不利化価格で引く」というズレが出ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **live 発注前の fill 同期に最小間隔と直列化を置く** `+2`
  > `LiveFills.Gate` が最小間隔と直列化を担い、突合・起動側は `force: true` で間引きを無視する（reconcile.ex L256-262）。「認可前の間引き」と「突合の確実性」を別扱いにする判断が明示されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

### datastore / Ash

- **Ash を永続状態に限定し、ホットパスから Resource を呼ばない** `+3`
  > 板・Tick・認可ループは ETS / GenServer にあり、Ash は `Order` / `Position` / `Fill` / `BalanceSnapshot` / `RiskState` / `StrategyParameterRevision` / `BaselineImport` / `DailyEquityPeak` に閉じている。今回 HWM を永続化するにあたっても「Ash は `DailyLoss` GenServer の外」を原則として明記し（daily_loss.ex L5-8）、`record_peak` は `prepare_peak` → 外で persist → `commit_peak` の 3 段にしてある。GenServer の中で DB を叩かないという原則を、新機能でも崩していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/`

- **価格・数量の Decimal 徹底と、float の明示拒否** `+3`
  > 金額を扱う設定パーサが 3 箇所（`LiveBalance.parse_decimal/1`、`LiveInventory.parse_decimal/1`、`LiveSafety.parse_risk_trimmed!/3`）あり、いずれも float を受けない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/live_balance.ex L367-372
  > # float は受けない（金額の float 禁止。config は string / Decimal / integer）。
  > # 未知型は 0（許容なし）へ倒し、端数をごまかして前進しない。
  > defp parse_decimal(_), do: Decimal.new(0)
  > ```
  >
  > 「未知型は許容 0」に倒すのが効いている。設定ミスが「甘い許容幅」ではなく「許容なし」に落ちるので、事故の向きが安全側に固定される。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/startup/live_inventory.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **`BalanceSnapshot.latest_tips/1`（`DISTINCT ON`）と索引** `+2`
  > append-only テーブルから通貨ごとの先端だけを 1 クエリで取る。`Reconcile.read_latest_balances/1`、`LiveBalance.current_tips/1`、`Baseline.existing_tip_currencies/1` がすべてここへ委譲しており、実装が 1 本にまとまっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

- **`pg_advisory_xact_lock` の namespace を用途ごとに分けている** `+4`
  > Balances=1、Baseline import=2、LiveBalance advance=3 と、衝突しない番号を明示的に割り当てている（live_balance.ex L29 のコメント「Balances=1 / Baseline import=2 と衝突させない」）。
  >
  > さらに `LiveBalance.persist_changed/2` はロックを取ったあとに `current_tips/1` を読み直し、`explain` 時点の watermark より tip が進んでいれば **上書きも halt もせず黙ってスキップする**（`tip_moved_since_explain?/3`, L496-525）。resume と定期突合が重なったときに古い `getbalance` で新しい tip を潰す、という具体的な競合を想定して書かれている。楽観的並行制御をここまで正確に組んでいるのは、同種プロジェクトの水準を明確に超えている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **`DailyEquityPeak` の identity / custom_index / validation の三点セット** `+3`
  > `identity :unique_mode_day`、`custom_indexes` の unique index、`validate compare(:peak, greater_than_or_equal_to: 0)` を揃えている。負のピークを持たないという不変条件が、アプリだけでなく DB とバリデーションの両方で表現されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **マイグレーションと resource snapshot を同じコミットで揃える運用** `+2`
  > `20260912180000_add_daily_equity_peaks.exs` と `priv/resource_snapshots/repo/daily_equity_peaks/20260912180000.json`、`20260912220000_add_fills_fee.exs` と `priv/resource_snapshots/repo/fills/20260912220000.json` が対で入っている。ゲートは無いが（弱点に記載）、運用としては守られている。
  > 対象ファイル: `apps/bitflyer/priv/repo/migrations/`, `apps/bitflyer/priv/resource_snapshots/`

### cache / ETS

- **鮮度付き ETS キャッシュに徹し、単一ノードで Redis を増やしていない** `+2`
  > `MarketData.Cache` は `monotonic_ms` ベースの `fresh?/3` を持ち、消えても REST gap-fill と DB から再構築できる。overview.md L91 の方針どおりで、余計なミドルウェアを足していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

- **`BalanceCache` の hold / reserve を GenServer 内で原子化している** `+3`
  > 残高の減額と不足判定が 1 プロセス内で完結するので、複数注文の同時発注でも拘束が漏れない。`reserve_balance_releasing/4` で失敗時の release まで担保している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **ETS の warm（再構築）が全カウンタで揃っている** `+3`
  > `OrderRate` は直近 Order 窓、`FailureRate` は rejected Order 窓、`DailyLoss` は当日 Fill 合計と `DailyEquityPeak`、`BalanceCache` は `BalanceSnapshot.latest_tips` から温める。どれも失敗時は unsynced で fail-closed。「ETS は消えても DB から再構築する」が 4 箇所で同じ形に実装されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

### observe

- **`Bitflyer.Telemetry` を語彙の正本にし、metadata allowlist で秘密を落とす** `+4`
  > イベント名・ログ語彙・メタデータの allowlist が 1 モジュールに集約され、`config/config.exs` L173-205 の logger metadata と対応している。今サイクルで `:unexplained` / `:allowance` / `:currencies` / `:trading_day` が追加され、突合の不一致が「期待・実際・差分・許容」まで構造化ログに出るようになった。halt の事後説明に必要な情報が、文字列補間ではなくフィールドとして残る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `config/config.exs`

- **Discord を発注経路から独立したアダプタにし、HEARTBEAT を持たせた** `+3`
  > `Observe.Discord` は Supervisor の兄弟で、HTTP は Task。未設定でも送信失敗でも取引は止まらない（テストにも `discord notify failed: :forced_failure` が出ている）。さらに「通知経路の死はイベント欠落では分からない」というコメント付きで定期 HEARTBEAT を持つ（config.exs L120-121）。Webhook URL はログにも本文にも出さない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **`OperationalStatus` が「いま発注してよいか」の単一の答えを持つ** `+4`
  > `orders_gate/5` と `market_feed_gate/2` が、Readiness・trade_mode・市場データ鮮度・Feed 接続・`live_confirmed?` を 1 箇所で合成する。UI の `ALLOWED` / `STOPPED`、`/health/ready` の 200 / 503、`Risk.authorize` の可否がすべてここから導かれる。運用者が画面で見る答えと、システムが実際に行う判断が同じ関数から出る構造は、事故調査のコストを桁で変える。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **`Observe.Exposure` が建玉・未約定・残高・当日損益・halt 復帰手順を 1 つの読取にまとめる** `+3`
  > UI は `Bitflyer.System.exposure/0` を 1 回呼ぶだけでよく、各要素のエラー（`positions_error` / `open_orders_error` / `balances_error`）も個別に返る。一部が読めなくても画面全体が落ちない。`record_peak: false` で HWM を動かさない点も含め、観測の副作用が切られている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **公開 API の意味論を匿名 corpus で固定し、CI は実ホストを叩かない** `+4`
  > `priv/contract/corpus/`（実ホスト採取 + 匿名化 + manifest）と `Contract.check_corpus/1` が `precommit` に入り、実 API 呼び出しは人手の `mix bitflyer.contract` に分けてある。取引所 API を CI から叩かない（レート制限・鍵漏洩・非決定性を持ち込まない）という判断と、それでも意味論は検査するという両立が実装されている。`--write-corpus` は注文 ID を自動で伏せる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `apps/bitflyer/priv/contract/corpus/`, `apps/bitflyer/lib/mix/tasks/bitflyer.contract.ex`

### OTP / Application

- **Endpoint と取引監督が別アプリの兄弟で、UI 例外が発注側を巻き込まない** `+3`
  > `Bitflyer.Application` と `Ui.Application` が分かれ、`ui` は `bitflyer` に一方向依存する。overview.md L83 の方針がそのまま構造になっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

- **`prep_stop/1` が「発注停止 → drain → timeout 時は不明化して circuit open」まで書かれている** `+5`
  > グレースフルシャットダウンを「Supervisor の shutdown 秒数を伸ばす」で済ませる実装が大半のなか、ここは OTP の `prep_stop/1` を使って順序を明示している。(1) Discord telemetry を外す、(2) `mark_not_ready_safe/0` で新規 submit を拒否（halted は維持）、(3) `InFlight.drain/1` で進行中を待つ、(4) timeout したら残りの `pending` かつ `exchange_order_id: nil` の Order を `submission_unknown` に更新し、(5) `Risk.open_circuit(:submission_unknown)` でゲートを閉じる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/application.ex L117-121
  > # submit mark が無く cancel のみでも、途中打ち切りは不明扱いしてゲートを閉じる
  > if marked? or leftovers != [] do
  >   _ = Bitflyer.Risk.open_circuit(:submission_unknown)
  > end
  > ```
  >
  > `Readiness.get()` すら `catch :exit` で包み、停止中の GenServer 不在で prep_stop 自体が落ちないようにしている。「落ちるときに何を保証するか」をここまで設計している個人プロジェクトは見たことがない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **子ごとの shutdown 予算を Compose の `stop_grace_period` から逆算している** `+3`
  > `@child_shutdown_ms 5_000` に対し「Supervisor は子を直列停止する。1 子あたりの上限を短くし、Compose stop_grace_period（45s）内に Repo 等の後続クリーンアップ余地を残す」というコメントがある（application.ex L8-11）。config.exs L108 にも「drain ≤10s + 明示 shutdown 子（最大おおよそ 5×5s）≪ 45s」と予算が書いてある。OTP の停止時間とコンテナの猶予時間を足し算で照合している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `config/config.exs`, `compose.prod.yaml`

- **起動シーケンスと Ready 状態を `Bitflyer.Readiness` に正本化した** `+4`
  > `:not_ready` / `:ready` / `{:halted, reason}` の 3 値で、起動直後は `:not_ready`（fail-closed）、不整合時は `halt/1` して Ready へ直接は戻さない。`Reconciler.apply_result/2` は `:ready` / `{:halted, _}` / `:not_ready` を別々に扱い、halted 中は自動で Ready に戻さず手動 `clear_halt` を待つ。さらに paper/live は `DailyLoss` と `BalanceCache` が両方 synced のときだけ Ready にする（`risk_caches_synced?/3`）。overview.md L134 の設計とコードが一致している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **Feed / Strategy を設定で条件付き起動し、無効時は監督ツリーに入れない** `+2`
  > `market_data_feed/0` と `strategy_runner/0` が `enabled?` を見て子リストを組み立てる。テストや観測専用モードで不要なプロセスを立てない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

---

## 技術評価層 — apps/ui

- **責務が「運用状態の閲覧＋ kill / resume / reconcile」に限定されている** `+3`
  > `apps/ui/lib` の LiveView は `status_live.ex` 1 本のみ。発注フォームも板も無い。冒頭に「Operational health check. This is not a trading UI.」と書いてある。Vision の非目標「裁量トレード用の高機能 UI」に踏み込んでいない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **`Bitflyer.System` 経由でのみ `bitflyer` に触り、取引所 API を直接叩かない** `+3`
  > `status_payload/0` は `System.check_database/0` / `System.operational_status/0` / `System.exposure/0` の 3 つだけを呼ぶ。`ui` 側に `Exchange` の参照も Ash クエリも無い。境界が守られている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **halt 理由ごとの復帰手順を画面に出す** `+4`
  > `halt_step_label/1` は 25 種類の手順を持つ。`daily_loss_exceeded` なら「上限超過中は Resume するな。JST 日付が変わるのを待つかフラット化せよ」、`submission_unknown` なら「Resume せず `mix bitflyer.recover`」、`clock_skew` なら「NTP でホスト時計を直せ」。
  >
  > 停止した原因ごとに「次に何をすべきか」を画面で案内する運用 UI は、商用の取引基盤でも珍しい。しかも手順は `Observe.Exposure` が halt reason から導出するので、画面側は表示だけを担当する。深夜に叩き起こされた本人が読む前提で書かれている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **BasicAuth を Plug と LiveView on_mount の二重にし、`/health*` だけ無認証に切り出した** `+4`
  > `/health/live` / `/health/ready` / `/health` は `:api` パイプラインで無認証（外部監視が引けるように）。Status と `/ops/dashboard` は `:browser` の `UiWeb.Plugs.BasicAuth`、さらに LiveView は `UiWeb.Hooks.BasicAuth` が session の `:ui_basic_ok` を要求する。
  >
  > ```elixir
  > # apps/ui/lib/ui_web/hooks/basic_auth.ex L3-6
  > `/health*` 経由で得た匿名 session だけで Status を購読できないようにする。
  > ```
  >
  > 「無認証エンドポイントが session を発行し、それで LiveView に繋げてしまう」という Phoenix 特有の抜け穴を、実際に塞いでいる。prod では資格情報未設定で `raise` する（runtime.exs L290-294）。LiveDashboard も同じ on_mount を通し、Ecto / RequestLogger / 破壊操作は明示オフにしてある。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `apps/ui/lib/ui_web/hooks/basic_auth.ex`, `config/runtime.exs`

- **`start_async` による非ブロッキング更新と LiveView stream の正しい利用** `+3`
  > 5 秒ごとの refresh は `start_async(:status_refresh, &status_payload/0)` で走り、前回が終わっていなければスキップする（`status_refreshing` フラグ）。DB や ETS の読取で LiveView プロセスがブロックしない。建玉・未約定・残高は `stream(..., reset: true, dom_id: & &1.id)` で扱い、メモリを抱えない。操作系も `ops_busy` で二重発火を防ぎ、`{:exit, reason}` を個別に処理する。en / ja の gettext も入っている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **操作者名を BasicAuth のユーザー名から `operator` へ伝播させている** `+2`
  > `Hooks.BasicAuth` が `:ui_basic_username` を `ops_operator` に載せ、kill / resume / reconcile の呼び出しに渡る。ログには `operator=...` が残る（config.exs の metadata allowlist に `:operator` がある）。誰が止めたかが後から分かる。
  > 対象ファイル: `apps/ui/lib/ui_web/hooks/basic_auth.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **開発（bind mount）と本番（release イメージ・非 root・`--chown`）の分離** `+3`
  > 開発 `Dockerfile` はソースを焼かず Compose で bind mount、本番 `Dockerfile.prod` は multi-stage release で uid/gid 1000 の非 root。`.dockerignore` で `.env` / `_build` / `deps` / `.git` を除外している。
  > 対象ファイル: `Dockerfile`, `Dockerfile.prod`, `.dockerignore`

- **`TRADE_MODE` の既定 dry_run・不正値で起動停止・`BITFLYER_LIVE_CONFIRM` の当日日付一致** `+4`
  > `runtime.exs` L80-108 は Application 未起動でも動くよう stdlib だけでパースし、許可値以外は `raise`。`live_confirmed` は `BITFLYER_LIVE_CONFIRM` が **UTC 当日の ISO8601 と完全一致** のときだけ true になる。「一度 live にしたら放っておくと明日も live」を構造的に防ぐ日付確認は、単なる真偽フラグより明確に上である。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

- **live 限定で Risk 上限を環境変数必須にし、形式まで検証する** `+4`
  > `require_risk_limits!/1` が 6 つの上限（order size / position size / daily loss / daily drawdown / orders per minute / price deviation）をすべて必須にし、正の Decimal・非負整数として検証する。エラーメッセージは「開発既定（1 BTC / 5 BTC / 100000 JPY）を live で使ってはならない」と明記する（live_safety.ex L211-218）。**開発既定が本番に載る**という最頻の事故を、起動不能で潰している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **`BITFLYER_WS_URL` の上書きを dry_run / paper に限定し、live では起動停止する** `+3`
  > Game Day の Feed 断注入用に WS URL を差し替えられるようにしたうえで、live では公式 Lightstream を上書きさせない（`Config.WsUrl.resolve/3`）。上書き時は `IO.warn` でホスト名だけを出す（完全な URL は出さない）。テスト用の穴を開けたその場で本番を塞いでいる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/ws_url.ex`, `config/runtime.exs`

- **本番 HTTP bind の既定を loopback にし、prod の BasicAuth を必須にする** `+3`
  > `PHX_HTTP_IP` の既定は `127.0.0.1`、許可値は 4 つだけで、それ以外は `raise`（runtime.exs L370-397）。公開面の最小化が「そう書いてある」ではなく「そうしないと起動しない」になっている。
  > 対象ファイル: `config/runtime.exs`

- **test が開発 DB に触れず、`.env` の資格情報がテストへ漏れない** `+3`
  > `TEST_DATABASE_URL` 優先、未設定なら `_dev` → `_test` へ寄せ、`MIX_TEST_PARTITION` も付く（runtime.exs L18-43）。加えて `config_env() == :test` のとき API キーを強制的に空にし（L136-144）、UI BasicAuth も強制オフにする（L296-299）。いずれも「runtime.exs は test.exs の後に走る」という順序を理解したうえでの明示的な打ち消しで、コメントに理由がある。
  > 対象ファイル: `config/runtime.exs`

- **healthcheck を `/health/live` にし、WS 断でコンテナを再起動しない** `+3`
  > liveness（プロセス生存）と readiness（DB + Readiness + Feed + 鮮度）を分け、Compose の healthcheck は前者を見る。WS が切れただけでコンテナが再起動して状態復元をやり直す、という悪循環を避けている。LiveView Socket が `/live` を使うため liveness を `/health/live` にした、という制約の記録も残っている。
  > 対象ファイル: `apps/ui/lib/ui_web/controllers/health_controller.ex`, `compose.yaml`, `compose.prod.yaml`

- **CI / CD の設計がプロダクション水準である** `+5`
  > 4 点が揃っている。(1) GitHub Actions はすべて commit SHA でピンし、コメントに版を併記（Dependabot が更新できる形）。(2) CD は **同一 SHA の「最新」 ci.yml run** を `gh run list --limit=1` で引き、`status != completed` でも `conclusion != success` でも push を拒否する。「過去に success があるが最新は failure」を通さない、という具体的な攻撃面を塞いでいる。自動待機せず落とす判断も明示的。(3) `deps.audit` を precommit と別ジョブにし、`bin/classify-deps-audit.sh` で「advisory 検出」と「ツール／取得障害」を分類して、後者では落とさない。レポートは artifact に 30 日残る。(4) `Dockerfile.prod` を PR でも push なしでビルドし、そのコストがトレードオフであることをコメントに書いている。
  >
  > 個人プロジェクトの CI は「test を回す」で終わることがほとんどで、ここまで供給網とゲートの整合を詰めている例は見たことがない。
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`, `bin/classify-deps-audit.sh`

---

## 横断評価層

### テスト戦略

- **擬似取引所ハーネスによる live 縦貫通回帰** `+5`
  > `live_balance_advance_test.exs` は Fill を Ash で直接作らない。`System.submit_order` で実際に発注し、`LiveExchangeHarness.apply_fill/2` で部分約定を 2 回入れ、`LiveFills.sync_order` で記帳し、`Reconciler.run_now` で突合し、`Readiness.get() == :ready` と tip 前進を検証し、そのうえで ETS を全部捨てて（`simulate_process_restart!`）再突合まで通す。さらに売り 2 回で建玉を解消し、tip が初期値へ戻ることまで見る。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs L247-251
  > simulate_process_restart!()
  > assert Reconciler.run_now() == :ok
  > assert Readiness.get() == :ready
  > assert_tips!(@after_buy_fee_jpy, @after_buy_btc)
  > assert_net!(Decimal.negate(@fee_total), @fee_total)
  > ```
  >
  > 「前回の live ブロッカーを、部品の単体テストではなく経路の回帰で固定する」という要求に真正面から応えている。外部入金による halt（`credit("JPY", 1)` → `balance_mismatch`）まで同じファイルで固定している点も良い。この種の縦貫通テストは、商用でも書かれないことが多い。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

- **`LiveExchangeHarness` が拘束・手数料・部分約定・open order まで再現する** `+5`
  > 255 行の Agent だが、模している範囲が実物に近い。`place_order` で `available` だけを拘束し（`hold_available/2`）、約定では `amount` を動かして他注文の拘束を消さない。`commission` は拘束外なので quote の `amount` と `available` の両方から引く。`refresh_order/2` は execution 列から `filled_size` / VWAP / `status` を導出する。`fetch_reconcile_snapshot` は `active` な注文だけを open として返す。
  >
  > ```elixir
  > # apps/bitflyer/test/support/live_exchange_harness.ex L193-195
  > # 拘束は place 時に available から引く。約定では amount だけ動かし、
  > # 他注文の残拘束を available=amount で消さない。
  > # commission は拘束外なので quote の amount と available の両方から引く。
  > ```
  >
  > 「available と amount の意味が違う」という取引所の細部をテストダブルに実装し、`completed buy on the harness keeps another buy hold` というテストでハーネス自体の正しさを検証している。テストダブルをテストする発想があるのは、ハーネスが嘘をつくと回帰が無意味になることを理解しているからである。
  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`

- **テスト規模と対象の広がり** `+3`
  > bitflyer 599 テスト + 1 doctest、ui 38 テストの計 **637 本**（前回 521 本）。`test/` は 14098 行で `lib/` の 15551 行にほぼ匹敵する。今サイクルの追加は `feed_test.exs` +513、`regression/live_balance_advance_test.exs` +432、`live_balance_test.exs` +406、`reconcile_test.exs` +346、`risk_test.exs` +267、`rest_test.exs` +198 など、**新機能ごとに単体と経路の両方**が入っている。`ws_url_test.exs` / `live_safety_test.exs` のように設定の起動停止条件までテストしている。
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`

- **`mix precommit` 単一ゲートをローカル / Docker / CI で共有する** `+2`
  > `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `test --warnings-as-errors` の 4 本。`preferred_envs: [precommit: :test]` で環境も固定。今回 `docker compose run --rm -e MIX_ENV=test app mix precommit` が 11.7 秒で全通した。`test --warnings-as-errors` を入れている（test/ は compile 対象外だから、という理由もコメントにある）のは丁寧である。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

### 可観測性・プロセス

- **ドキュメントとコードの一致度が高い** `+4`
  > `vision.md` / `architecture/overview.md` / `env/dev.md` / `env/prod.md` / `env/game-day.md` / `env/watch-ready-evidence.md` / `ci-cd.md` が揃い、今サイクルの変更が overview.md L112 の 1 段落（残高前進の条件、fee の織り込み、絶対床、spot 在庫の比較対象、売りのカバー条件、`getpositions` を呼ばない理由、監視外の明示）に正確に反映されている。**コードを読まずに overview だけ読んでも、live の意味論が再現できる密度**がある。設計文書が実装に追随している例は少数派である。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/`

- **improvement-plan → 実装 → 再評価の自己改善サイクルが機能している** `+4`
  > 前回まとめの P0 2 件・P1 4 件・P2 5 件のうち **9 件がコード上で完了、2 件が部分完了**。1 サイクルで 8884 行追加・107 ファイル変更。各 PR は `fix: P1 #4 live 手数料を...` のように計画の番号を持ち、`gemini review` の修正コミットが後続している。計画・実装・レビュー・再評価のループが実際に回っている。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, git log

- **Game Day / watch-ready の記録が「閉じていないこと」を明記している** `+3`
  > `watch-ready-evidence.md` は「監視と取引は同じ物理ホストに乗る」「常駐は未登録」と自分から書く。`game-day.md` の Stage 2 記録は「Discord チャンネル到達は**未確認**」「halt 後のホスト認可拒否と paper executor 経路での建玉は未実施」「FixedOnce の ID 衝突で建玉は SQL 投入」と、うまくいかなかった部分まで残す。`--private` の記録も「permissions count=33 withdraw=false sendcoin=false」と結論だけで、パス一覧・金額・キーは残していない。
  >
  > 演習記録は成功だけを書きがちで、そうすると次の人が同じ穴に落ちる。ここは誠実で、しかも秘密情報の扱いも守られている。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `.workspace/0_doc/architecture/env/game-day.md`

- **一方向依存と「第3アプリを切らない」方針の順守** `+3`
  > 5 サイクル経っても umbrella は `bitflyer` / `ui` の 2 本のまま。paper も Discord も contract も `bitflyer` 内のアダプタとして実装されている。機能が増えるとアプリを増やしたくなるが、overview.md L61 の方針を守り切っている。
  > 対象ファイル: `apps/`, `.workspace/0_doc/architecture/overview.md`

- **秘密情報の取り扱いが多層で守られている** `+4`
  > (1) キーは環境変数のみ、`.dockerignore` でビルドコンテキストから `.env` を除外。(2) live 起動時に `getpermissions` を叩き、`/v1/me/withdraw` / `/v1/me/sendcoin` があれば halt（`Permissions.assert_safe/1`）。(3) telemetry metadata は allowlist で、秘密らしきキーは落とす。(4) Discord Webhook URL はログにも本文にも出さない。(5) `BITFLYER_WS_URL` の警告はホスト名だけ出す。(6) contract corpus は注文 ID を自動で伏せ、private 応答をリポジトリに置かない。(7) CI に本番シークレットを置かず、CD は `GITHUB_TOKEN` のみ。
  >
  > 「出金権限のないキーを使う」を運用ルールではなく**起動時検査**にしているのが特に良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/permissions.ex`, `.dockerignore`, `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **`mix deps.audit` が CI ゲートとして機能している** `+2`
  > `mix_audit` を `only: [:dev, :test], runtime: false` で導入し、CI の独立ジョブで実行。今回の実行も `No vulnerabilities found.`。Hex advisory の範囲という限界は `ci-cd.md` に記載がある。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer — market-data | +20 |
| apps/bitflyer — strategy | +9 |
| apps/bitflyer — risk-manager | +32 |
| apps/bitflyer — order-executor | +28 |
| apps/bitflyer — datastore / Ash | +17 |
| apps/bitflyer — cache / ETS | +8 |
| apps/bitflyer — observe | +18 |
| apps/bitflyer — OTP / Application | +17 |
| apps/ui | +19 |
| 実行基盤 / 設定 | +28 |
| 横断（テスト戦略） | +15 |
| 横断（可観測性・プロセス） | +20 |
| **合計** | **+231** |
