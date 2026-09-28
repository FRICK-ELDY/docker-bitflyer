# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-29

対象コミット: `80c486f`（`docs: 作業PCの ready 常駐で監視条件を閉じ、解除手順を残す`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
種別: **同日の上書き再評価**（P1 #3 の実装と P1 #5 の完了宣言の後で採点し直した）

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての加点は当該コードの再読で確認したものに限る。
行番号は**本サイクルで実際に読んだ箇所**だけを記す。
`mix precommit` は本再評価では**未再実行**。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +54 点**

朝の下書きは +52 だった。差分は 2 件である。

- **`+4` → `+5`**: HWM の永続化。`PeakWriter.enqueue/4` が DB upsert 成功と ack まで待って `:ok` を返すようになり、認可が返った時点で DB に高値がある。前回まで残差として減点していた「認可後の強制終了で高値が戻る」窓が消えた。
- **`+1` 新規**: `/health/ready` の常駐監視と、リポジトリ外に置いた `READY_URL` を消す解除手順。

なお下書きにあった `absorb_enqueues/1`（flush 中の enqueue をメールボックスから取り込む）への言及は取り消す。同期化に伴って**この関数は現在のコードに存在しない**ため、加点の根拠から外した。

---

## 技術評価層 — apps/bitflyer

### order-executor / 手数料会計

- **売買それぞれの実約定で手数料単位を確定し、実差分を回帰テストに固定した** `+5`
  > 3 サイクル「公式記載からの類推」で止まっていた P0 #1 を、実口座の最小ロット往復で閉じた。証跡は匿名化したうえで、検証に必要な数値をすべて残している。
  >
  > ```
  > # .workspace/0_doc/architecture/env/commission-unit-evidence.md L50-58
  > | execution id | …6098 | …6123 |
  > | size | 0.00101151 | 0.00100848 |
  > | price | 13311678 | 13326965 |
  > | commission | 0.00000151 | 0.00000151 |
  > | JPY 実差分 | −13465 | +13439 |
  > | BTC 実差分 | +0.00101 | −0.00100999 |
  > ```
  >
  > 重いのは数値そのものではなく、**前サイクルの内部モデルが実際に誤っていたことまで記録している**点である（証跡 L61: 旧売り式だと JPY は約 20 円多く、BTC は `C` だけ少なく、絶対床の外）。自分の会計モデルを実口座で反証して差し替え、反証の過程を残している。
  >
  > 署名つき `gettradingcommission` が `0.0015`、出金権限なし、全量売りが `insufficient_funds` で拒否されたので売り数量を `available / 1.0015` に切った、という実験条件も同じ場所にある（証跡 L46）。`LiveBalance.explain/4`（live_balance.ex L66）と `fill_delta/2`（同 L267）が単位を織り込み、`Product.fee_currency/1` が spot を base に倒す（product.ex L114-119）。
  >
  > 「取引所の事実はモックでは決められないので、観測して記録する側に境界を移す」という判断が正しく、実行もされている。このクラスの個人プロジェクトで、会計モデルを実口座で反証して差し替え、その過程を含めて証跡化した例は見たことがない。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/trading/product.ex`

- **売り余白を公表上限 0.15% で取り、建玉ちょうどの売りを取引所より先に拒む** `+3`
  > 全量売りが取引所側で `insufficient_funds` になったという観測（証跡 L46）を、認可の条件に翻訳している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L69-72, L91-93
  > # Lightning 現物の公表上限（約定数量 × 0.15%）。口座の実レートはこれ以下。
  > # 認可はこの率で base を多めに拘束し、全量売りが insufficient_funds になるのを拒む。
  > @max_spot_fee_rate Decimal.new("0.0015")
  > ...
  > def sell_base_debit(product_code, %Decimal{} = size) when is_binary(product_code) do
  >   if spot?(product_code) and fee_currency(product_code) == base_currency(product_code) do
  >     Decimal.add(size, Decimal.mult(size, @max_spot_fee_rate))
  > ```
  >
  > 約定前に実 commission は分からないので**不足側に倒す**、という方向が正しい。`Risk.balance_hold/2`（risk.ex L180）が認可側で同じ負担を見るので、認可と突合が同じ式を通る。
  >
  > 良いのは副作用まで moduledoc に書いていることである。「口座レートが 0.15% 未満だと、残りが最小数量（BTC_JPY は 0.001）を下回って次の売りは余白不足で通らず、long が残る」（product.ex L86-88）。取引所の拒否を先取りする設計は、そのぶん自分が拒否側に倒れるという対価を持つ。それを隠していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

