# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-10_2

対象コミット: `2c21cf9`（`Merge pull request #68 from FRICK-ELDY/fix/p3-cleanup-noise`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-10](./archive/2026-09-10/opus-specific-weaknesses-2026-09-10.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -24 点**

前回の -33 から 9 点改善した。improvement-plan の P0–P3「済」主張はコード再読で**すべて解決を確認した**（DailyLoss/BalanceCache の本番接続、両建て net、LiveSafety、Decode strict、baseline/recover/FailureRate/stall/InFlight、AuthorizedOrder/FillPricing/StatusLive halt）。以下は新規に見つかったものと、複数回連続で未解決の軽微項目である。

---

## 技術評価層 — apps/bitflyer

### risk-manager

- **既定銘柄 `FX_BTC_JPY` に対し、スポット `getbalance` + BTC/JPY 拘束モデルを当てている** `-3`
  > システムの既定銘柄は Lightning FX の `FX_BTC_JPY` である（`MarketData` 既定・`Exchange.Rest.@default_product`・大半の fixture）。一方、残高の正本は `/v1/me/getbalance` のみで（rest.ex L140-145）、`getcollateral` は呼ばない。認可時の拘束もスポット前提で、買いなら `quote_currency`（JPY）、売りなら `base_currency`（BTC）を `BalanceCache` から要求する（risk.ex L107-118、product.ex L7-20）。
  >
  > FX では売りにスポット BTC は不要で、拘束の正本は証拠金（担保・必要証拠金・維持率）である。現状だと (1) スポット BTC が無いと売りが `insufficient_balance` で拒否され、FX ショートが事実上できない、(2) 逆にスポット JPY/BTC が十分でも証拠金不足の発注を通しうる、(3) live の突合で「残高一致」しても担保状態は見ていない。Build した BalanceCache / hold 会計はスポットには正しいが、**既定プロダクトの資金モデルと不一致**である。Vision の Safety first に対し「検査は動いているが測っている量が違う」状態で、P0 #2「残高検査の実効化」を形だけ満たして中身を取り違えている。
  > 改善方針: FX 銘柄では `getcollateral`（および必要なら `getcollateralaccounts`）を突合・BalanceCache の正本にし、売り拘束を「必要証拠金の見積もり」に切り替える。スポット `BTC_JPY` は現行モデルを維持し、`Product` か `TradeMode` 周辺で銘柄種別を分岐する。live 解禁前に「FX で何を available とみなすか」を overview / README に明示する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

### order-executor

- **部分約定の増分に「累積 VWAP」を掛けており、建玉平均単価と実現損益がずれる** `-2`
  > `LiveFills.apply_order_info/3` は取引所の `filled_size` とローカルの差分 `delta` を取り、その `delta` に対する約定価格として `info.average_price` を使う。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex L186-190
  > defp fill_price(%Order{} = order, info, exchange) do
  >   cond do
  >     match?(%Decimal{}, info.average_price) and Decimal.positive?(info.average_price) ->
  >       {:ok, info.average_price}
  > ```
  >
  > bitFlyer の `average_price` は**その注文の全約定の加重平均**であって、今回の増分の平均ではない。0.5 が 100 万で約定した直後に同期し、次に 0.5 が 200 万で約定して再同期すると、2 回目の増分 0.5 に対して `average_price = 150 万` が適用される。正しくは `(1.0×150 − 0.5×100) / 0.5 = 200 万`。結果として `Positions.apply_fill/2` が積む建玉 VWAP、`Fill.price`、`Fill.realized_pnl` のすべてが実勢からずれる。
  >
  > このずれは 3 方向に効く。(1) `Risk.DailyLoss` は `Fill.realized_pnl` を正本にしているので（daily_loss.ex L380-396）、日次損失サーキットの発火点が実際とずれる。(2) 起動突合 `compare_positions/2` は建玉平均単価を `Decimal.eq?` で厳密比較する（reconcile.ex L460-463）ので、取引所と内部で平均が食い違い `position_mismatch` で halt する。halt は安全側だが、部分約定が普通に起きるだけで無人稼働が止まる。(3) 決済時の実現損益が誤る。fail-closed には倒れるので `-3` にはしないが、live の主要ケースで確実に踏む欠陥である。
  > 改善方針: `Order` に累積約定代金（`filled_notional`）を持たせ、`delta_price = (remote_filled × remote_avg − filled_notional) / delta` で増分価格を導く。あるいは `fetch_executions` の `id` 単位で未取込の約定だけを畳み込む（下記 `exchange_execution_id` の未使用解消と同時に解ける）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **live 発注 1 回につき「未約定注文の全件照会」を 2 回走らせており、取引所レート制限に触れうる** `-2`
  > 同期呼び出しが二重になっている。`System.submit_order/2` が認可前に 1 回、
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/system.ex L363-367
  > with :ok <- reject_if_order_gate_closed(),
  >      :ok <- Bitflyer.OrderExecutor.sync_live_fills_before_authorize(trade_mode, opts),
  >      {:ok, authorized} <- Bitflyer.Risk.authorize(command, opts) do
  >   Bitflyer.OrderExecutor.submit(authorized, opts)
  > ```
  >
  > `OrderExecutor.do_submit/2` が実行直前にもう 1 回呼ぶ（order_executor.ex L91-92 の `maybe_sync_live_fills(trade_mode, opts)`）。どちらも `LiveFills.sync_open_orders/1` で、これは open 注文 1 件ごとに `fetch_order`（`getchildorders`）を撃つ（live_fills.ex L26-33）。さらに place 成功後に `sync_fills_after_place/2` が 1 回（live.ex L52）。
  >
  > 未約定が N 件あると 1 発注あたり `2N + 1` 回の private REST を消費する。`max_orders_per_minute: 20` を許した設定で N=5 なら毎分 220 リクエストになり、bitFlyer の private API 制限（概ね 5 分 500 回）を超える。超えた 429 は `Decode.map_error/2` で `:rate_limited` になり（decode.ex L259）、`FailureRate.@countable_reasons` に含まれるので（failure_rate.ex L20-26）、窓内 5 回で `:consecutive_exchange_errors` halt に到達する。**自分の同期処理が原因でサーキットが開く**という構図になっており、しかも live 実運用に入るまで表面化しない。
  > 改善方針: 認可前同期と実行直前同期のどちらか一方に統一する（認可前が本命なのでコメントどおり `do_submit` 側を落とす）。加えて `sync_open_orders` に最小間隔（例: 直近 1 秒以内の同期はスキップ）を入れ、`Exchange.Rest` にトークンバケットのレート制限を持たせる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **`Fill.exchange_execution_id` が常に `nil` で、約定単位の冪等性と監査証跡が張れていない** `-1`
  > Resource には `exchange_execution_id` 属性があり（fill.ex L49-52）、マイグレーションにもカラムがある（20260910010000_add_fills.exs L12）。しかし書き込み側は常に `nil` を入れる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/positions.ex L160-171
  > defp insert_fill(%Order{} = order, fill_price, size, realized_pnl) do
  >   attrs = %{
  >     internal_order_id: order.internal_order_id,
  >     exchange_execution_id: nil,
  > ```
  >
  > `Exchange.Client.execution()` は `id` を型定義まで持っており（client.ex）、`LiveFills.recover_missing_order/2` は `fetch_executions` の結果を実際に受け取っている（live_fills.ex L98-102）のに、その `id` を捨てている。unique 制約も無い（同マイグレーションの index は `[:trade_mode, :filled_at]` と `[:internal_order_id]` のみ）。結果として (a) 同じ取引所約定を二重に Fill 行にしていないかを DB 制約で保証できない、(b) 「どの取引所約定がどの内部 Fill に対応するか」を後から人が突き合わせられない。いまは差分計算で二重取込を避けているが、それはアプリのロジックが正しい限りという条件付きである。
  > 改善方針: `LiveFills` が `fetch_executions` の各行を 1 Fill として書き、`exchange_execution_id` に unique index を張る。差分 `delta` の畳み込みではなく約定明細の取込に変えれば、上記の VWAP 問題も同時に解ける。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/priv/repo/migrations/20260910010000_add_fills.exs`

- **`Fill.filled_at` がホスト壁時計で、日次損失の日跨ぎ判定が取引所時刻から外れる** `-1`
  > `insert_fill/4` は `filled_at: DateTime.utc_now()` を入れる（positions.ex L170）。一方 `DailyLoss.load_modes/2` は `filled_at` で JST 取引日を切る（daily_loss.ex L365-378）。取引所の `exec_date` は `Decode.execution/2` が `executed_at` として拾っているのに（decode.ex L206）、Fill には渡っていない。
  >
  > 影響は 2 つ。(1) WS 断や API 不調で同期が数分遅れると、JST 0 時直前の約定が翌取引日に計上され、当日の損失合計が過小になる。日次損失サーキットは「その日の損を止める」ための装置なので、境界での過小評価は装置の目的に直接反する。(2) Vision L122 が本番PC（WSL2）の時刻ずれを明示的なリスクに挙げているのに、日次集計がまさにそのホスト時計に依存している。`Risk.check_source_timestamp/3` で発注時の skew は見ているぶん、記録側だけが無防備なのがちぐはぐである。
  > 改善方針: `LiveFills` が `execution.executed_at` を `filled_at` に渡す（欠落時のみ `utc_now`、その事実をログに残す）。paper は擬似約定なので `utc_now` のままでよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **残高の「検査」と「予約」が別トランザクションで、判定が古いまま通る窓がある** `-1`
  > `Risk.authorize/2` の `check_available_balance/2` は `BalanceCache.get/2` で残高マップを読んで比較するだけ（risk.ex L367-382）。実際の減額は認可後、`OrderExecutor.reserve_balance/3` の `BalanceCache.reserve/4` で行う（order_executor.ex L342-362）。この 2 つの間に別の発注が `reserve` を通すと、authorize の時点で見た `available` は古くなる。
  >
  > 実害は限定的である。`reserve` 自体は GenServer 内で原子的に不足を弾き、`{:error, :insufficient_balance, meta}` を `:limit_exceeded` に写して返す（order_executor.ex L360-361）。つまり「通ってしまう」のではなく「認可は通ったが予約で落ちる」だけで、資金は守られる。ただし Runner から見ると `:limit_exceeded / :insufficient_balance` は再試行対象（runner.ex L36-40）なので、混雑時に認可→予約失敗→再試行のループが回り、その間 `OrderRate` は `record` されないまま `AuthorizedOrder` を消費し続ける。検査と予約が同じ場所にない設計上のねじれが残っている。
  > 改善方針: `authorize` の残高検査を「予約可能かの事前確認」と割り切って軽くし（現状どおり）、`reserve` 失敗を Runner の terminal 側に寄せるか、`BalanceCache.reserve/4` に `dry_run: true` モードを足して authorize から同じコードパスを呼ぶ。少なくとも「認可の残高判定は近似であり正本は reserve」という設計意図を `Risk` の moduledoc に書く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **`FailureRate` だけ再起動復元が無く、連続障害サーキットがクラッシュループで空振りする** `-1`
  > `OrderRate` は前回指摘を受けて `init/1` で DB から直近 1 分の Order を温める仕組みを入れた（order_rate.ex L100-115、失敗時は unsynced で fail-closed）。同型で作られた `FailureRate` にはそれが無く、moduledoc も現状を追認している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/failure_rate.ex L10-11
  > - カウンタはプロセス内 ETS のみ。再起動で消える（`OrderRate` 同型）。
  >   `:auth_failed` は都度即 halt なので鍵違いは再発で再度止まる
  > ```
  >
  > 401/403 は 1 回で halt するので鍵違いは確かに守られる。守られないのは「取引所が断続的に 4xx を返す」「レート制限に触れ続ける」ケースで、`max_exchange_errors_per_window: 5` に達する前にプロセスが再起動すればカウンタは 0 に戻る。`Risk.open_circuit` は Supervisor の再起動をまたいで RiskState に残るが、**カウンタが 5 に届かないと open_circuit がそもそも呼ばれない**。上で挙げた REST 過剰呼び出しと組み合わさると、429 を撃ち続けながら halt に到達しない周回が起こりうる。
  > 改善方針: `Order` の `status: :rejected` を直近窓で数えて `init/1` で温める（`OrderRate.warm_from_db/1` とほぼ同じコードで済む）。あるいは連続エラーの発生を `RiskState` の補助カラムに書き、再起動時に読み戻す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`

### datastore / Ash

- **`BalanceCache.load_latest/1` が `BalanceSnapshot` を全件読み込む（append-only なのに `limit` が無い）** `-2`
  > 残高キャッシュの再構築は次のクエリで行う。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/balance_cache.ex L669-680
  > defp load_latest(trade_mode) do
  >   case BalanceSnapshot
  >        |> Ash.Query.filter(trade_mode == ^trade_mode)
  >        |> Ash.Query.sort(captured_at: :desc, id: :desc)
  >        |> Ash.read() do
  >     {:ok, rows} ->
  >       balances =
  >         rows
  >         |> Enum.reduce(%{}, fn row, acc ->
  >           Map.put_new(acc, row.currency, row.available || row.amount)
  >         end)
  > ```
  >
  > `limit` も `distinct` も無い。`BalanceSnapshot` は `Balances.apply_fill/2` が paper 約定ごとに通貨 2 行を **append** する設計（balances.ex L52-70、コメントにも append-only と明記）なので、行数は約定回数に比例して無限に増える。この関数は `BalanceCache.refresh/2` 経由で **突合のたび**（`Reconciler` の `interval_ms: 60_000`、reconciler.ex L260-283）と、paper の各約定後（`BalanceCacheSync.around_fill`）に呼ばれる。
  >
  > 同じモジュール内の `Balances.latest_amount/2` はきちんと `Ash.Query.limit(1)` を付けており（balances.ex L84-93）、`Reconcile.read_latest_balances/1` は `DISTINCT ON` を使っている（reconcile.ex L605-618）。**3 つある「最新残高を取る」実装のうち 1 つだけが全件読み**になっている。24/365 で回すシステムで毎分の全表スキャン＋全行ソートが積み上がるのは、Vision の「長時間稼働しても」に直接反する。
  > 改善方針: `Reconcile.read_latest_balances/1` と同じ `DISTINCT ON`（または通貨リストを回して `limit(1)`）に置き換える。通貨数は 2〜3 なので後者でも十分速い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **永続データの保持・剪定方針がどこにも無い** `-1`
  > `fills` / `balance_snapshots` / `orders` / `strategy_parameter_revisions` はいずれも append-only で、削除・アーカイブ・パーティションのどれも実装されていない。`prune` / `retention` / `delete_all` をリポジトリ全体で探しても、当たるのは ETS の窓剪定（`OrderRate.prune/4`、`FailureRate.prune/4`、`AuthorizedOrder.purge_expired/3`）だけである。運用文書側も `bin/backup-db.sh` による dump はあるが、保持期間の定義が無い。
  >
  > 512 GB のストレージ（vision.md L118）で当面破綻はしないが、`Risk.DailyLoss` は当日分を毎回 Fill から再集計し（daily_loss.ex L380-396）、`Runner.load_submitted_ids/0` は 7 日分の Order を読む（runner.ex L416-434）。テーブルが育つほどこれらが遅くなる。「消えても再構築できる ETS」と「無限に育つ DB」の非対称が設計上どう扱われるのかが文書にもコードにも書かれていない。
  > 改善方針: `prod.md` に保持期間（例: fills 2 年、balance_snapshots 90 日で日次 1 行へロールアップ）を明記し、`mix bitflyer.compact` 相当を用意する。少なくとも「当面は剪定しない。閾値はこれ」という判断を文書に残す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/*.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **`Fill` が `Order` を文字列でしか参照しておらず、参照整合性が DB で保証されない** `-1`
  > `Fill.internal_order_id` は単なる `:string` で（fill.ex L44-47）、`Order` への `belongs_to` も外部キー制約も無い。マイグレーションも `add(:internal_order_id, :text, null: false)` とインデックスのみ（20260910010000_add_fills.exs L11, L33）。`Order.internal_order_id` 側には unique があるので参照先は一意に決まるはずだが、それを DB に教えていないので、注文が消えた Fill（孤児）を作れてしまう。
  >
  > 実際に同一トランザクションで書いているので現時点で孤児は生まれない（positions.ex L26-28 の `insert_fill` は `Positions.apply_fill/2` の内側で、その外側は `Bitflyer.Repo.transaction`）。ただし `Fill` は日次損失サーキットの正本であり、監査証跡でもある。「正本」と位置づけたテーブルの整合性をアプリロジックだけに委ねているのは、この実装の他の部分（`pg_advisory_xact_lock`、`FOR UPDATE`、unique 制約による冪等性）で見せている厳密さと比べて弱い。
  > 改善方針: `Fill` に `order_id` の `belongs_to`（`Order.id` 参照、`on_delete: :restrict`）を足す。`internal_order_id` は検索用に残してよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`

### market-data

- **ticker 一本のままで、板・約定ストリームが無い** `-1`
  > 前回から状況は改善したが解消はしていない。`Normalize` が取り出すのは `ltp` と `source_timestamp` の 2 つだけで（normalize.ex L11-14）、購読チャネルも `lightning_ticker_*` のみ（feed.ex L236 の `MarketData.ticker_channel/1`）。README L182-188 の表も `lightning_board_*` / `lightning_executions_*` を「—」としており、現状認識は正確である。
  >
  > 前回 `-2` としたのは paper の約定モデルが本番と乖離していたためだが、`FillPricing` の導入で成行 LTP±(slip+fee)・指値 fee のみという不利化が入り（fill_pricing.ex L27-49）、しかも `Risk.balance_hold/2` が paper 買いの拘束額を同じ不利化後価格で計算する（risk.ex L467-473）ところまで詰めてある。楽観バイアスは大きく減った。残る乖離は「常に全量即時約定する」ことで、`Paper.decide_fill/3` は成行も交差済み指値も一括で `{:fill, price}` を返す（paper.ex L78-99）。板の厚みを見ていない以上、大口注文の部分約定・不成立を paper で再現できない。`max_order_size` が 1 BTC 想定なら実害は小さいので `-1` に留める。
  > 改善方針: まず `lightning_executions_*` を購読して直近約定列を `Cache` に持ち、paper の約定サイズをその出来高で頭打ちにする（板より実装が軽い）。板は後続でよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **常時接続の中核が更新の止まった依存（`websockex` 0.4）に載ったまま** `-1`
  > 前回指摘から未解決。`apps/bitflyer/mix.exs` L38 の `{:websockex, "~> 0.4"}` は変わっていない。`websockex` の最終リリースは 2019 年の 0.4.3 で、OTP 27 の TLS 既定変更や `:ssl` API 追随は保証されていない。`mix deps.audit` は Hex advisory しか見ないため（今回の実行も `No vulnerabilities found.`）、「メンテされていない」ことは CI に一切現れない。
  >
  > 救いは差し替え可能性が確保されていることで、`Bitflyer.MarketData.Socket.Client` behaviour（socket/client.ex）とテスト実装 `Socket.Local`（socket/local.ex）があるため、移行しても `Feed` のテスト 287 行は無改修で通る。今回 stall watchdog が入って「無言接続」からは自力復帰できるようになったので、単一障害点としての深刻さは下がった。
  > 改善方針: behaviour の実装を `Mint.WebSocket`（+ 自前 GenServer）または `Fresh` へ差し替える。当面移行しないなら、依存の保守状況を `ci-cd.md` の「非保証」欄に明記して既知のリスクとして固定する。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`

### 保守性

- **`Reconcile.read_latest_balances/1` だけが生 Ecto + 全例外 `rescue` で、理由が 1 行も書かれていない** `-1`
  > **3 回連続で未解決**。コードは前回評価時から 1 文字も変わっていない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L605-618
  > defp read_latest_balances(trade_mode) do
  >   import Ecto.Query
  >
  >   query =
  >     from(b in BalanceSnapshot,
  >       where: b.trade_mode == ^trade_mode,
  >       distinct: b.currency,
  >       order_by: [asc: b.currency, desc: b.captured_at]
  >     )
  >
  >   {:ok, Bitflyer.Repo.all(query)}
  > rescue
  >   error -> {:error, error}
  > end
  > ```
  >
  > 同じモジュールの `read_risk_state/0`（L587-594）、`read_positions/1`（L596-603）、`read_open_orders/1`（L620-628）はすべて `Ash.Query` 経由で `{:ok, _} | {:error, _}` を返す。`DISTINCT ON` が Ash で書きにくいという事情は理解できるが、**そう書いていないので次に読む人には判断できない**。このモジュールは他の箇所（net 正規化の L315-317、hedged 平均比較の L426-428、残高 baseline の L472-474）で判断理由を丁寧に残しているだけに、ここだけ浮いている。関数節 `rescue` が全例外を捕まえる点も、`ArgumentError` のようなプログラミングエラーまで `restore_failed` に化けるという意味で他の読み出しと粒度が揃っていない。
  > 改善方針: 「なぜ Ash ではなく Ecto か」を 1 行コメントで残す。`rescue` は `Postgrex.Error` / `DBConnection.ConnectionError` に絞る。1 行で片付く指摘が 3 回残っているのは、レビュー漏れというより「小さすぎて優先度リストに乗らない」問題なので、improvement-plan の P3 に明示的に載せるほうがよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

---

## 技術評価層 — apps/ui

- **未約定滞留・日次損益・不整合の中身が画面に無い** `-1`
  > 前回から kill switch / resume / reconcile_now が入り（status_live.ex L172-228）、運用操作の面では大きく前進した。ここは加点している。残るのは表示側で、`prod.md` が「最低限、次を見る」とした項目のうち画面に出ているのは Feed 接続・データ鮮度・DB・モード・readiness である。
  >
  > 欠けているのは 3 つ。(1) **未約定注文の滞留** — `Order` の `pending` / `partially_filled` 件数と最古の経過時間。live で `submission_unknown` が発生したかどうかも画面から分からない。(2) **日次損益とリミット接近** — `DailyLoss` の ETS には当日損失が入っており `Risk.Limits.current/0` に上限もあるのに、両方とも画面に出ていない。日次損失サーキットが今回実効化されただけに、「あと何円で止まるか」が見えないのはもったいない。(3) **不整合の中身** — halt 理由は `reason_label/1`（L472-474）が atom 名を出すだけで、`reconcile_mismatch` の `kind` / `currency` / `product_code` は出ない。`OperationalStatus.snapshot/1` の型定義（operational_status.ex L39-48）にもこれらのフィールドが無い。
  > 改善方針: `OperationalStatus.snapshot/1` に `open_orders`（件数・最古経過秒・`submission_unknown` 件数）、`daily_loss`（当日損失・上限・比率）、`halt_detail`（直近 `RiskState` のメタ）を足し、UI は描くだけにする（現在のロジックレス方針は維持する）。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **`mix precommit` に Ash マイグレーションのドリフト検査が無い** `-1`
  > 前回指摘から未解決。品質ゲートは 4 本のままである。
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
  > `mix ash.codegen --check` が無いので、Resource の attribute を変えてマイグレーションを作り忘れても CI は緑のまま通る（テスト DB は既存マイグレーションから作られるため）。気付くのは本番で `migrate` を回したときか、カラムが無くて落ちたときになる。今回のサイクルで `Fill` / `BaselineImport` / `StrategyParameterRevision` の 3 Resource が追加され、マイグレーションも手書きで足されている（`20260910010000` / `20260910110000` / `20260910140000`）ぶん、ドリフトを踏む確率は前回より上がっている。CI 側にも同等の検査は無い（ci.yml は `ash.setup` してから `precommit` するだけ）。
  > 改善方針: `precommit` の `compile` の後に `"ash.codegen --check --domains Bitflyer.Trading"` を足す。resource snapshot は既にコミットされているので追加コストはほぼゼロで、1 行で塞げる。
  > 対象ファイル: `mix.exs`

- **開発コンテナが root で実行される** `-1`
  > 前回指摘から未解決。開発用 `Dockerfile` に `USER` 指定が無いため（Dockerfile 全 20 行、`RUN mix local.hex` のあと `WORKDIR /app` → `CMD` で終わる）、bind mount した `/app` 配下に root 所有のファイルが作られる。`_build` / `deps` は名前付きボリュームに逃がしてあるが（compose.yaml L32-34）、`priv/static/assets` のようにホスト側に落ちる生成物は root 所有になる。
  >
  > `Dockerfile.prod` は `groupadd --gid 1000 app` / `useradd --uid 1000` で非 root 化し `--chown=app:app` まで付けている（Dockerfile.prod L55-66）ので、方針そのものは理解されている。開発側だけが取り残されており、WSL2 のホストで所有者が食い違う日常的な摩擦になる。
  > 改善方針: 開発 `Dockerfile` にも uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる。
  > 対象ファイル: `Dockerfile`

---

## 横断評価層

### テスト戦略

- **`test_helper.exs` に Sandbox のモード指定が無い** `-1`
  > **3 回連続で未解決**。`apps/bitflyer/test/test_helper.exs` は `ExUnit.start()` の 1 行のみで、`apps/ui/test/test_helper.exs` も同じ。`Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` が呼ばれていない。
  >
  > 現在は DB を触るテストがすべて `Bitflyer.DataCase` / `UiWeb.ConnCase` 経由で `start_owner!/2` するため実害は出ていない（今回の実行でも 352 + 35 テストが 0 failures）。ただし明示が無いぶん、`use` を書き忘れたテストが 1 本入った時点でテスト DB に実データが残り、しかも他テストの `read_one` が壊れて初めて気付く形になる。テストが 200 本から 387 本に増えたぶん、この事故が起きたときの原因特定コストも上がっている。1 行で「checkout していないプロセスは DB に触れない」が保証できる。
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加する。
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`

- **取引所 API の契約テストが自作 fixture だけで、実応答との突き合わせ記録が無い** `-1`
  > 前回指摘から未解決。`Bitflyer.Exchange.Rest` は `:http_client` を差し替えられる良い設計で、`rest_test.exs`（307 行）も `decode_test.exs`（107 行）もある。しかし fixture はすべて手書きで、bitFlyer の実応答から採取したものではない。
  >
  > `Decode` が読むキーは `child_order_acceptance_id` / `executed_size` / `average_price` / `currency_code` / `exec_date` / `child_order_date` と実 API 依存が濃い（decode.ex L93-232）。今回 strict 化されたことで「キー名が変わって静かに 0 が入る」経路は塞がれ、欠落は `:skip`、不正数値は `{:error, :invalid_number}` になった（この改善は加点している）。しかし**識別子キーの改名は `:skip` に落ちる**（例: `child_order_acceptance_id` が変われば `open_order/1` は L148 で `:skip`）ので、突合が「取引所に未約定注文なし」と誤認する経路は残る。`getchildorders` の全行が `:skip` になれば `compare_open_orders/2` は内部側だけを見て `open_order_missing_exchange` で halt するので fail-closed ではあるが、原因が「API 仕様変更」だと分かる材料がログに出ない。
  > 改善方針: public API（`/v1/ticker` 等）と匿名化した private 応答を `test/fixtures/bitflyer/YYYY-MM-DD/` に採取し、`Decode` のテストをそのファイルから読む形にする。採取手順を `ci-cd.md` に書く。あわせて「行が 1 つも decode できなかった」ケースを `:skip` と区別してログに出す。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/exchange/rest_test.exs`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

### ドキュメント

- **`apps/bitflyer/README.md` が生成テンプレのまま残っている** `-1`
  > リポジトリ全体で `TODO` / `FIXME` を検索して当たるのはこの 1 箇所だけである。
  >
  > ```
  > apps/bitflyer/README.md L3
  > **TODO: Add description**
  > ```
  >
  > 単体では些細だが、P3 #19 で「残骸棚卸し」として `Heartbeat` / `PageController` / `Mailer` / `swoosh` / Phoenix マーケティングリンクを一掃したサイクルの直後に、umbrella の中核アプリの README だけが手つかずで残っているのは棚卸しの網羅性の問題である。ルート `README.md` が 227 行で丁寧に書かれているだけに落差が目立つ。`apps/ui/README.md` の有無も含めて揃えるべきである。
  > 改善方針: `apps/bitflyer/README.md` にアプリの責務（取引所連携・ドメイン・エンジンの正本、論理コンポーネントの配置、ルート README と overview.md へのリンク）を 10 行程度で書く。不要なら削除する。
  > 対象ファイル: `apps/bitflyer/README.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| 技術評価層 — apps/bitflyer（risk-manager） | -5 |
| 技術評価層 — apps/bitflyer（order-executor） | -6 |
| 技術評価層 — apps/bitflyer（datastore / Ash） | -4 |
| 技術評価層 — apps/bitflyer（market-data） | -2 |
| 技術評価層 — apps/bitflyer（保守性） | -1 |
| 技術評価層 — apps/ui | -1 |
| 技術評価層 — 実行基盤 / 設定 | -2 |
| 横断評価層（テスト戦略） | -2 |
| 横断評価層（ドキュメント） | -1 |
| **合計** | **-24** |

---

## 前回マイナス点の解決状況（コード再読で確認）

| 前回の指摘 | 前回 | 状況 | 根拠 |
|:---|:---:|:---|:---|
| `max_daily_loss` が本番経路で発火しない | -4 | **解決** | `Risk.resolve_daily_loss/1`（risk.ex L530-568）が `DailyLoss.get/2` を既定にし、`Fill.realized_pnl` を正本に再集計（daily_loss.ex L380-396） |
| 残高検査が `:balances` 未注入でスキップ | -2 | **解決** | `resolve_balances/2` が `BalanceCache.get/2` を既定に（risk.ex L577-594）。未同期は `:unsynced` で fail-closed |
| 連続障害・署名エラーでサーキットが開かない | -2 | **解決** | `FailureRate.evaluate/2` で 401/403 即 halt・窓内 N 回で `:consecutive_exchange_errors`（live.ex L200-213） |
| 時計ずれを拒否理由にできない | -1 | **解決** | `Risk.check_clock_skew/3` + `check_source_timestamp/3`（risk.ex L205-247）、live 起動突合でも検査（reconcile.ex L181-228） |
| `OrderRate` が再起動でゼロに戻る | -1 | **解決** | `init/1` で DB warm、壁時計→monotonic 写像、失敗時 unsynced（order_rate.ex L100-115, L163-186） |
| `submission_unknown` から回復する手段が無い | -2 | **解決** | `SubmissionRecovery`（403 行、承認 + hash 一致 + 曖昧時 ID 指定 + `--absent`）と `mix bitflyer.recover` |
| 確定拒否が本文の部分一致に依存 | -1 | **解決** | `map_error/2` が status 優先（401/403→`:auth_failed`、429→`:rate_limited`）（decode.ex L257-263） |
| WS サイレントストール watchdog が無い | -2 | **解決** | `arm_stall_watchdog/1` + `{:stall_watchdog, ref}`（feed.ex L164-177, L376-393） |
| ticker 一本で paper の約定モデルが乖離 | -2 | **部分解決** | `FillPricing` で不利化。板・約定ストリームは未購読 → `-1` に縮小 |
| `websockex` 0.4 依存 | -1 | **未解決** | mix.exs L38 変更なし |
| 約定明細が永続化されない | -1 | **解決** | `Bitflyer.Trading.Fill` + 同一トランザクション書込（positions.ex L160-179） |
| 戦略パラメータ履歴 Resource が無い | -1 | **解決** | `StrategyParameterRevision` + `Revision.ensure_current/1` + Order 由来 3 属性 |
| `Heartbeat` の残骸 | -1 | **解決** | 削除済み。`ash_domains: [Bitflyer.Trading]`（config.exs L6）、`drop_heartbeats` マイグレーションあり |
| 停止理由が `risk_halted` に丸められる | -1 | **解決** | `Risk.HaltReason` を正本化（12 理由 allowlist + `to_existing_atom` + rescue） |
| StatusLive に滞留・損益・不整合が無い | -1 | **未解決** | 上記のとおり（kill switch は追加済み） |
| Phoenix 生成テンプレ残骸 | -1 | **解決** | `Layouts.app/1` はアプリ名 + テーマ切替のみ（layouts.ex L36-58）。`PageController` / `Mailer` / `swoosh` 削除済み |
| 本番に telemetry の集計先が無い | -2 | **解決** | prod 既定 `ConsoleReporter`（ui/telemetry.ex L34-40）+ BasicAuth 配下 `/ops/dashboard`（router.ex L44-57） |
| `precommit` に `ash.codegen --check` が無い | -1 | **未解決** | mix.exs L47-53 変更なし |
| `Dockerfile.prod` が CI で検証されない | -1 | **解決** | ci.yml に `docker-prod` ジョブ（`push: false`、`cache-from: type=gha`） |
| 開発コンテナが root | -1 | **未解決** | Dockerfile に `USER` なし |
| `test_helper.exs` に Sandbox mode が無い | -1 | **未解決** | 1 行のまま |
| 取引所 API の契約テストが手書き fixture のみ | -1 | **未解決** | `test/fixtures/` は存在しない |
| `read_latest_balances` の生 Ecto + 広い rescue | -1 | **未解決** | 1 文字も変わっていない |
| README が risk-manager を過大申告 | -1 | **解決** | `partial` + 「含み損は未計上」まで明記（README L28） |

**解決 15 件 / 部分解決 1 件 / 未解決 7 件。** 未解決 7 件のうち 6 件は `-1` の軽微な項目で、うち 3 件（Sandbox mode、`read_latest_balances`、開発 Dockerfile の root）は 3 回連続で残っている。これらは「重要度が低い」というより「improvement-plan に載らないサイズの指摘が拾われない」という運用上の穴を示している。
