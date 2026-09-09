# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-10

対象コミット: `490fb5a`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/prod.md](../../architecture/env/prod.md) / [ci-cd.md](../../architecture/ci-cd.md)
前回（自系統）: [opus/archive/2026-09-09](./archive/2026-09-09/opus-specific-strengths-2026-09-09.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +148 点**

---

## 技術評価層 — apps/bitflyer

### order-executor（資金保全の中核）

- **`submission_unknown` — 「受注したか分からない」を第一級の状態として持つ** `+5`
  > 取引所への `place_order` が `timeout` / `disconnected` / `closed` で失敗したとき、これを `rejected` にしない。専用の状態へ落とし、サーキットを開いて再送を止める。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live.ex L130-148
  > defp handle_place_error(%Order{} = order, reason) do
  >   if definite_rejection?(reason) do
  >     _ = update_status(order, :rejected, reason)
  >     {:error, :exchange_error, %{reason: reason}}
  >   else
  >     # timeout / 切断等: 受注不明。rejected にせず halt して再送を止める
  >     _ = update_status(order, :submission_unknown, reason)
  >     _ = open_circuit_or_log!(:submission_unknown, %{...})
  >     {:error, :submission_unknown, %{reason: reason}}
  >   end
  > end
  > ```
  >
  > 状態は Resource の制約にも入っており（order.ex L85-87 `:submission_unknown` にコメント付き）、ログレベルも `:critical` に分けている（live.ex L189）。何より、この分類が **`Bitflyer.Exchange.Client` の moduledoc にエラー契約として明文化されている**（client.ex L14-23）ため、将来のクライアント実装者が「どのエラーを確定拒否にしてよいか」を推測しなくて済む。取引所がクライアント側注文 ID を受け付けない bitFlyer において、二重発注を構造的に防ぐ唯一の正解に近い。個人プロジェクトでここまで踏み込んだ実装はほとんど見ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **受注後の `exchange_order_id` 永続化失敗を「最悪の状態」として扱う** `+4`
  > 取引所は受け付けたのに内部に ID が残らない、という照合不能状態を明示的に検出し、`:critical` ログ + サーキット開 + `{:error, :persist_failed, ...}` に倒す。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live.ex L53-76
  > {:error, error} ->
  >   # 取引所では受注済みなのに ID を見失うと照合不能になる。
  >   # 再送・追加発注を止め、起動突合で回収するまで Ready にしない。
  >   Bitflyer.Telemetry.log(:critical, "Failed to persist exchange_order_id ...", ...)
  >   _ = open_circuit_or_log!(:persist_failed, %{...})
  > ```
  >
  > さらに `open_circuit_or_log!/2` は「`Circuit.open` は常に先に `Readiness.halt` する。`{:error, _}` は RiskState 永続化失敗のみ」とコメントし、永続化まで失敗した場合に「稼働中は閉じているが再起動で halt が消える」危険を `:critical` として残している（live.ex L150-173）。二段目の失敗まで設計されている点が良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **冪等キーと DB 一意制約の競合を「既存行を返す」で解決している** `+3`
  > `internal_order_id` は `Order` の identity（order.ex L134-136）で、`submit/2` は事前 lookup で `{:idempotent, order}` を返す。それに加えて、事前 lookup をすり抜けた同時実行に対しても安全側に倒す。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor.ex L208-213
  > {:error, error} ->
  >   # 競合時は既存行を返す（二重 REST を防ぐ）
  >   case fetch_order(attrs.internal_order_id) do
  >     {:ok, %Order{} = order} -> {:idempotent, order}
  >     _ -> {:error, :persist_failed, %{error: error}}
  >   end
  > ```
  >
  > 「DB の一意制約を最後の砦にし、違反したら REST を撃たずに既存を返す」は、冪等な発注を実装するうえで最も堅い形。Vision の Idempotent actions がテストではなく制約で担保されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **取消は注文自身の `trade_mode` に固定し、halt 中でも許可する** `+3`
  > 2 つの判断がどちらも正しい。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor.ex L83-85
  > def cancel(%Order{} = order, opts) do
  >   # opts の :trade_mode は無視。live 注文を dry_run 取消にして取引所に残骸を残さない。
  >   trade_mode = order.trade_mode
  > ```
  >
  > `live/cancel.ex` L17-18 は「発注ゲートが閉じていてもエクスポージャ削減のため REST 取消は許可する」と明記する。halt したら**すべて**止める、という素朴な実装だと「止まった瞬間に建玉を畳めなくなる」ので、新規発注と取消を非対称に扱うのは取引システムとして正しい設計判断。さらに取消成功後に即 `cancelled` へ落とさず、fill 同期を挟んでから終端化する（cancel.ex L63-84）ことで、取消レース中の部分約定を取りこぼさない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`

- **live は risk 認可の「前」に約定を同期する** `+3`
  > `submit/2` の `with` は `validate_command` → `maybe_sync_live_fills` → `Risk.authorize` の順（order_executor.ex L47-49）。同期に失敗したら `{:error, :fill_sync_failed, ...}` で発注しない（L109-117）。これが無いと、`Risk.check_position_size/3` が DB の古い `Position` を見て建玉上限をすり抜ける。順序を「認可 → 同期」ではなく「同期 → 認可」にしてある理由が moduledoc にも書かれている（L32）。地味だが、建玉リミットを実効化するうえで決定的。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **paper の擬似約定が注文・建玉・残高を単一トランザクションで更新する** `+3`
  > `Paper.apply_fill_transaction/2` は `Repo.transaction` の中で `mark_filled` → `Positions.apply_fill` → `Balances.apply_fill` を回し、いずれかが失敗すれば全部ロールバックする（paper.ex L29-43）。さらに Ash の通知を `return_notifications?: true` で受け取り、**コミット後に** `Ash.Notifier.notify/1` する（L44-45）。トランザクション内で通知を飛ばして「ロールバックしたのに通知は出た」を作らないという配慮まで入っている。`LiveFills.apply_fill_transaction/4` も同じ形（live_fills.ex L228-242）で、片側だけ成功する状態を構造的に排除している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **残高 append を PostgreSQL の advisory lock で直列化し、デッドロックまで回避している** `+4`
  > append-only の残高スナップショットで Lost Update を防ぐために `pg_advisory_xact_lock` を使う。しかもロック取得順を通貨コード昇順に固定して、buy/sell 同時のデッドロックを避ける。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/balances.ex L36-41
  >   |> Enum.sort_by(fn {currency, _delta} -> currency end)
  > ```
  >
  > moduledoc（L11-25）は「先端行の `FOR UPDATE` だけでは新 tip 挿入後も古い額から append され得る／初回行なし時も競合する」と、なぜ行ロックでは足りないのかまで説明している。この粒度の並行性設計と、その理由がコードに残っていることは、同規模のプロジェクトではまず見ない。`Positions.apply_fill/2` 側も `Ash.Query.lock(:for_update)` + unique 衝突時の再読マージ（positions.ex L34-64）で揃えている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **`LiveFills` が「取引所の一覧に無い注文」を約定履歴から回収する** `+3`
  > `getchildorders` に出ない注文（未約定取消・窓外）を諦めず、`fetch_executions` で約定を確認してから終端化する（live_fills.ex L82-145）。約定があれば載せ、なければ `cancelled` に落とす。照会自体に失敗したら「黙って open のままにしない」で `{:error, :exchange_error, %{cause: :order_not_found_recovery_failed}}` を返す（L136-144）。「取引所に見えなくなった＝無かったことにする」という一番危ない近道を取っていない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

### risk-manager

- **8 段の検査列がすべて fail-closed で、読めないものを空とみなさない** `+4`
  > 検査順は「コマンド妥当性 → 同期 → 鮮度 → 注文サイズ → 建玉 → 価格逸脱 → 発注頻度 → 日次損失 → 残高」（risk.ex L52-61）。特筆すべきは、各検査の**失敗時の倒し方**が一貫して安全側であること。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L191-194
  >   {:error, _error} ->
  >     # 建玉が読めないときは空とみなさない（fail-closed）
  >     {:error, :unsynced, %{reason: :position_load_failed, product_code: product_code}}
  > ```
  >
  > 鮮度を通過した後でも LTP が欠けていれば `:stale` を返し（L226-229）、`extract_ltp/1` は非正の LTP を `nil` 扱いにする（L377-385）。発注頻度が読めなければ `:unsynced`。「読めなかった＝制限なし」という古典的な事故が、どの検査にも無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **発注ホットパスから DB 往復を外す設計判断が明示されている** `+3`
  > `Readiness` は ETS 直読（readiness.ex L41-43）、発注頻度は `Risk.OrderRate` の ETS（order_rate.ex）。`check_sync/1` にはなぜ既定で RiskState を読まないのかが書かれている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L126-131
  >   # 実行時の正本は Readiness（ETS）。サーキット開は先に halt する設計のため
  >   # 既定では RiskState を読まない（発注ホットパスの DB 往復を避ける）。
  >   if Keyword.get(opts, :check_persisted_circuit, false) and ...
  > ```
  >
  > しかも「読まなくてよい」理由が `Circuit.open/2` の実装順序（メモリ先 → 永続後）と結び付いており、性能最適化が安全性の前提とセットで説明されている。overview.md L96 の「ホットパスから Resource を呼ばない」を、方針で終わらせず個別の判断に落とし込んでいる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/readiness.ex`, `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`

- **サーキットの開閉順序が非対称に設計されている** `+3`
  > 開くときはメモリ（`Readiness.halt`）が先、永続（RiskState）が後。閉じるときは永続の解除が先、`Readiness.clear_halt` が後（circuit.ex L36-88）。どちらも「途中で落ちても発注が開かない」向きに倒れる。加えて `persisted_halted?/0` は読み取り失敗を `true` に倒す（L98）。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/circuit.ex L95-99
  >   {:ok, %RiskState{halted: true}} -> true
  >   {:ok, _} -> false
  >   {:error, _error} -> true
  > ```
  >
  > 「順序が安全性の証明になっている」タイプの実装で、コメントにもその意図が残っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

- **`authorize?: false` のような迂回口が公開 API から消え、回帰テストで固定されている** `+3`
  > `lib/` 配下に `authorize?: false` の一致は 0 件。`OrderExecutor.submit/2` の moduledoc は「risk 認可は常に必須。公開 API からスキップできない」と宣言し（order_executor.ex L40）、`with` の 3 番目に `Risk.authorize` が固定で入る。しかも `order_executor_test.exs` L548 と `capital_preservation_test.exs` L363 の 2 箇所で「`authorize?: false` を渡しても迂回できない」ことをテストしている。**削除して終わりではなく、復活を検知するテストを残した**点が良い。前回の指摘（`-3`）に対する模範的な閉じ方。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

### 起動突合 / Readiness

- **live の残高 baseline を必須通貨で強制し、空リストで成功にしない** `+4`
  > 前回「内部が空だと `compare_balances/2` が必ず `:ok` を返す」と指摘した穴が、明示的な baseline チェックで塞がれている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L272-280
  > defp ensure_balance_baseline(internal_map, required) when is_list(required) do
  >   case Enum.find(required, fn currency -> not Map.has_key?(internal_map, currency) end) do
  >     nil -> :ok
  >     currency ->
  >       {:error, :reconcile_mismatch, %{kind: :balance_baseline_missing, currency: currency}}
  >   end
  > end
  > ```
  >
  > 必須通貨は `config/config.exs` L23 で `["JPY", "BTC"]`、上書きは `:required_balance_currencies` で可能。「追跡中の通貨だけ突合する（取引所側のダスト通貨で誤停止しない）」という元の意図を保ったまま、空集合だけを別扱いにする最小の修正になっている。テスト実行ログにも `kind=balance_baseline_missing currency=JPY [warning] boot reconcile halted` が出ており、動作も確認できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `config/config.exs`

- **突合をモード別に分け、live だけ取引所を正とする** `+2`
  > `reconcile_mode/3` は `dry_run` / `paper` を「内部仮想状態が正。取引所とは突合せず、建玉も書き換えない」で早期 `:ok`（reconcile.ex L141-147）、`live` だけ fill 同期 → 再 restore → 取引所スナップショット取得 → 比較（L149-156）。overview.md L110 の仕様（「`paper` の起動突合は取引所の建玉ではなく、内部の仮想状態を正とする」）とコードが 1 対 1 で対応している。live では突合の直前に `restore(:live)` を撃ち直しており、fill 同期による変化を確実に取り込む点も丁寧。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **halted からの復帰入口を `Startup.Resume` 1 本に絞っている** `+3`
  > `Reconciler.apply_result/2` は突合が成功しても halted なら Ready に戻さない（reconciler.ex L104-107 「手動 clear_halt 待ち。自動では Ready に戻さない」）。復帰は `Resume.run/1` だけで、しかも `Circuit.open?` を先に確認し（resume.ex L25-29）、再突合が成功したときのみ `Circuit.close` → `mark_ready` の順に進む（L62-73）。`mix bitflyer.resume` は失敗時に終了コード 1 を返し、**別 BEAM で叩いた場合に常駐側 ETS が残る問題までタスクの moduledoc に書いてある**（bitflyer.resume.ex L9-11）。さらに release 用に `Bitflyer.Release.resume()` を rpc で叩く手順が prod.md L173-180 にあり、「`eval` は別プロセスになるため resume には使わない」まで明記されている。運用の落とし穴を先回りして潰している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/resume.ex`, `apps/bitflyer/lib/mix/tasks/bitflyer.resume.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **`Readiness` は書き込み GenServer / 読み取り ETS で、テーブル消失も `:not_ready` に倒す** `+4`
  > 状態遷移は `handle_call` に集約して不変条件（halted からは `mark_ready` できない、L169-170）を守り、読み取りは `:ets.lookup_element/3` の直読で発注ゲートがプロセス間通信に依存しない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/readiness.ex L243-247
  > defp ets_get(table) when is_atom(table) do
  >   :ets.lookup_element(table, :state, 2)
  > rescue
  >   ArgumentError -> :not_ready
  > end
  > ```
  >
  > 「正本は 1 つ、読みは速く、壊れたら閉じる」の 3 つが同時に満たされている。UI / executor / health / risk がすべてここを読む（`System.readiness/0`、`TradeMode.exchange_order_gate/0`、`Health.classify/2`、`Risk.check_sync/1`）ので、状態の分裂が起きない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`

### market-data

- **再接続と REST 穴埋めの競合を「開始時刻の比較」で正しく解いている** `+3`
  > gap-fill は Feed をブロックしないよう `Task.Supervisor` に逃がし、結果は Feed 経由で適用する。そのうえで、穴埋め開始後に届いた WS tick を古い REST 値で上書きしない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/feed.ex L258-266
  > defp maybe_apply_gap_fill(key, value, product_code, gap_fill_started_at) do
  >   case Cache.get(key) do
  >     {:ok, _current, received_at} when received_at >= gap_fill_started_at -> :ok
  >     _ -> put_tick(key, value, product_code, received_at: gap_fill_started_at)
  >   end
  > end
  > ```
  >
  > 加えて、mailbox に残った `:reconnect` が確立済み接続を落とさないようにするガード（L136-138）、`{:error, {:already_started, pid}}` で古い socket を捨てて張り直す処理（L171-176）、`trap_exit` + `Process.exit(pid, :shutdown)` によるリーク防止（L41, L185-188）と、非同期まわりの落とし穴が一通り塞がれている。指数バックオフも上限付き（L317-320）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **ETS 鮮度キャッシュが miss / 期限切れ / テーブル消失をすべて false に倒す** `+3`
  > `fresh?/3` は `get/2` が `:miss` なら false、`ets_lookup/2` は `ArgumentError` を `:miss` に落とす（cache.ex L162-169）。鮮度判定の核は ETS 非依存の純関数 `entry_fresh?/3`（L74-79）に切り出され、risk とテストの両方から再利用される。monotonic 時刻を使っているので、NTP による壁時計の跳びで「急に全部 stale」「急に全部 fresh」にならない。境界条件（`age <= max_age_ms` を fresh）も moduledoc に書いてある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

### strategy

- **`Strategy.Runner` が「再試行してよい失敗」と「もう出さない失敗」を明示的に分類している** `+4`
  > 縦貫通の骨として最小の戦略を入れただけでは終わらせず、再送制御をきちんと設計している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/strategy/runner.ex L24-37
  > @retryable_errors [:unsynced, :stale, :circuit_open, :persist_failed,
  >                    :strategy_submit_crashed, :strategy_submit_exit]
  > @retryable_limit_kinds [:max_orders_per_minute, :max_daily_loss, :insufficient_balance]
  > ```
  >
  > 一時的なもの（Ready 前、stale、頻度・残高による一時拒否）は再試行、`invalid_command` や恒久的なリミット超過は settled にして二度と出さない。**未知の理由は再試行側に倒す**（L272-274「誤って永続停止しない」）判断も、可用性と安全性の折り合いとして妥当。さらに、起動時は `Order` から submitted ID を復元するまで tick を無視し（L104-105）、ロード完了時刻より前に送られた tick を破棄する（L108-109）ことで、起動レースによる二重評価を防いでいる。戦略クラッシュは `rescue` / `catch :exit` で受け止め、取引経路を巻き込まない（L211-220, L317-335）。「アルゴリズムは 1 本でよいが、駆動役は本気で作る」という優先順位が正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **依存方向が Behaviour で強制されている** `+2`
  > `Bitflyer.Strategy` の moduledoc は「取引所 API・OrderExecutor は呼ばない（Runner が `System.submit_order/2` へ渡す）」と宣言し、`@callback evaluate(market(), [position()], params()) :: [command()]` は純粋な変換だけを許す（strategy.ex L9-20）。`FixedOnce` も実際に副作用ゼロの純関数（fixed_once.ex）。overview.md L154「strategy から API を直接叩かない」が、規約ではなく型で守られている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy.ex`, `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`

### 永続化 / 型

- **金額・数量が Decimal で統一され、不変条件が Resource 制約になっている** `+3`
  > `Order` の `price` / `size` / `filled_size` はすべて `:decimal`、`size` は `constraints greater_than: 0`、`filled_size` は `min: 0`（order.ex L98-113）。さらに validations で「limit なら price 必須」「market の pending は price 不可」「`filled_size <= size`」を宣言している（L125-132）。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/order.ex L125-132
  > validate present(:price), where: [attribute_equals(:order_type, :limit)]
  > # 成行は発注時 price なし。約定後は fill 価格を price に残してよい
  > validate absent(:price),
  >   where: [attribute_equals(:order_type, :market), attribute_equals(:status, :pending)]
  > validate compare(:filled_size, less_than_or_equal_to: :size)
  > ```
  >
  > 「約定後は market でも price を残す」という現実的な緩和まで含めて、DB 層で守れるものは DB 層で守っている。float は取引ドメインのどこにも無い（`Decode.to_decimal/1` は float を経由するが `float_to_binary(decimals: 10)` を挟んで文字列化してから Decimal 化する、decode.ex L11-13）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

### observe

- **telemetry メタデータの allowlist で秘密の漏洩経路を構造的に断つ** `+3`
  > `Bitflyer.Telemetry` は許可キーの `MapSet` を持ち、`execute/3` / `log/3` / `put_logger_metadata/1` のすべてが `sanitize_metadata/1` を通る（telemetry.ex L92, L101, L109）。文字列キーは `String.to_existing_atom/1` を `rescue` 付きで使い（L139-143）、**未知の文字列で atom を作らない**（メモリリーク対策）。moduledoc も「秘密キーを allowlist に入れないこと」と運用ルールを添えている。前回指摘した `:kind` / `:currency` / `:limit` の欠落も解消され（L52-54）、`config/config.exs` L136-138 の Logger メタデータとも揃っている。デフォルト拒否のホワイトリストは、この手の漏洩対策として最も堅い形。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `config/config.exs`

- **Discord アダプタが発注経路から完全に独立している** `+4`
  > 監督ツリー上は取引監督の兄弟で、`shutdown: 5_000` 指定（application.ex L27-28「発注経路の兄弟。通知失敗・クラッシュで取引木を巻き込まない」）。telemetry ハンドラは Application 起動時に静的 ID で **一度だけ** attach し（L37）、イベントは `GenServer.cast`（非同期）で渡す。送信は `try/rescue/catch` で二重に囲い（discord.ex L132-163, L170-178）、**失敗時も cooldown を進める**（L142「連打で GenServer を埋めない」）。Webhook URL は未設定なら黙ってスキップし、失敗ログにも URL を出さない。`content` は Discord の 2000 文字上限で切り詰める（L197-203）。`readiness.changed` と `reconcile.mismatch` の二重投稿も抑制する（L269-271）。「通知は落ちてもよいが、通知のせいで取引が落ちてはいけない」という要件に対して、考えうる失敗モードがほぼ網羅されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

### OTP / Application

- **`prep_stop/1` で発注ゲートを閉じ、Compose の猶予と子の shutdown が整合している** `+4`
  > SIGTERM で真っ先に発注を止める。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/application.ex L52-69
  > def prep_stop(state) do
  >   _ = Bitflyer.Observe.Discord.uninstall_telemetry()
  >   previous = try do Bitflyer.Readiness.get() catch :exit, _ -> :not_ready end
  >   Bitflyer.Telemetry.log(:info, "prep_stop: closing order gate", ...)
  >   _ = Bitflyer.Readiness.mark_not_ready_safe()
  >   state
  > end
  > ```
  >
  > `mark_not_ready_safe/1` は未起動・停止中を no-op にして `:noproc` で落ちない（readiness.ex L94-109）。数字も整合している。子 1 つあたり `@child_shutdown_ms 5_000`（application.ex L11、「Supervisor は子を直列停止する」というコメント付き）に対し、`compose.yaml` L30 と `compose.prod.yaml` L52 が `stop_grace_period: 45s`。overview.md L168 の要求（新規発注を止め、進行中の書き込みを終えてから終了する）をコードと Compose の両方で担保しており、しかも `application_shutdown_test.exs` で回帰も張ってある。ToDo の手順ではなくコードで守られている点が良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`, `compose.prod.yaml`

- **`/health/live` と `/health/ready` を分離し、Compose には liveness だけを見せる** `+3`
  > `Health` の moduledoc（health.ex L4-16）が 3 プローブの使い分けを明記し、`classify_ready/4` は Ready かつ Feed 接続かつ全銘柄鮮度のときだけ `:ready` を返す（L218-229）。Compose の healthcheck は `/health/live` を見る（compose.yaml L54、compose.prod.yaml L81）ので、**WS が切れてもコンテナは再起動しない**（Feed が自力で張り直す）。一方で外部監視は `/health/ready` で stale を 503 として拾える。「プロセス生存」と「仕事ができる状態」を混同しないのは運用の基本だが、その理由まで文書とコードの両方に書いてある例は少ない。公開 JSON に DB エラー本文を載せない配慮（L136-146）も入っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `compose.yaml`, `compose.prod.yaml`

### exchange

- **`Exchange.Client` behaviour がエラーの意味論まで契約に含めている** `+4`
  > 型（`snapshot` / `place_order_request` / `order_info` / `execution` 等）が全部書かれているだけでなく、moduledoc に「確定拒否 → `rejected`、halt しない」「提出不明 → `submission_unknown` + halt、再送しない」の分類が例示付きで載っている（client.ex L14-23）。behaviour が「呼べる関数」ではなく「守るべき安全性」を伝える文書になっている。テスト用スタブ（`ExchangeClientStubs`）と `Unavailable`、実装の `Rest` が同じ契約に並ぶので、live 経路の分岐がテストで固定できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`

- **署名付き REST が HTTP 層を差し替え可能にし、実ネットを前提にしない** `+3`
  > `Rest` は `:http_client`（既定 `Rest.HTTP`）へ委譲し（rest.ex L322-324）、`Auth.sign/5` は `timestamp <> METHOD <> path <> body` を HMAC-SHA256 で hex 化する純関数（auth.ex L12-21）。GET のクエリを署名対象パスに含める（rest.ex L251-253）という、bitFlyer で間違えやすい点も正しい。`Auth.headers/6` は「`api_key` / `api_secret` は返さない」と moduledoc に明記し、返すのはヘッダだけ。`Req` を使い `retry: false` を明示（http.ex L18, L29）しているのも重要で、**HTTP 層で勝手に再送されると `submission_unknown` の設計が壊れる**。ここを外していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/exchange/auth.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/http.ex`

- **既定は `Unavailable`、5xx は「不明」側へ倒す** `+2`
  > `config/config.exs` L7 の既定は `Bitflyer.Exchange.Unavailable` で、`runtime.exs` L151-153 が `trade_mode == :live` かつ `config_env() != :test` かつキーありのときだけ `Rest` を差し込む。三重条件で、テスト環境や dry_run から実 REST に届く経路が無い。`Rest.request/4` は 5xx を `:disconnected` にし、コメントで理由を残す（rest.ex L274-276「5xx は受注不明の可能性（POST 発注時）。呼び出し側が分類する」）。
  > 対象ファイル: `config/config.exs`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

---

## 技術評価層 — apps/ui

- **「今トレードしてよいか」が画面最上部の 1 バッジで分かる** `+3`
  > `StatusLive` の先頭セクションは `orders-gate` で、`ALLOWED` / `STOPPED` を成功色・エラー色で出し、停止時は `orders-gate-reason` に理由を表示する（status_live.ex L69-94）。`aria-live="polite"` まで付いている。前回「6 項目中 0 項目」と指摘した状態から、発注可否・Feed 接続・再購読/再接続回数・銘柄ごとの鮮度経過・halt 理由・DB が並ぶ画面になった。5 秒ポーリングで更新（L7, L314-316）。運用 UI に求められる最重要要件が満たされている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **判定を `OperationalStatus` に集約し、UI をロジックレスに保っている** `+3`
  > 「発注してよいか」の合成（readiness / live 解禁 / 鮮度 / Feed）は `Bitflyer.OperationalStatus.classify/4`（operational_status.ex L151-171）にあり、UI は返り値を描くだけ。`Feed.status/1` の呼び出しも `safe_feed_status/0` で `catch :exit` して `:unavailable` に正規化する（L176-182）ので、**Feed が落ちていても UI は落ちない**。overview.md L82「`ui` は Ash の公開インターフェース経由でのみ `bitflyer` に触る」の精神どおり、UI に判断を持たせていない。`ui` から bitFlyer API を直接叩く箇所も無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **BasicAuth が Plug と LiveView の 2 層で、`/health` 経由の匿名 session を弾く** `+4`
  > 単に `Plug.BasicAuth` を挟むだけで終わっていない。認証成功時に session `:ui_basic_ok` を立て（plugs/basic_auth.ex L31）、LiveView 側は `on_mount` でその session を確認する（hooks/basic_auth.ex L9-15）。
  >
  > ```elixir
  > # apps/ui/lib/ui_web/plugs/basic_auth.ex L7-9
  > # 成功時（または無効時）に session :ui_basic_ok を立て、LiveView Socket（/live）が
  > # router プラグを通らない場合でも UiWeb.Hooks.BasicAuth で弾けるようにする。
  > ```
  >
  > LiveView の WebSocket 接続が router pipeline を通らない、という Phoenix 特有の抜け道を理解したうえで塞いでいる。`/health*` は `:api` パイプラインで認証対象外（router.ex L21-29）、`runtime.exs` L188-197 は prod で資格情報が欠けていれば **起動を止める**。テストも `plugs/basic_auth_test.exs` と `hooks/basic_auth_test.exs` の両方にある。
  > 対象ファイル: `apps/ui/lib/ui_web/plugs/basic_auth.ex`, `apps/ui/lib/ui_web/hooks/basic_auth.ex`, `apps/ui/lib/ui_web/router.ex`, `config/runtime.exs`

- **取引モードが色で区別される** `+2`
  > `dry_run` は無彩色、`paper` は info、`live` は **error 色**（status_live.ex L285-292）。前回「`dry_run` と `live` が視覚的にまったく区別されない」と指摘した点が、カード枠・背景・文字色の 3 つで直っている。live であることが赤で目に入るのは、誤操作の抑止として実効的。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **`TRADE_MODE` を runtime で検証し、live には日付付き二重確認を要求する** `+4`
  > `runtime.exs` L80-98 は許可値以外を `raise` で止める。`live` でも `BITFLYER_LIVE_CONFIRM` が **UTC 当日の `YYYY-MM-DD` と一致**しなければ発注ゲートが開かない（L100-105 → `TradeMode.exchange_order_gate/0` L121-136）。「日付を書かせる」設計により、`.env` に置きっぱなしにしても翌日には失効する。さらに `runtime.exs` は Application 未起動でも動くよう stdlib のみでパースし、「許可値・確認規則は `Bitflyer.TradeMode` と揃えること」とコメントで二重管理を明示している（L78-79）。live 解禁が「モード変更」ではなく「モード + 当日確認 + Ready」の 3 条件になっているのは、Vision の Environment split / Safety first の具体化として質が高い。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

- **本番 HTTP bind を allowlist にし、既定を loopback にしている** `+3`
  > `PHX_HTTP_IP` は `127.0.0.1`（既定）/ `0.0.0.0` / `::1` / `::` の 4 値のみ受け付け、それ以外は `raise` で起動を止める（runtime.exs L261-287）。Phoenix 生成物の既定は `{0,0,0,0,0,0,0,0}`（全 IF）なので、これは明確に安全側へ倒す変更。`compose.prod.yaml` はコンテナ内 `0.0.0.0` + ホスト側 `127.0.0.1:4000` 公開という組み合わせで、その理由もコメントに書かれている（L58-60）。DB はホストへ公開せず `expose` のみ（L19-21）。VLAN 越し運用の想定に対して、公開面が二重に絞られている。
  > 対象ファイル: `config/runtime.exs`, `compose.prod.yaml`

- **prod では秘密情報が欠けていれば起動しない** `+3`
  > `UI_BASIC_AUTH_USERNAME` / `PASSWORD` は prod で必須（runtime.exs L189-197）、`BITFLYER_API_KEY` / `SECRET` は `TRADE_MODE=live` で必須（L128-134、メッセージに「出金権限なしで発行すること」まで書いてある）、`SECRET_KEY_BASE` も必須（L250-256）。`compose.prod.yaml` は Compose 側でも `${POSTGRES_PASSWORD:?...}` / `${DATABASE_URL:?...}` / `${UI_BASIC_AUTH_USERNAME:?...}` で必須化しており（L24, L56-67）、アプリに届く前に落ちる。「設定漏れで気付かないまま無防備に上がる」経路が塞がれている。
  > 対象ファイル: `config/runtime.exs`, `compose.prod.yaml`

- **テスト環境では API キーと BasicAuth を強制的に無効化する** `+3`
  > `runtime.exs` は `config_env() == :test` のとき、`.env` に本物のキーが入っていても空に潰す。
  >
  > ```elixir
  > # config/runtime.exs L137-144
  >   :test ->
  >     # runtime は test.exs の後。.env のキーがテストに漏れないよう空にする。
  >     {"", ""}
  > ```
  >
  > BasicAuth も同様に test では固定オフ（L199-201）。`runtime.exs` が `test.exs` の**後**に評価されるという Elixir の実行順を理解したうえでの措置で、理由がコメントに残っている。開発者が `.env` に live キーを置いた状態で `mix precommit` を回しても、テストから実 API に届かない。地味だが事故を実際に防ぐ類の配慮。
  > 対象ファイル: `config/runtime.exs`

- **本番イメージが multi-stage / 非 root / tini / 依存キャッシュ最適化を満たしている** `+4`
  > `Dockerfile.prod` は builder（`elixir:1.18.3-otp-27-slim`）と runner（`debian:bookworm-slim`）を分け、`mix.exs` / `mix.lock` / `config` を先に COPY して deps 層をキャッシュし（L27-32）、release だけを runner へ `--chown=app:app` でコピーする（L61）。`useradd --uid 1000 --shell /usr/sbin/nologin` で非 root 化（L55-56, L67）、`tini` を PID 1 にしてゾンビ回収とシグナル転送を担わせる（L78）。Elixir / OTP のバージョンを開発 Dockerfile・CI と揃えることが冒頭コメントで宣言されている（L2）。`rel/overlays/bin/server` を使う Phoenix 標準の release 構成にも乗っている。本番コンテナの作法として過不足がない。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

- **`.dockerignore` が「なぜ必要か」から書かれ、秘密とワークスペースを確実に除外する** `+3`
  > 冒頭に「本番 Dockerfile の COPY 混入防止のため先に置く。完了条件: `.env` / `_build` / `deps` / `.git` がイメージ構築コンテキストに入らないこと」（.dockerignore L1-2）。`.env` / `.env.*` / `*.pem` / `*.key` / `secrets/` / `credentials.json` に加え、`.git/` / `.github/` / `.cursor/` / `.workspace/` まで落としている。`Dockerfile.prod` は `COPY apps apps` という広い COPY をするので、この除外リストが実質的な防波堤になる。`git check-ignore` でも `.env` / `.env.prod` の両方が `.gitignore` に掛かっていることを確認した（追跡されているのは `.env.example` のみ）。
  > 対象ファイル: `.dockerignore`, `.gitignore`

---

## 技術評価層 — CI / CD

- **CI の品質ゲートがローカルと同一の `mix precommit` 1 本で、test にも warnings-as-errors が掛かる** `+3`
  > `mix.exs` L47-53 の `precommit` は `deps.unlock --check-unused` → `format --check-formatted` → `compile --warnings-as-errors` → `test --warnings-as-errors`。**`test/` は compile 対象外なので test 側にも明示的に付ける**、という理由がコメントで書かれている（L51）。`cli/0` の `preferred_envs: [precommit: :test]` により環境指定も不要。CI（ci.yml L114-115）はこの 1 コマンドだけを叩く。`.env` に `MIX_ENV` を書くと `preferred_envs` が効かなくなる、という落とし穴が `.env.example` L37 と README L94 の両方に書かれている。「ローカルと CI で同じゲート」が形式ではなく実際に成立している。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

- **`deps.audit` をゲート外で可視化し、「CI 緑 ≠ 脆弱性なし」を明記している** `+3`
  > ci.yml L69-109 は `continue-on-error: true` で `mix deps.audit --format=json` を 1 回だけ実行し、結果を `clean` / `vulnerabilities_found` / `audit_tool_or_fetch_failed` の 3 値に分類して artifact に残す。ツール失敗と脆弱性検出を混同しない設計になっており、非ゼロ終了時は `::warning::` で「CI green does not mean no advisories」と出す。README L114 も「Hex の既知 advisory が対象。`heroicons` / `daisyui` など GitHub タグ依存はスキャンされない。**CI 緑 ≠ 依存に既知脆弱性なし。**」と限界を明示している。導入したツールの**保証範囲を過大に見せない**姿勢は、セキュリティ機構そのものより価値がある。
  > 対象ファイル: `.github/workflows/ci.yml`, `README.md`

- **CD が明示タグ / 手動限定で、digest を出力しロールバック単位を固定する** `+3`
  > `cd.yml` L6-15 は `push: tags: v*` と `workflow_dispatch` のみ。`main` へのマージだけでは発火しない。`environment: production`（L29）で承認ゲートを掛けられ、`concurrency` で同時実行を防ぐ。ビルド後に `APP_IMAGE=ghcr.io/...@sha256:<digest>` の形で貼り付け用の行を出力し（L78-80）、`compose.prod.yaml` L41-43 が「digest 固定。未設定時はローカル build（検証用）。`:latest` だけに頼らない」で受ける。`bin/deploy-prod.sh rollback <image@digest>` まで用意されているので、「何を戻すのか」が一意に決まる。個人プロジェクトの CD としては十分にプロダクション水準。
  > 対象ファイル: `.github/workflows/cd.yml`, `compose.prod.yaml`, `.workspace/0_doc/architecture/env/prod.md`

---

## 横断評価層

- **資金保全の回帰テストが「守りたい性質」の一覧として機能している** `+4`
  > `capital_preservation_test.exs` の moduledoc がそのまま安全ネットの目録になっている。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs L4-14
  > # - 重複 intent（冪等）/ trade_mode 分離 / boot reconcile halt → 発注不可
  > # - risk 拒否が executor 経由でも永続化・REST を起こさない
  > # - live submission 不明（timeout）→ halt・再送禁止
  > # - live exchange_order_id 永続化失敗 → halt・再送禁止
  > # - live 空 BalanceSnapshot → baseline missing で halt
  > # - 公開 submit は authorize?: false でも risk を迂回できない
  > ```
  >
  > `SpyExchange` は `place_order` の呼び出し回数を Agent で数え、「拒否されたときに REST が **0 回**であること」を直接検証する。「部品テストは各モジュールに任せ、ここでは縦貫通の安全ネットだけを固定する」という役割分担も明示されている。テストが仕様書として読める状態は、この規模ではかなり珍しい。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

- **`Bitflyer.System` ファサードが境界を 1 箇所に集約している** `+3`
  > UI / health / mix タスクが `bitflyer` に触る入口が `Bitflyer.System` に揃っている（`health*/1`, `operational_status/1`, `readiness/0`, `exchange_order_gate/0`, `reconcile_now/0`, `resume/1`, `submit_order/2`）。`submit_order/2` の doc には「risk は常に必須。`OrderExecutor.submit/2` 経由でもスキップできない」と書かれている（system.ex L129）。`ui` → `bitflyer` の一方向依存が、実際に 1 モジュールの厚み分だけ守られている。第 3 の Umbrella アプリも切られていない（`apps/` は `bitflyer` と `ui` のみ）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **文書が「正本」を宣言し、コードと相互参照している** `+4`
  > `overview.md` は Ready の正本を `Bitflyer.Readiness`、telemetry 語彙の正本を `Bitflyer.Telemetry` と名指しし、コード側の moduledoc も同じ言葉で受ける（readiness.ex L14、telemetry.ex L3）。`prod.md` は停止・再開の具体コマンド（`docker compose exec app mix bitflyer.resume`、release では `rpc "Bitflyer.Release.resume()"`）と「`eval` は使わない」理由まで書く。README のコンポーネント表（L23-43）は 18 行で現状が分かる形になり、前回指摘した「実装が README を追い越した」問題は解消された。`ci-cd.md` / `dev.md` / `prod.md` / `vision.md` の役割分担も重複が少ない。文書がコードの後追いメモではなく、判断の記録になっている。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/prod.md`, `README.md`

- **improvement-plan の自己改善サイクルが実際に回っている** `+4`
  > 2026-09-09 の `improvement-plan.md` は P0 を 5 項目、P1 を 4 項目、P2 を 5 項目、P3 を 5 項目に分け、それぞれに「完了の見方」を書いていた。今回コードを読み直した結果、**P0 の 5 項目すべてと、P1〜P3 の 14 項目すべてが実装で確認できた**（詳細は総合レポート）。しかも各項目の「完了の見方」に対応するテストが残っている（`balance_baseline_missing` の halt、`authorize?: false` の迂回不可、`submission_unknown` の再送禁止、`prep_stop` 後の submit 拒否）。git ログを見ると 1 項目 = 1 PR = 1 レビューの粒度で進んでおり、評価 → 計画 → 実装 → 再評価のループが仕組みとして機能している。この運用自体が、コードの質を継続的に支えている資産。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| 技術評価層 — apps/bitflyer（order-executor） | +28 |
| 技術評価層 — apps/bitflyer（risk / 突合 / Readiness） | +26 |
| 技術評価層 — apps/bitflyer（market-data / strategy / 永続 / observe / OTP / exchange） | +38 |
| 技術評価層 — apps/ui | +12 |
| 技術評価層 — 実行基盤 / 設定 | +20 |
| 技術評価層 — CI / CD | +9 |
| 横断評価層 | +15 |
| **合計** | **+148** |