**小計: +8 点**

### risk-manager / HWM

- **ドローダウン基準点（HWM）を、認可が返る前に DB へ落としきる耐久経路** `+5`
  > 本サイクルの中心である。認可で上がった当日高値が「メモリにしか無い」時間をゼロにした。
  >
  > 経路は 4 段で、どの段も同期である。`check_daily_drawdown/2` が `persist: false` + `write_behind: true` で `Equity.enforce/1` を呼び（risk.ex L660-671）、`DailyLoss.schedule_write_behind/4` が `PeakWriter` へ 5 秒タイムアウトの `call` を出し（daily_loss.ex L393-403）、`handle_call({:enqueue, ...})` の非 suspend 節が**返答より前に** upsert と ack を実行する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/peak_writer.ex L163-175
  > true ->
  >   state = put_pending(state, trade_mode, day, peak, daily_loss)
  >
  >   case persist_attempt(state, trade_mode, day, peak, daily_loss) do
  >     :done ->
  >       state = drop_covered(state, trade_mode, day, peak)
  >       {:reply, :ok, kick(%{state | writing?: false})}
  >
  >     :retry ->
  >       state = requeue(state, trade_mode, day, peak, daily_loss)
  >       Process.send_after(self(), :flush, @retry_ms)
  >       {:reply, {:error, :unsynced}, %{state | writing?: true}}
  >   end
  > ```
  >
  > つまり失敗は `{:error, :unsynced}` として認可へ返り、`check_daily_drawdown/2` は `{:error, :unsynced, meta}` で発注を拒否する（risk.ex L690-691）。**「基準点を DB に書けないなら発注しない」という fail-closed が、ドローダウン保護にまで及んでいる。**
  >
  > そのうえで、耐久キューとして必要なものが揃っている。
  >
  > - `trap_exit` を立て、親の `:shutdown` でも `terminate/2` へ届かせる（L132-134, L224-227）
  > - `init/1` が `DailyLoss` の未永続高値を積み直すので、**自分が kill されても生存している `DailyLoss` の ETS から復元できる**（L131-146 / daily_loss.ex L730-743 の `:unpersisted_peaks`）
  > - upsert 失敗は pending に残して再送し、ack が `:down` のときも捨てない（L287-299）
  > - `drop_covered/3` が「書いた値より高い pending」だけを残す（L401-415）
  > - `Application.prep_stop/1` が `PeakWriter.drain()` を呼び、失敗時は `DrainHalt.record/1` へ落とす（application.ex L111-143）
  > - 子順が意図どおり（`DailyLoss` の後に起動し、停止時は先に落ちる。application.ex L28-32）
  >
  > 検証も強制終了そのものを使っている。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs L139-157
  > test "write-behind success leaves the DB peak after both processes are discarded" do
  >   assert {:ok, peak} = DailyLoss.record_peak(:paper, Decimal.new("160000"), persist: false, write_behind: true)
  >   assert PeakWriter.pending_count() == 0
  >   ...
  >   Process.exit(pid, :kill)
  >   assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  >   ...
  >   assert :ok = DailyLoss.reinit()
  >   assert {:ok, %{peak: restored}} = DailyLoss.snapshot(:paper)
  >   assert Decimal.eq?(restored, Decimal.new("160000"))
  > ```
  >
  > `pending_count() == 0` で「返答時点で未書きが無い」ことを押さえ、`kill` と `reinit()` で「プロセス側の記憶を全部捨てても DB から同じ高値が戻る」ことを押さえている。同時に、失敗側のテストも `:ok` から `{:error, :unsynced}` へ書き換わっており（test L62, L79, L105 付近の 3 箇所）、**成功と失敗の両方が契約として固定されている**。
  >
  > `+5` の理由は、単に耐久化したことではない。ホットパスの DB 往復を避けるという一般的な最適化と、ドローダウン基準点を失わないという資金保全要件がぶつかったときに、**後者を選び、選んだ代償（新高値ごとに 1 往復、失敗時は発注拒否）を実装と契約で明示した**点にある。個人プロジェクトでこの優先順位を選ぶ例は少なく、選んだあと `kill -9` で検証する例はさらに少ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs`

- **drain 失敗の停止を Postgres の外に fsync で残し、次回起動が Ready になる前に読み戻す** `+4`
  > 「DB へ halt を書けないときの停止をどう残すか」という、多くの実装が見落とす問いに正面から答えている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/drain_halt.ex L5-8
  > drain が落ちるときは DB も書けないことが多い。RiskState への halt が
  > 失敗すると、メモリ上の停止は再起動で消える。先にローカルファイルを置き、
  > 次の起動の突合が Ready にする前に止める。印を消したあとも、DB に残った
  > halt を ETS へ載せてから Ready を判定する。成功した突合は停止を解除しない。
  > ```
  >
  > 順序が正しい。`record/1` は**印を先に書いてから** `Readiness.halt/1` と RiskState を試し、DB に書けたときだけ印を消す（L36-44）。書けなければ `:marker_only` を返して印を残し、`:critical` で記録する（L46-54）。`enforce/1` は印があれば `halt(:persist_failed)` してから DB へ書き直し、書けなければ印を残してこの起動を `:halted` にする（L73-97）。
  >
  > 置き場所まで環境別に詰めてある。既定は `BITFLYER_DRAIN_HALT_PATH`、未設定時だけ tmp で、「tmp は同じコンテナの再起動では残るが、作り直しや掃除では消える」と限界まで書いている（L21-27）。本番はそれを専用ボリュームへ向け、所有者を合わせる使い捨てサービスまで用意している（compose.prod.yaml L46 の `entrypoint: ["chown", "1000:1000", "/var/lib/bitflyer"]`、L87 の `BITFLYER_DRAIN_HALT_PATH: /var/lib/bitflyer/hwm-drain-halt`）。
  >
  > 「印がどこに残るか」を環境ごとに設計している時点で、思いつきの実装ではない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/drain_halt.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `compose.prod.yaml`

