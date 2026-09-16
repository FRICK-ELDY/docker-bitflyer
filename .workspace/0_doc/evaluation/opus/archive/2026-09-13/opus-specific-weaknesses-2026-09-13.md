# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-13

対象コミット: `cfaf0a5`（`Merge pull request #103 from FRICK-ELDY/ops/p2-game-day-stage-2`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-12](./archive/2026-09-12/opus-specific-weaknesses-2026-09-12.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。すべての判定は当該コードの再読に基づく。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -15 点**

前回の -18 から 3 点改善した。前回 13 件のうち **6 件（-11 点分）は解決を確認した**。とくに前回の live ブロッカー（残高 tip 不前進 `-4`、spot 建玉未照合 `-2`、HWM 非永続 `-2`）はいずれもコード上で閉じている。

一方で **新規に 4 件（-6 点分）** を見つけた。うち 2 件は「P0/P1 を実装した結果、その周辺に残った境界条件」であり、残り 2 件は実装細部の脆さである。そして **1〜2 行で終わる軽微負債 5 件が 5 サイクル連続で残った**。improvement-plan は P3 #15 で「毎サイクル 3 件まで必ず消す」と自ら宣言したが、今サイクルの消化は **0 件** である。

---

## 技術評価層 — apps/bitflyer

### risk-manager

- **認可ホットパスで上がった HWM が永続化されず、再起動でドローダウン基準が緩む（P1 #3 の残差）** `-2`
  > `DailyEquityPeak` の導入そのものは正しい。問題は **ETS にだけ上がったピークを DB へ流す経路が存在しない** ことである。
  >
  > `record_peak` の永続化判定は「**ETS の peak より高いか**」しか見ない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L448-465
  > def handle_call({:prepare_peak, trade_mode, equity_pnl, now}, _from, table) do
  >   ...
  >     new_peak = equity_pnl |> Decimal.max(peak) |> Decimal.max(zero())
  >     if Decimal.compare(new_peak, peak) == :gt do
  >       {:reply, {:rise, day, new_peak}, table}   # ここだけが persist へ行く
  >     else
  >       {:reply, {:ok, new_peak}, table}          # persist しない
  >     end
  > ```
  >
  > 一方で認可経路は `persist: false` で ETS だけ上げる（risk.ex L602-607 の `Keyword.put_new(:persist, false)`）。`risk_test.exs` L259 の `authorize raises HWM in ETS without persisting DailyEquityPeak` はこの挙動を**意図として固定**している。
  >
  > 結果、次の順序で穴が開く。(1) 60 秒周期の `Equity.enforce` が DB に peak=100000 を書く。(2) その後 30 秒のあいだに含み益が伸び、`authorize` が ETS peak を 150000 に上げる（DB は 100000 のまま）。(3) 価格が戻って equity_pnl が 120000 になる。(4) 次の周期 enforce は `prepare_peak(120000)` を呼ぶが、ETS peak 150000 より低いので `{:ok, _}` を返し **DB へ書かない**。(5) ここでプロセスが落ちる。`DailyLoss.init/1` は `load_peaks/2` で DB の 100000 しか読まない（daily_loss.ex L287-292, L599-608）。`reload` の `resolve_peak/4` は「ETS と DB の高い方」を取るが（L561-563）、`init` は ETS を作り直すので比較対象が無い。
  >
  > 再起動後の drawdown は `100000 − 120000 → 0`。本来は `150000 − 120000 = 30000` である。`max_daily_drawdown` を 30000 に設定していても止まらない。Vision L119-122 が本番PC（Windows 11 + WSL2）の予期しない再起動をリスクとして明記している以上、これは踏みうる経路である。前回 `-2` を付けた「実現益後の含み損で再起動すると drawdown が消える」が、「**常に消える**」から「**周期間のピーク分だけ消える**」に縮んだだけで、性質は同じである。improvement-plan の完了条件「実現益後の含み損状態で再起動・突合 reload しても drawdown が消えない」は、周期をまたぐピークについては満たされていない。
  >
  > 改善方針: ETS 行に `persisted_peak` を 1 列足し、persist 点（Fill 後 / 突合 / resume）で `peak > persisted_peak` なら `peak` を flush する。`prepare_peak` の戻りを `{:rise, day, new_peak}` / `{:flush, day, peak}` / `{:ok, peak}` の 3 値にすれば、GenServer の外で Ash を呼ぶ現在の構造を崩さずに入る。あるいは認可も persist させ、`upsert` の頻度を「前回 persist から N ms」で間引く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`DailyEquityPeak` の一意制約衝突検出が `inspect(error)` の文字列一致に依存している** `-1`
  > 並行 upsert の競合を拾うために、Ash のエラーを**文字列化して部分一致**で判定している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L141-176
  > defp unique_mode_day_taken?(error) do
  >   unique_mode_day_name?(inspect(error)) or
  >     error |> error_leaves() |> Enum.any?(&identity_collision?/1)
  > end
  > ...
  > defp unique_mode_day_name?(text) when is_binary(text) do
  >   String.contains?(text, "unique_mode_day") or
  >     String.contains?(text, "daily_equity_peaks_unique_mode_day")
  > end
  > ```
  >
  > 構造的なマッチ（`%{identity: :unique_mode_day}` 等）を 5 パターン並べたうえでの保険なので、今すぐ壊れるわけではない。ただし `inspect/1` の出力はライブラリのバージョンで変わる契約のない文字列であり、`error_leaves/1` が拾えない形に Ash がエラーを包み直せば静かに外れる。外れたときの挙動は `{:error, _}` → `peak_persist_failed` → 当該モード unsynced → `authorize` が `daily_loss_unsynced` で全拒否である。fail-closed なので資金は減らないが、**並行 Fill と周期 enforce が重なっただけで取引が止まる**ことになる。しかもこの経路は `record_peak` から毎回通る。
  >
  > 加えて `identity_collision?/1` の最後の節が `Exception.message(other)` を `rescue _ -> false` で包んでおり、構造体でない任意項を握りつぶす。例外分類のコードとしては広すぎる。
  >
  > 改善方針: `Ash.Changeset.for_create(..., upsert?: true, upsert_identity: :unique_mode_day)` か、AshPostgres の `ON CONFLICT ... DO UPDATE SET peak = GREATEST(excluded.peak, peaks.peak)` を直接使い、read → create → rescue の三段を 1 文に畳む。HWM は単調増加なので `GREATEST` で意味論が完全に表現できる。文字列一致の分岐はまるごと不要になる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **残高の「検査」と「予約」が別段のままで、認可通過 → 予約失敗の再試行ループが残る（前回から未解決）** `-1`
  > `Risk.authorize/2` の `check_available_balance/2` は `BalanceCache.get/2` の値を読んで比較するだけ（risk.ex L630-702）。実際の減額は認可後の `OrderExecutor.reserve_balance/3` → `BalanceCache.reserve/4`。予約は GenServer 内で原子的に不足を弾くので資金は守られるが、`Runner` は `:insufficient_balance` を明示的に再試行対象にしている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/strategy/runner.ex L36-40
  > @retryable_limit_kinds [
  >   :max_orders_per_minute,
  >   :max_daily_loss,
  >   :insufficient_balance
  > ]
  > ```
  >
  > 混雑時は「認可 → 予約失敗 → throttle 後に再試行」が回り続ける。`OrderRate` は release されるので枠は漏れないが、`AuthorizedOrder` の mint/consume は毎回消費される。今サイクルで `Risk` の moduledoc は大幅に加筆され（残差や設計意図が丁寧に書かれるようになった）、`check_spot_sell_cover` のように「認可と突合で同じ集計を使う」原則まで明文化されたのに、**残高だけが「近似判定＋別経路の正本」のまま、その旨の記述も無い**。他が揃っているぶん目立つ。
  >
  > 改善方針: `BalanceCache` に `probe/4`（予約せず同一ロジックで可否だけ返す）を足して `authorize` から呼び、判定コードパスを 1 本にする。`SpotInventory` で売りカバーに対して行った「認可と突合を同一関数に寄せる」のと同じ処方である。当面直さないなら、少なくとも `Risk` の moduledoc に「残高判定は近似であり正本は reserve」と書き、`Runner` の `:insufficient_balance` 再試行にバックオフを付ける。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### 起動・突合（live の意味論）

- **突合窓のあいだに入った約定は、「取引所が内部より先」の向きだけ再同期されず即 halt する** `-2`
  > `LiveBalance` の前進は、取引所と内部の時間差を **片側だけ** 吸収する。内部 Fill が先行して取引所 `getbalance` が未反映のとき（`balance_exchange_lag`）は 1 回だけ再取得する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L292-307
  > {:error, :reconcile_mismatch, %{kind: :balance_exchange_lag} = meta} when retries > 0 ->
  >   Bitflyer.Telemetry.log(:info, "live getbalance lagged fills; refetching once", ...)
  >   with {:ok, snapshot2} <- fetch_live_snapshot(exchange) do
  >     compare_or_refetch_lag(internal, snapshot2, required, ...)
  >   end
  > ```
  >
  > ところが逆向き（取引所に約定が反映済みで、内部 Fill がまだ無い）には同じ救済が無い。`exchange_lag?/4` は `Decimal.eq?(right_amount, left_amount)` を要求するので（live_balance.ex L229-233）、取引所側が動いていれば当たらない。そのまま `fee_explained?/2` に落ち、買いなら JPY が `notional + fee` ぶん余計に減って `unexplained` が大きく負、BTC は増えているので「入金」とみなされて即 `false`（live_balance.ex L247-257）。どちらも `balance_mismatch` である。
  >
  > 窓は狭い。`reconcile_mode/4` は `sync_live_fills(exchange)` → `restore(:live)` → `fetch_live_snapshot(exchange)` の順に走るので（reconcile.ex L159-168）、危険なのは fill 同期の完了から `getbalance` の応答までの数百 ms である。しかし周期突合は 60 秒ごとに回り続け、live で戦略が動いていれば約定はいつでも入りうる。`reconcile_mismatch` は `cancel_on_halt` が `false`（config.exs L44）なので未約定は板に残り、復旧には人が Status の Resume を押す必要がある。**「人が張り付かなくても回し続ける」という Vision の中心要件に対して、原理的に避けられない誤検知が残っている**のが問題で、止まり方そのものは安全側である。
  >
  > なお同じ理由で、`explain` が Fill を読んでから `captured_at`（= `now + 1µs`）を決めるまでの間に記帳された Fill は、次回の `since` より前になって恒久的に説明対象から落ちる（live_balance.ex L384-420）。こちらはマイクロ秒オーダーなので実害はまず無いが、原因は同じ「片側しか再同期しない」である。
  >
  > 改善方針: `balance_mismatch` の直前に対称の救済を 1 段入れる。`unexplained` が「取引所が先行している」向き（買いなら quote 減・base 増）のときは `LiveFills.sync_open_orders(force: true)` をもう一度回して Fill を読み直し、それでも説明できないときだけ halt する。再試行回数は `balance_lag_retries` と同じ 1 回で足りる。あるいは `getbalance` を fill 同期の**前**に取り、内部 Fill の読取をそのあとにすれば、向きが `balance_exchange_lag` 側に固定されて既存の救済に乗る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

### market-data

- **ticker 一本のままで、板・約定ストリームと spread ゲートが無い（前回から未解決）** `-1`
  > `Normalize.from_ticker/1` が取り出すのは `ltp` と `source_timestamp` の 2 つだけ（normalize.ex L20-32）、購読も `lightning_ticker_*` のみ（feed.ex L312 の `MarketData.ticker_channel/1`）。`best_bid` / `best_ask` を読むコードはリポジトリに存在しない。
  >
  > 影響は 2 つ。(1) `Paper.decide_fill/3` が板の厚みを見ないため、大口の部分約定・不成立を paper で再現できない。(2) `Risk.authorize/2` の検査列（risk.ex L95-110）に spread ゲートが無く、異常スプレッド時の成行を拒否できない。今サイクルで検査列は `check_market_feed` / `check_spot_sell_cover` と 2 段増え、`check_price_deviation` は指値の LTP 乖離を見るようになったが、**成行の実効価格を守る入力そのものが無い**状態は変わっていない。live を spot 最小ロットで始める前提なら実害は小さいので `-1` に留める。
  >
  > 改善方針: `lightning_executions_*` を購読して直近約定列を `Cache` に置き、paper の約定サイズを出来高で頭打ちにする。`ticker` の `best_bid` / `best_ask` は REST の gap-fill でも取れているので、`Normalize.from_ticker/1` に 2 フィールド足すだけで spread ゲートは先に作れる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **常時接続の中核が更新の止まった依存（`websockex` 0.4）に載ったままで、その事実がどこにも記録されていない（5 サイクル連続）** `-1`
  > `apps/bitflyer/mix.exs` の `{:websockex, "~> 0.4"}` は変わっていない。最終リリースは 2019 年の 0.4.3 で、OTP 27 の TLS 既定変更への追随は保証されない。`mix deps.audit` は Hex advisory しか見ないため（今回の実行も `No vulnerabilities found.`）、「メンテされていない」は CI に現れない。
  >
  > 前回の改善方針は「移行するか、`ci-cd.md` の非保証欄に明記する」だった。`ci-cd.md` を `websockex` で検索しても 1 件も当たらない。`socket.ex`（全 60 行）の moduledoc も「Lightstream JSON-RPC WebSocket（WebSockex）。」の 1 行のみで、リスクの記述は無い。今サイクルで P2 #7 の購読 ACK を入れたときに `Socket.Client` behaviour と `Socket.Local` の分離はさらに強化され、差し替えコストは**下がった**。それでも 1 行の記録すら残らないのは、負債が可視化されていないからである。
  >
  > 改善方針: `Mint.WebSocket` + 自前 GenServer か `Fresh` へ behaviour 実装を差し替える。当面移行しないなら `ci-cd.md` L69 付近の「CI / CD が保証しないこと」に 1 行足し、`socket.ex` の moduledoc にも既知リスクとして残す。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `.workspace/0_doc/architecture/ci-cd.md`

### datastore / Ash

- **永続データの保持・剪定方針がどこにも無く、当日集計が全行読みのまま（5 サイクル連続）** `-1`
  > `fills` / `balance_snapshots` / `orders` / `strategy_parameter_revisions` / `baseline_imports` / `daily_equity_peaks` はいずれも append-only で、削除・アーカイブ・パーティションのどれも無い。`prod.md` を「保持 / retention / 剪定 / compact」で検索しても 1 件も当たらない。
  >
  > 今サイクルでこの負債は**重くなった**。`DailyLoss.sum_realized/3` は当日分の Fill を Ash で全行読んで Elixir 側で合算する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L610-626
  > case Fill
  >      |> Ash.Query.filter(trade_mode == ^trade_mode and filled_at >= ^start_utc and filled_at < ^end_utc)
  >      |> Ash.read() do
  >   {:ok, fills} ->
  >     net = Enum.reduce(fills, Decimal.new(0), fn fill, acc -> Decimal.add(acc, fill.realized_pnl || Decimal.new(0)) end)
  > ```
  >
  > `Reconciler` は 60 秒ごとに `DailyLoss.reload()` を回し（reconciler.ex L147）、`reload` は全 3 モードぶん `load_modes/2` を呼ぶ。そのうえ今サイクルで `LiveBalance.load_fills_since/2` が加わり、突合のたびに tip 以降の Fill を**もう一度**読む（live_balance.ex L384-406）。live の Fill は execution 単位なので行数は以前より増える設計である。512 GB（vision.md L118）で当面破綻はしないが、「ETS は消えても再構築できる／DB は無限に育つ」の非対称が、コードにも文書にも扱われていない点は変わらない。
  >
  > 改善方針: `prod.md` に保持期間（例: fills 2 年、balance_snapshots 90 日で日次ロールアップ）を書き、`mix bitflyer.compact` を用意する。当面剪定しないなら「しない。判断閾値は行数 N / サイズ M」と文書に残す。あわせて `sum_realized/3` を `Ash.aggregate(:sum)` か生 SQL の `SUM` に変える（行を BEAM へ運ばない）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `.workspace/0_doc/architecture/env/prod.md`

---

## 技術評価層 — 実行基盤 / 設定

- **`mix precommit` に Ash マイグレーションのドリフト検査が無い（5 サイクル連続）** `-1`
  > 品質ゲートは 4 本のままである。
  >
  > ```elixir
  > # mix.exs L47-53
  > precommit: [
  >   "deps.unlock --check-unused",
  >   "format --check-formatted",
  >   "compile --warnings-as-errors",
  >   "test --warnings-as-errors"
  > ],
  > ```
  >
  > `mix ash.codegen --check` が無いので、Resource の attribute を変えてマイグレーションを書き忘れても CI は緑で通る。今サイクルはまさにドリフトしやすい変更を 2 本入れた。`DailyEquityPeak` の新設（`20260912180000_add_daily_equity_peaks.exs` + snapshot）と `Fill.fee` の追加（`20260912220000_add_fills_fee.exs` + snapshot）である。今回は整合しているが、それは人が気を付けた結果で、ゲートが保証した結果ではない。resource は今回 1 本増えて、次サイクル以降の面積はさらに広い。
  >
  > 改善方針: `precommit` の `compile` の後に `"ash.codegen --check --domains Bitflyer.Trading"` を 1 行足す。snapshot は既にコミット済みなので追加コストはほぼゼロである。
  > 対象ファイル: `mix.exs`

- **開発コンテナが root で実行される（5 サイクル連続）** `-1`
  > 開発用 `Dockerfile` は全 20 行で `USER` 指定が無い。bind mount した `/app` 配下（`.:/app`）に root 所有のファイルが生まれる。`deps` / `_build` は名前付きボリュームに逃がしてあるが、`priv/static/assets` や `priv/contract/corpus`（`mix bitflyer.contract --write-corpus` の出力先）のようにホスト側へ落ちる生成物は root 所有になる。
  >
  > `Dockerfile.prod` は非 root 化し `--chown=app:app` まで付けているので、方針そのものは理解されている。開発側だけが取り残されており、WSL2 ホストでの日常的な摩擦になる。今サイクルは `bin/watch-ready.ps1` / `bin/register-watch-ready-task.ps1` を追加して Windows ホスト側の運用面を厚くしたので、ホスト↔コンテナのファイル所有権の摩擦はむしろ増える方向である。
  >
  > 改善方針: 開発 `Dockerfile` にも uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる（`bin/docker-entrypoint.sh` で `chown` するか、`user: "1000:1000"` を compose に足す）。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

---

## 横断評価層

### テスト戦略

- **`test_helper.exs` に Sandbox のモード指定が無い（5 サイクル連続）** `-1`
  > `apps/bitflyer/test/test_helper.exs` は `ExUnit.start()` の 1 行のみで、`apps/ui/test/test_helper.exs` も同じ。`Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` が呼ばれていない。
  >
  > 現状は DB を触るテストがすべて `Bitflyer.DataCase` / `UiWeb.ConnCase` 経由で `start_owner!/2` するため実害は出ていない（今回の実行でも 637 テストが 0 failures）。ただしテストは前回 521 本から **637 本**に増え、今サイクルの追加分には `regression/live_balance_advance_test.exs`（432 行、`async: false`）や `live_inventory_test.exs` のように DB 状態へ強く依存するものが多い。`use` を書き忘れたテストが 1 本入った時点でテスト DB に実データが残り、他テストの `read_one` が壊れて初めて気付く形になる。事故時の原因特定コストは 1 サイクルごとに上がっている。1 行で「checkout していないプロセスは DB に触れない」が保証できる。
  >
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加する。
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`

### 可観測性

- **別ホスト監視が「同一物理ホスト」までで、本番構成としてはまだ成立していない** `-1`
  > P2 #10 の実装（`bin/watch-ready.ps1` 122 行、`bin/register-watch-ready-task.ps1` 54 行）と証跡（`watch-ready-evidence.md`）は良い。非 ready（HTTP 500）と到達不能（`http=000` × 3 → `ready watch alert`）の両方を実際に走らせて記録している点は評価する。
  >
  > ただし文書自身が認めているとおり、監視ホストと取引プロセスは同じ PC に乗っている。
  >
  > ```
  > # .workspace/0_doc/architecture/env/watch-ready-evidence.md L17-19
  > 開発 Compose をこの作業 PC で動かしているあいだ、監視と取引は **同じ物理ホスト** に乗る。
  > ...
  > | 常駐登録 | 未登録（`bin/register-watch-ready-task.ps1` は手順のみ。取引ホストでは動かさない） |
  > ```
  >
  > overview.md L167 は「同一ホスト死の検知は取引ホストの外。別ホストが `GET /health/ready` を pull し、ホスト exporter を scrape する」を設計として掲げている。現状で検知できるのは「アプリが 500 を返す」「ポートが死んだ」までで、**ホストごと落ちた場合（Windows Update の再起動、WSL2 のハング）は依然として誰も気付かない**。Vision の「人が張り付かなくても」を支える最後の一枚が、道具は揃ったのに配備されていない状態である。improvement-plan の完了条件は「記録がある」なので形式的には満たすが、資金保全の観点では満たしていない。
  >
  > 改善方針: VLAN1 本番 PC を `READY_URL` にして作業用 PC1 で `register-watch-ready-task.ps1` を実行し、`watch-ready-evidence.md` に「本番向き常駐」の行を足す。あわせて `windows_exporter` 等のホスト exporter を別ホストから scrape する側も 1 段作る。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`, `.workspace/0_doc/architecture/env/prod.md`

### ドキュメント・プロセス

- **improvement-plan の P3 #15「毎サイクル 3 件まで必ず消す」が 0 件で、軽微負債 5 件が 5 サイクル連続で残った** `-1`
  > 前回の総括で「P3 のうち 1 行で終わるものは別枠にしたほうが早い」と書き、improvement-plan はそれを受けて P3 #15 に **「毎サイクル 3 件まで必ず消す」** と明記した。
  >
  > ```
  > # .workspace/0_doc/evaluation/improvement-plan.md L57
  > | 15 | 軽微負債一括 | **毎サイクル 3 件まで必ず消す**: `ash.codegen --check`、開発 Dockerfile の USER、
  >      Sandbox mode、websockex 記録または移行、`apps/bitflyer/README.md`、Hex 外 scanner |
  > ```
  >
  > 今サイクルで消えたのは **0 件** である。`mix.exs` の precommit は 4 本のまま、`Dockerfile` に `USER` なし、両 `test_helper.exs` は 1 行のまま、`websockex` は `~> 0.4` で記録もなし、`apps/bitflyer/README.md` は `**TODO: Add description**` のまま。一方で P0 2 件・P1 4 件・P2 5 件は完走し、8884 行を追加している。**実行力の問題ではなく、優先度づけの構造の問題**である。
  >
  > この 1 点は上に個別計上した 5 件とは別軸で、「自己改善サイクル（improvement-plan の運用）が自分で決めたルールを守れていない」ことに対する減点である。計画が守られない前提で運用されると、次に「P0 は必ず塞ぐ」と書いたときの信頼度も下がる。
  >
  > 改善方針: P3 #15 を「P0/P1 と同じブランチに相乗りさせる」運用に変える。たとえば P0 のブランチで必ず 1 件、P1 で 1 件、P2 で 1 件を同時にコミットする。どれも 1〜2 行なので PR のレビュー負荷は増えない。それができないなら P3 #15 から「必ず」を消し、達成できない宣言を計画に残さない。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

- **`apps/bitflyer/README.md` が生成テンプレのまま残っている（3 サイクル連続）** `-1`
  > リポジトリ全体で `TODO` / `FIXME` を検索して当たるのはこの 1 箇所だけである。
  >
  > ```
  > # apps/bitflyer/README.md L3
  > **TODO: Add description**
  > ```
  >
  > 中身は Hex 公開用のテンプレ（`{:bitflyer, "~> 0.1.0"}` を deps に足せ、HexDocs で公開せよ）で、umbrella の中核アプリ（`lib` 15551 行 / `test` 14098 行）の説明としては誤情報でもある。ルート `README.md`、`apps/ui/README.md`、`.workspace/0_doc/` が丁寧に整備されているだけに落差が目立つ。
  >
  > 改善方針: 10 行程度で責務（取引所連携・ドメイン・エンジンの正本、論理コンポーネントの配置、ルート README と overview.md へのリンク）を書く。不要なら削除する。
  > 対象ファイル: `apps/bitflyer/README.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer — risk-manager | -4 |
| apps/bitflyer — 起動・突合（live の意味論） | -2 |
| apps/bitflyer — market-data | -2 |
| apps/bitflyer — datastore / Ash | -1 |
| 実行基盤 / 設定 | -2 |
| 横断（テスト戦略） | -1 |
| 横断（可観測性） | -1 |
| 横断（ドキュメント・プロセス） | -2 |
| **合計** | **-15** |

---

## 前回マイナス点の解決状況（コード再読で確認）

| 前回の指摘 | 前回 | 状況 | 根拠 |
|:---|:---:|:---|:---|
| live 残高突合が固定 baseline との厳密一致 | -4 | **解決** | `LiveBalance.explain/advance`（live_balance.ex 全 547 行）。`compare_with_exchange` が explain → LiveInventory → open_orders → advance の順で走る（reconcile.ex L320-341）。`Baseline` は初期化専用のまま、`rebaseline?: true` が別経路（baseline.ex L169-184, L379-399） |
| live spot で建玉突合が無効 | -2 | **解決** | `LiveInventory.compare/4`（152 行）が `getbalance` の base amount と買い `Position.size` を通貨ごとに比較。売建玉は `spot_short_position`、超過は `spot_inventory_inflated`（live_inventory.ex L37-97）。認可側は同じ `SpotInventory` を使う（risk.ex L485-502） |
| 当日 equity ピーク（HWM）が非永続 | -2 | **部分解決** | `DailyEquityPeak` Resource + `load_peaks/2`（daily_loss.ex L599-608）で init/reload/reinit が当日行を読む。ただし認可 ETS 上のピークを flush する経路が無い（本文の新規 `-2` を参照） |
| `Risk.authorize/2` が Feed 接続を見ない | -1 | **解決** | `check_market_feed/2` が `check_freshness` の前（risk.ex L101）。入力は `Feed.connection_snapshot/0`（`:persistent_term` の `{pid, connected?}` 一致検査、feed.ex L54-68）。`operational_status.ex` の残差記述も削除済み |
| 残高検査と reserve のねじれ | -1 | **未解決** | risk.ex L630-702 と `BalanceCache.reserve` は別段のまま。`Runner.@retryable_limit_kinds` に `:insufficient_balance`（runner.ex L36-40） |
| `getexecutions` のページングなし | -1 | **解決** | `fetch_execution_pages/6` が `before` で降順に取り切る。最終満杯ページは次ページが空/短いときだけ確定、続きがあれば `:execution_pages_exhausted`（rest.ex L113-199）。`execution_page_size: 500` / `execution_max_pages: 20`（config.exs L17-18） |
| ticker 一本 | -1 | **未解決** | normalize.ex L20-32 は `ltp` / `source_timestamp` のみ。`best_bid` / `best_ask` の参照はリポジトリに無い |
| `websockex` 0.4 依存 | -1 | **未解決** | `apps/bitflyer/mix.exs` 変更なし。`ci-cd.md` に `websockex` の記述なし |
| 永続データの保持方針が無い | -1 | **未解決** | `prod.md` に保持期間の記述なし。`sum_realized/3` は全行読みのまま |
| `precommit` に `ash.codegen --check` が無い | -1 | **未解決** | mix.exs L47-53 変更なし |
| 開発コンテナが root | -1 | **未解決** | `Dockerfile` に `USER` なし |
| `test_helper.exs` に Sandbox mode が無い | -1 | **未解決** | 両方とも `ExUnit.start()` の 1 行のまま |
| `apps/bitflyer/README.md` が TODO テンプレ | -1 | **未解決** | L3 変更なし |

**解決 6 件（-11 点分）/ 部分解決 1 件 / 未解決 6 件（-6 点分）。**

未解決 6 件のうち 5 件（`ash.codegen`、Dockerfile root、Sandbox mode、`websockex`、保持方針）は **5 サイクル連続** で残っている。いずれも 1〜2 行で片付く種類である。前回・前々回と同じ文を書いており、今回は「毎サイクル 3 件必ず消す」という自分たちの宣言つきで 0 件だったため、プロセス側にも `-1` を計上した。