- **`DailyEquityPeak` が `GREATEST` の `ON CONFLICT` 1 文になり、文字列一致の再試行が消えた** `+3`
  > 「`inspect/1` の文字列で一意制約衝突を拾う」4 段構えが、単調増加という意味論をそのまま表す 1 文に置き換わった。
  >
  > ```sql
  > -- apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L110-117
  > ON CONFLICT (trade_mode, trading_day)
  > DO UPDATE SET
  >   peak = GREATEST(daily_equity_peaks.peak, EXCLUDED.peak),
  >   updated_at = CASE
  >     WHEN EXCLUDED.peak > daily_equity_peaks.peak THEN EXCLUDED.updated_at
  >     ELSE daily_equity_peaks.updated_at
  >   END
  > ```
  >
  > 生 SQL に落とした理由がバージョンと失敗モードつきで残っている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L99-101
  > # AshPostgres 2.13 の upsert は PostgreSQL 17 で MERGE になる。MERGE は
  > # 同じキーの並行 insert を待たず、敗者が一意制約で落ちる。HWM は
  > # INSERT ... ON CONFLICT の 1 文で仲裁する。
  > ```
  >
  > フレームワークの抽象を捨てる判断に、いつ・なぜという根拠が添えてある。`updated_at` を「高い値で上書きしたときだけ前進させる」のも、低い後着で更新時刻が動かないという意味で正しい。0 以下の peak は SQL に到達する前に `:ok` で落とす（L91-94）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **成行の残高拘束が `best_ask × size` になり、拘束しきれない部分を moduledoc が明示する** `+2`
  > 「板は取れているのに LTP で拘束する」が閉じた。`base_unit_price(:live, :buy, :market, ...)` は `fetch_bid_ask` の ask を返し（risk.ex L825）、欠落は `bid_ask_missing` で fail-closed（L832）。指値は渡された価格をそのまま使い（L818）、paper は LTP 側の節へ落ちる（L838）。
  >
  > 良いのは、直したうえで**まだ拘束できない分を書いている**ことである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L38-41
  > live 成行買いの拘束は `best_ask × size` ちょうど（LTP だと薄いスプレッドで過小）。
  > ticker に気配数量が無いので、最上段を超えて歩いた平均は ask を超えうる。
  > その超過は拘束せず、部分約定の解放はサイズ比のまま残る。
  > paper 成行買いは LTP に `FillPricing` の不利化だけを載せる（ask は重ねない）。
  > ```
  >
  > 残差を隠さず、かつ二重に不利化しない理由まで同じ場所にある。成行の spread ゲート（`max_spread_pct`。risk.ex L579-584）と板欠落拒否（L594）も同じ層に揃っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

**小計: +14 点**

### market-data

- **ticker を `{ltp, book}` の 2 層に分け、板異常と配信停止を切り分けられるようにした（維持）** `+3`
  > 「板が crossed / ゼロだと ticker ごと破棄し、板異常が鮮度切れに化ける」を 2 層化で閉じた状態が保たれている。`cast_book/2`（normalize.ex L243）は無効な板で `nil` を返すだけで、LTP は Cache に載る。
  >
  > 層を導入したあとの読み取り規律が徹底されている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/normalize.ex L130-136
  > def book(%{book: nil}), do: :miss
  > def book(%{"book" => nil}), do: :miss
  > def book(%{book: book}) when is_map(book), do: book_quotes(book)
  > ...
  > def book(%{best_bid: bid, best_ask: ask}), do: valid_book(bid, ask)
  > ```
  >
  > `book` キーがあるときは平坦な `best_bid` / `best_ask` へ**落ちない**。`source_timestamp/1` も同じで、LTP 層があればその時刻だけを見る（L146-162）。移行前の手書き値との互換を残しつつ、層がある値では曖昧さを作らないという判断である。
  >
  > 切り分け先も用意されている。`/health/ready` は LTP 鮮度で判定して 200 のまま、JSON の `book` / `all_books` で板欠落を出す（health.ex L15, L188）。成行の拒否は `bid_ask_missing`（risk.ex L12, L594）。overview の「配信停止と混ぜない」（L159）がコード 3 箇所で守られている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/health.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

**小計: +3 点**

### 診断タスク / 運用

- **Game Day Stage 2 が永続停止を消さず、停止中は監督木すら起動しない（維持）** `+4`
  > 「診断タスクがグローバル停止状態を無条件に解除する」を、指摘より広く直した状態が保たれている。
  >
  > 第一に、`app.start` の**前に** Repo だけを起こして `RiskState` を読む（`persisted_start_block/0` は L218、`with_repo/1` は L145、呼び出しは L63-68）。halted / 読取不能なら中断する。
  >
  > 第二に、この BEAM だけ起動副作用を外す。`disarm_startup!/0`（L161）が `Reconciler` の `boot?`・`CircuitSync`・`OpenOrderPolicy` を差し替え、`after` で必ず戻す（呼び出しは L51）。常駐側の設定は触らない。
  >
  > 第三に、Ready の作り方が `Readiness.mark_ready()` の直接呼び出しではなく `require_ready_via_reconcile/0`（L228）になった。`Reconciler.run_now/0` が `:ok` で、かつ `Readiness` が `:ready` のときだけ通る。
  >
  > 第四に、各発注段の前に `order_gate/0`（L245）が**永続停止を読み直す**（L283 / L310 / L352）。`CircuitSync` を止めているので、別 BEAM が共有 DB を halt してもここで止まる。
  >
  > 「診断ドリルが安全装置を壊してはいけない」という原則を、中断・無効化・再読の 3 段で実装しきっている。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`

**小計: +4 点**

### datastore / Ash

- **Ash を永続状態に限定し、判定ループは ETS のまま保たれている（維持。HWM のみ意図的な例外）** `+3`
  > overview L97 の「ホットパスから Resource を呼ばない」が、実装が厚くなった今も原則として守られている。頻度は `Risk.OrderRate`、連続エラーは `Risk.FailureRate`、日次損失は `Risk.DailyLoss`、残高は `Risk.BalanceCache.probe/4`（risk.ex L34, L729）で、いずれも ETS である。
  >
  > 本サイクルで HWM の upsert だけが同期化されたが、これは Ash Resource ではなく生 SQL 1 文であり（daily_equity_peak.ex L102-131）、発火は新高値のときだけである。原則を捨てたのではなく、資金保全のために 1 点だけ例外を置いた形になっている（その例外が `risk.ex` の moduledoc に書かれていないことは weaknesses の `-1`）。
  >
  > 書き込み側は必要な強度を取っている。`LiveBalance` は `pg_advisory_xact_lock` で tip 前進を直列化する（live_balance.ex L569）。Decimal 徹底も維持されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

**小計: +3 点**

---

## 技術評価層 — 実行基盤 / 設定

- **live 実発注が「設定 1 つ」では絶対に起きない多段ゲート（維持）** `+4`
  > ゲートが 6 段ある。
  >
  > 1. `TRADE_MODE` は allowlist。不正値は起動停止（runtime.exs 周辺。既定は `dry_run`）
  > 2. `BITFLYER_LIVE_CONFIRM` が **UTC 当日の `YYYY-MM-DD`** と一致しないと live 実発注は不可（runtime.exs L76, L100）。昨日の値を残しても通らない
  > 3. live かつキー両方ありのときだけ実 REST クライアントを差す
  > 4. `LiveSafety.apply_live_overrides!/3`（runtime.exs L162）が Strategy を既定無効にし、`FixedOnce` の有効化を拒否し（live_safety.ex L93-98）、Risk 上限を環境変数必須にする（live_safety.ex L136-138 の doc）
  > 5. `require_max_open_age_ms!/1` が `BITFLYER_MAX_OPEN_AGE_MS` を必須にし、7 日超も拒否する（live_safety.ex L112-133）。GTC 無期限を防ぐ
  > 6. `assert_live_products!/1` が空リストと非 spot を起動停止（live_safety.ex L50-74）
  >
  > 「live へ切り替える操作は設定上で目立たせる」（overview L103）が、目立たせるどころか**うっかりでは到達できない**ところまで作り込まれている。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **開発と本番の Compose / Dockerfile が完全に分かれ、本番は非 root release + tini + loopback bind（維持）** `+3`
  > `Dockerfile.prod` は release を `--chown=app:app` で配って `USER app` に落とし（L61-67）、PID 1 は `tini` でゾンビ回収とシグナル転送を任せている（L53, L77-78）。開発 `Dockerfile` は 20 行でソースを焼かず bind mount 前提（L1）。
  >
  > `compose.prod.yaml` も詰まっている。`db` は `ports` ではなく `expose` だけ（L21）。アプリのホスト公開は既定 loopback（L59 の `${APP_HOST_PORT:-127.0.0.1:4000}`）で、コンテナ内は全 IF だがホスト側 bind で絞るという理由がコメントにある（L71）。`stop_grace_period: 45s`（L61）は子 5s × 複数 + Repo という予算から来ている（application.ex L8-11 と対応）。healthcheck は `/health/live` を見るので WS 断でコンテナを再起動しない（L97、overview L145 と一致）。
  > 対象ファイル: `Dockerfile.prod`, `Dockerfile`, `compose.prod.yaml`

**小計: +7 点**

---

## 技術評価層 — CI / CD

- **ローカルと CI が同一の `mix precommit`、Actions は SHA ピン、audit と本番ビルドを分離（維持）** `+3`
  > `precommit` は 5 本で、うち 2 本が drift 検出に向いている（mix.exs L47-54: `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `ash.codegen --check --domains Bitflyer.Trading` / `test --warnings-as-errors`）。`test --warnings-as-errors` を別に付けた理由が「`test/` は compile 対象外のため」とコメントされている（L53）。`preferred_envs: [precommit: :test]`（L27）で環境も固定している。
  >
  > `ci.yml` は同じ `mix precommit` を 1 ステップで呼ぶ（L18, L72）。`deps.audit` は別ジョブで、ツール障害と advisory 検出を `bin/classify-deps-audit.sh` で分ける（L120）。`Dockerfile.prod` の push なしビルドまで PR で回し、そのコストがトレードオフであることもコメントに書いてある（L134-150）。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`, `bin/classify-deps-audit.sh`

**小計: +3 点**

---

## 横断評価層

### テスト戦略

- **ハーネスに売り手数料の 2 モデルを持たせ、誤モデルが縦回帰で halt することを固定した（維持）** `+3`
  > 「ハーネスが本番と同じ式を実装していて反証になっていない」を、モデルスイッチで閉じた状態が保たれている。
  >
  > ```elixir
  > # apps/bitflyer/test/support/live_exchange_harness.ex L7, L129-132
  > # `:quote_mark` は反証用。内部 explain とは独立に残高を動かす。
  > ...
  > `:quote_mark` は手数料を quote の受取から引く旧仮説で、縦回帰の反証に使う。
  > @spec set_sell_fee_model(:base_deduct | :quote_mark) :: :ok | {:error, :open_orders}
  > ```
  >
  > 残高を動かす側の分岐（L195-212、L335-350）が独立しているので、内部式を旧仮説に戻すと縦回帰が `balance_mismatch` で halt する。`:open_orders` があるあいだはモデル切替を拒む、という細部も整合を壊さないためである。
  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`

- **706 本のテストが発注経路・冪等・モード分岐・突合・サーキット・鮮度を覆う（維持）** `+3`
  > `apps/bitflyer/test` と `apps/ui/test` の `test` / `property` 宣言を本サイクルで数え直して 706 件（前サイクル 705 に、`peak_writer_test.exs` の強制終了テスト 1 本が加わった）。
  >
  > 資金保全の回帰が独立したディレクトリにあるのが良い。`test/bitflyer/regression/` は「壊れたら資金に触る」性質のものだけを集めている。副作用ゼロの担保もあり、両 `test_helper.exs` が `Sandbox.mode(Bitflyer.Repo, :manual)`、テスト注入は `Bitflyer.Risk` の `allow_test_injections` で守られ、本番経路では注入が黙って無視される（peak_writer.ex L444-448 の `test_injections_allowed?/0` も同じ規律で、`suspend/1` / `set_upsert/2` は本番で `{:error, :forbidden}`）。
  >
  > 注入で迂回できない設計は珍しい。とくに `PeakWriter` は「テスト用の `suspend/1` だけは受理を先に返す。本番の認可経路では suspend しない」と moduledoc に書いたうえで（L16）、その分岐を `allow_test_injections` で閉じている。
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`, `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`

**小計: +6 点**

### 可観測性

- **telemetry メタデータの allowlist と、発注経路から独立した Discord アダプタ（維持）** `+3`
  > `Bitflyer.Telemetry` が語彙の正本で、`execute/3` / `log/3` / `put_logger_metadata/1` の 3 経路すべてが `sanitize_metadata/1` を通る（telemetry.ex L106, L114, L122, L129-134）。秘密らしきキーは allowlist に入らない限り落ちる。
  >
  > Discord は overview の方針どおり第 3 アプリではなくアダプタで、`Application` の子として**発注経路の兄弟**に置かれている（application.ex L38-40 のコメント「発注経路の兄弟。通知失敗・クラッシュで取引木を巻き込まない」）。telemetry の attach/detach は起動時に 1 度だけで、GenServer 再起動ごとに付け外ししない（application.ex L49-50）。停止時は `prep_stop/1` の先頭で外す（L68）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **`/health/ready` の常駐監視を登録し、`READY_URL` を消せる解除手順まで用意した** `+1`
  > 本サイクルの新規。作業 PC に `BitflyerWatchReady` を常駐させ、証跡ログに探針の失敗が残る状態を作った（watch-ready-evidence.md L97-108）。
  >
  > 評価できるのは 2 点である。第一に、登録スクリプトが**リポジトリに秘密を置かない**。`READY_URL` を含む wrapper は `%LOCALAPPDATA%\bitflyer` に書き、タスクはそれを呼ぶ（register-watch-ready-task.ps1 L16-41）。ログオン起動と `RestartCount 3` / `AllowStartIfOnBatteries` も付いている（L46-51）。
  >
  > 第二に、**外し方が用意されている**。`unregister-watch-ready-task.ps1` は停止 → `Unregister-ScheduledTask` → wrapper 削除の順で、証跡ログだけは残す（L18-32）。`prod.md` L150 と証跡 L73-79 の両方に解除手順がある。監視の常駐は「入れたあと誰も外せない」ことが多いので、`READY_URL` が入ったファイルを消すところまで手順にしてあるのは良い。
  >
  > `+1` に留める理由は、この常駐の `READY_URL` が同一ホストの開発 Compose（`127.0.0.1:4000`）であり、取引ホスト死の検知にはまだなっていないためである（これは所有者が見方を書き換えたので減点しない。次の段は提案に置いた）。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`, `bin/unregister-watch-ready-task.ps1`, `.workspace/0_doc/architecture/env/prod.md`

**小計: +4 点**

### プロジェクト全体設計・プロセス

- **improvement-plan の「完了」に観測 1 行を必須化し、見方を下げるときは先に見方を書き換える運用を実践した** `+2`
  > 「完了条件を満たさない項目を取り消し線で消している」を、ルール化で閉じた状態が保たれている。同じ規律が `.cursor/rules/evaluation.mdc` L300-306 に評価手順として入り、次回評価が矛盾を落とすところまで手続き化されている。
  >
  > 本サイクルで実際にその手続きが使われたことを加点する。P1 #5 は、基準を下げるときに**先に見方を書き換えてから完了を付ける**（evaluation.mdc L305）という順序を踏んでいる。基準を下げたこと自体は議論の余地があるが、「黙って完了にする」のではなく「見方を明示的に書き換えてから完了にする」を選んだのは、次の評価者が採否を判断できる形である。実際に本評価はその書き換えを根拠に採用を決めた。
  >
  > P1 #3 も同様に、部分完了として残していた残差を実装で潰し、`{:error, :unsynced}` を返す契約をテストで固定してから完了にしている。**プロセスが飾りではなく判断の道具として回っている。**
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.cursor/rules/evaluation.mdc`

**小計: +2 点**

---

## 小計一覧

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer — order-executor / 手数料会計 | +8 |
| apps/bitflyer — risk-manager / HWM | +14 |
| apps/bitflyer — market-data | +3 |
| apps/bitflyer — 診断タスク / 運用 | +4 |
| apps/bitflyer — datastore / Ash | +3 |
| 実行基盤 / 設定 | +7 |
| CI / CD | +3 |
| 横断（テスト戦略） | +6 |
| 横断（可観測性） | +4 |
| 横断（プロジェクト全体設計・プロセス） | +2 |
| **合計** | **+54** |
