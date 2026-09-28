# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-29

対象コミット: `afc46bb`（`Merge pull request #123 from FRICK-ELDY/fix/p2-10-completion-evidence`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-16](./archive/2026-09-16/opus-specific-strengths-2026-09-16.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての加点は当該コードの再読で再確認したものに限る。
維持されている長所も、今回あらためてファイルを読み直して確認できたものだけ計上した。

## 採点基準

    10|
| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +52 点**

    20|今サイクルの中心は「推定で回っていた資金会計を実測で固定した」ことと、「DB が書けないときに停止をどう残すか」に正面から答えたことである。前者は 3 サイクル open だった P0 を、匿名化した実口座の往復で閉じた。後者は Postgres の外へ fsync した印を置き、次回起動が Ready になる前にそれを読む、という設計まで踏み込んでいる。

---

## 技術評価層 — apps/bitflyer

### order-executor / 手数料会計

- **売買それぞれの実約定で手数料単位を確定し、実差分を回帰テストに固定した** `+5`
  > 本サイクルで最も重い前進である。3 サイクル「公式記載からの類推」で止まっていた P0 #1 を、実口座の最小ロット往復で閉じた。
  >
    30|  > 証跡は匿名化したうえで、検証に必要な数値をすべて残している。
  >
  > ```
  > # .workspace/0_doc/architecture/env/commission-unit-evidence.md L48-59
  > | | 買い | 売り |
  > | execution id | …6098 | …6123 |
  > | size | 0.00101151 | 0.00100848 |
  > | commission | 0.00000151 | 0.00000151 |
  > | JPY 実差分 | −13465 | +13439 |
  > | BTC 実差分 | +0.00101 | −0.00100999 |
    40|  ```
  >
  > そして**前サイクルの内部モデルが実際に誤っていた**ことまで記録している（証跡 L61: 旧売り式だと JPY は約 20 円多く、BTC は `C` だけ少なく、絶対床の外）。前回の評価で「売り側は確率 5 割の推定」と書いた指摘が、推定ではなく実測で片付いた形である。
  >
  > 実装は 3 モジュールで一致している。`LiveBalance.fill_delta/2` の売りが `−(S+C)` / `+S·P`（live_balance.ex L290-304）、`Positions.held_size/5` の売りが `size + fee`（positions.ex L355-361）、`Product.fee_currency/1` が spot を base に倒す（product.ex L114-119）。そのうえで回帰が実測値そのものを固定する。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/startup/live_balance_test.exs L452-455, L469-482
    50|  > test "2026-09-28 BTC_JPY buy and sell match base fee within the yen floor" do
  > ...
  >   after_buy_jpy = Decimal.new("86535")
  >   after_buy_btc = Decimal.new("0.00101")
  >   assert {:ok, _} = LiveBalance.explain(..., fee_tolerance_abs: %{"JPY" => "1", "BTC" => "0.00000001"})
  > ```
  >
  > 「取引所の事実をモックでは決められないので、観測して記録する側に境界を移す」という判断そのものが正しく、実行もされている。加えて Stage 3a の**発注しなかった**記録（証跡 L28-42。最小数量 0.001 BTC に届かないので翌日に円を足した）まで残っている。このクラスの個人プロジェクトで、自分の会計モデルを実口座で反証して差し替え、その過程を含めて証跡化した例は見たことがない。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/test/bitflyer/startup/live_balance_test.exs`

    60|- **売り余白を公表上限 0.15% で取り、建玉ちょうどの売りを取引所より先に拒む** `+3`
  > これも実測から来ている。全量売り（available ちょうど）が取引所側で `insufficient_funds` になったという観測（証跡 L46）を、認可の条件に翻訳している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L69-72, L90-97
  > # Lightning 現物の公表上限（約定数量 × 0.15%）。口座の実レートはこれ以下。
  > @max_spot_fee_rate Decimal.new("0.0015")
  > ...
  > def sell_base_debit(product_code, %Decimal{} = size) when is_binary(product_code) do
  >   if spot?(product_code) and fee_currency(product_code) == base_currency(product_code) do
  >     Decimal.add(size, Decimal.mult(size, @max_spot_fee_rate))
    70|  ```
  >
  > 約定前に実 commission は分からないので**不足側に倒す**、という方向が正しい。`Risk.balance_hold/2` は live の売りだけこれを使い、paper は `size` のまま（risk.ex L200-209。paper の手数料は約定価格に含む）。認可と突合が同じ負担を見る、という overview L113 の記述とも一致する。
  >
  > 注目すべきは副作用まで moduledoc に書いていることである。「口座レートが 0.15% 未満だと残りが最小数量を下回って long が残ることがある」（product.ex L86-88）。取引所の拒否を先取りする設計は、そのぶん自分が拒否側に倒れるという対価を持つ。それを隠さず書いている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### risk-manager

- **HWM の write-behind が、ホットパスから DB を外しつつ高値を 1 つも捨てない** `+4`
    80|  > `PeakWriter` は 468 行の専用 GenServer で、耐久キューとして必要なものがひととおり揃っている。
  >
  > - `trap_exit` を立て、親の `:shutdown` でも `terminate/2` へ届かせる（L127-130）
  > - `init/1` が `DailyLoss` の未永続高値を積み直すので、**自分が kill されても生存している DailyLoss の ETS から復元できる**（L131-140, daily_loss.ex L731-744 の `:unpersisted_peaks`）
  > - upsert 失敗は pending に残して再送し、ack が届かないときも捨てない（L292-304）
  > - `drop_covered/3` が「書いた値より高い pending」だけを残す（L407-419）
  > - `absorb_enqueues/1` が flush 中に届いた `enqueue` をメールボックスから直接取り込んで受理を返す（L429-441）。書き込み中の呼び出しがタイムアウトしない
  >
  > 最後の `absorb_enqueues/1` は、素朴な実装なら `handle_call` が塞がって認可側が 5 秒待つところを、明示的に捌いている。テストも窓を狙って書かれている。
  >
    90|  > ```elixir
  > # apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs L115-137
  > test "peak writer restart reloads an unpersisted ETS peak" do
  >   assert :ok = PeakWriter.suspend()
  >   assert {:ok, _} = DailyLoss.record_peak(:paper, Decimal.new("90000"), persist: false, write_behind: true)
  >   ...
  >   Process.exit(pid, :kill)
  >   ...
  >   assert Decimal.eq?(paper.peak, Decimal.new("90000"))
  > ```
  >
  > `Application` の子順も意図どおりで、`DailyLoss` の後に起動して先に停止する（application.ex L28-32 のコメント「DailyLoss より後に起動し、停止時は先に落ちる」）。ドローダウン保護の基準点を落とさないためにここまで組む例は、個人プロジェクトではまず見ない。
   100|  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **drain 失敗の停止を Postgres の外に fsync で残し、次回起動が Ready になる前に読み戻す** `+4`
  > 「DB へ halt を書けないときの停止をどう残すか」という、多くの実装が見落とす問いに正面から答えている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/drain_halt.ex L2-8
  > drain が落ちるときは DB も書けないことが多い。RiskState への halt が
  > 失敗すると、メモリ上の停止は再起動で消える。先にローカルファイルを置き、
  > 次の起動の突合が Ready にする前に止める。
  > ```
   110|  >
  > 順序が正しい。`record/1` は**印を先に書いてから** RiskState を試し、成功したときだけ印を消す（L36-44）。書き込みは `:sync` オプションで fsync する（L141-149）。`enforce/1` は印があれば `Readiness.halt(:persist_failed)` してから DB へ書き直し、書けなければ印を残してこの起動を Ready にしない（L72-97）。解除は `Resume` だけが担う（resume.ex L149）。
  >
  > 呼び出し位置も効いている。`Reconciler.apply_result/2` が**突合結果を適用するより前**に `enforce/1` を通すので、成功した突合が `persist_failed` を消して Ready にしてしまう経路が塞がれている（reconciler.ex L141-147）。
  >
  > 置き場所まで詰めてある。本番は専用ボリュームで、所有者を合わせる使い捨てサービスまで用意している。
  >
  > ```yaml
  > # compose.prod.yaml L41-47, L63-65, L87
   120|  > halt-dir:
  >   entrypoint: ["chown", "1000:1000", "/var/lib/bitflyer"]
  > ...
  >   volumes:
  >     - halt_marker:/var/lib/bitflyer
  >   ...
  >   BITFLYER_DRAIN_HALT_PATH: /var/lib/bitflyer/hwm-drain-halt
  > ```
  >
  > 開発側も bind mount 上の `/app/.data/hwm-drain-halt` に向けてある（compose.yaml L49-50）。「印がどこに残るか」を環境ごとに設計している時点で、思いつきの実装ではない。
   130|  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/drain_halt.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `compose.prod.yaml`, `compose.yaml`

- **`DailyEquityPeak` が `GREATEST` の `ON CONFLICT` 1 文になり、文字列一致の再試行が消えた** `+3`
  > 前回 `-1` だった「`inspect/1` の文字列で一意制約衝突を拾う」4 段構えが、単調増加という意味論をそのまま表す 1 文に置き換わった。
  >
  > ```sql
  > -- apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L110-117
  > ON CONFLICT (trade_mode, trading_day)
  > DO UPDATE SET
  >   peak = GREATEST(daily_equity_peaks.peak, EXCLUDED.peak),
  >   updated_at = CASE
  >     WHEN EXCLUDED.peak > daily_equity_peaks.peak THEN EXCLUDED.updated_at
   140|  >     ELSE daily_equity_peaks.updated_at
  >   END
  > ```
  >
  > 生 SQL に落とした理由もコメントに残っている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L99-101
  > # AshPostgres 2.13 の upsert は PostgreSQL 17 で MERGE になる。MERGE は
  > # 同じキーの並行 insert を待たず、敗者が一意制約で落ちる。
  > ```
   150|  >
  > フレームワークの抽象を使わない判断に、バージョンと具体的な失敗モードが添えてある。`updated_at` を「高い値で上書きしたときだけ前進させる」のも細かいが正しい（低い後着で更新時刻が動かない）。
  >
  > テストは本当に別接続を 3 本張って競わせている。共有 Sandbox なら直列化されて意味が無い、という点を認識したうえで `sandbox: false` で checkout し、`pg_backend_pid` が 3 つ異なることまで assert する。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/trading/daily_equity_peak_upsert_test.exs L22-27
  > backend_pids = Enum.map(results, fn {_result, backend_pid} -> backend_pid end)
  > assert length(Enum.uniq(backend_pids)) == length(peaks)
  > ...
   160|  > assert Decimal.eq?(row.peak, Decimal.new("150000"))
  > ```
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`, `apps/bitflyer/test/bitflyer/trading/daily_equity_peak_upsert_test.exs`

- **成行の残高拘束が `best_ask × size` になり、拘束しきれない部分を moduledoc が明示する** `+2`
  > 前回 `-1` だった「板は取れているのに LTP で拘束する」が閉じた。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L825-829
  > defp base_unit_price(:live, :buy, :market, _price, command, opts) do
  >   case fetch_bid_ask(command, opts) do
   170|  >     {:ok, _bid, ask} -> {:ok, ask}
  > ```
  >
  > 良いのは、直したうえで**まだ拘束できない分を書いている**ことである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L38-41
  > live 成行買いの拘束は `best_ask × size` ちょうど（LTP だと薄いスプレッドで過小）。
  > ticker に気配数量が無いので、最上段を超えて歩いた平均は ask を超えうる。
  > その超過は拘束せず、部分約定の解放はサイズ比のまま残る。
  > ```
   180|  >
  > paper は LTP に `FillPricing` の不利化だけを載せ、ask を重ねない（risk.ex L836-845, L849-855）。二重に不利化しない、という分岐の理由も書いてある。板欠落は `bid_ask_missing` で fail-closed（L830-833）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

### market-data

- **ticker を `{ltp, book}` の 2 層に分け、板異常と配信停止を切り分けられるようにした** `+3`
  > 前回 `-1` だった「板が crossed / ゼロだと ticker ごと破棄し、板異常が鮮度切れに化ける」を、提案どおりの 2 層化で閉じた。
  >
  > `cast_book/2` は無効な板で `nil` を返すだけで、LTP は Cache に載る（normalize.ex L43-50, L243-251）。層を導入したあとの読み取り規律が徹底されている。
  >
    190|  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/normalize.ex L130-136
  > def book(%{book: nil}), do: :miss
  > def book(%{book: book}) when is_map(book), do: book_quotes(book)
  > ...
  > def book(%{best_bid: bid, best_ask: ask}), do: valid_book(bid, ask)
  > ```
  >
  > `book` キーがあるときは平坦な `best_bid` / `best_ask` へ**落ちない**。`source_timestamp/1` も同じで、LTP 層があればその時刻だけを見る（L146-158）。移行前の手書き値との互換を残しつつ、層がある値では曖昧さを作らない、という細かいが重要な判断である。
  >
  > 切り分け先も用意されている。`/health/ready` は LTP 鮮度で判定して 200 のまま、JSON の `book` / `all_books` で板欠落を出す（health.ex L14-17, L174-191）。成行の拒否は `bid_ask_missing`（risk.ex L592-595）。overview L158 の「配信停止と混ぜない」という記述が、コード 3 箇所で実際に守られている。
   200|  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/health.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### 診断タスク / 運用

- **Game Day Stage 2 が永続停止を消さず、停止中は監督木すら起動しない** `+4`
  > 前回 `-2` を付けた「診断タスクがグローバル停止状態を無条件に解除する」を、指摘より広く直している。
  >
  > 第一に、`app.start` の**前に** Repo だけを起こして `RiskState` を読む。
  >
  > ```elixir
  > # apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex L67-75
  > # 停止中に Feed まで上げない。Repo だけで読み、clear のときだけ監督木を起動する。
  > case with_repo(read_halt) do
   210|  >   :ok ->
  >     start.()
  > ```
  >
  > halted なら理由を出して終了し、読めなければ `:unsynced` としてやはり中断する（L122-139）。`halted_at` は触らない、とエラーメッセージ自身が宣言している（L125）。
  >
  > 第二に、この BEAM だけ起動副作用を外す。`disarm_startup!/0` が `Reconciler` の `boot?` を false、`CircuitSync` を `:disabled`、`OpenOrderPolicy` の `cancel_on_halt` を空に置き換え、`after` で必ず戻す（L161-201）。常駐側の設定は触らない。
  >
  > 第三に、Ready の作り方が変わった。前回は `Readiness.mark_ready()` を 3 段で押し通していたが、いまは `Reconciler.run_now/0` が `:ok` を返し、かつ `Readiness` が `:ready` のときだけ通す。
  >
   220|  > ```elixir
  > # apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex L228-238
  > def require_ready_via_reconcile do
  >   case Reconciler.run_now() do
  >     :ok ->
  >       case Readiness.get() do
  >         :ready -> :ok
  >         other -> {:error, {:not_ready, other}}
  > ```
  >
  > さらに各発注段の前に `order_gate/0` が**永続停止を読み直す**（L244-259）。CircuitSync を止めているので、別 BEAM が共有 DB を halt してもここで止まる。テストがこの 3 点を個別に固定している（game_day_stage2_test.exs L53-74 / L77-100 / L128-137）。
   230|  >
  > 「診断ドリルが安全装置を壊してはいけない」という原則を、中断・無効化・再読の 3 段で実装しきっている。1 サイクルでここまで直した例は少ない。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `apps/bitflyer/test/bitflyer/game_day_stage2_test.exs`

### datastore / Ash

- **Ash を永続状態に限定し、判定ループは ETS のまま保たれている（維持）** `+3`
  > overview L97 の「ホットパスから Resource を呼ばない」が、実装が厚くなった今も守られている。
  >
  > `Risk.authorize/2` の moduledoc が方針を明示し（risk.ex L27-32）、実際に頻度は `OrderRate`、連続エラーは `FailureRate`、日次損失と HWM は `DailyLoss`、残高は `BalanceCache` の ETS を読む。今サイクルで追加された HWM の永続化も、認可からは `PeakWriter` への cast 相当に留めた（risk.ex L30-32）。
  >
  > 書き込み側は必要な強度を取っている。`Positions.find_position/2` は `Ash.Query.lock(:for_update)` で既存建玉を押さえ（positions.ex L138-142）、`LiveBalance.persist_changed/2` は `pg_advisory_xact_lock` で tip 前進を直列化する（live_balance.ex L566-576）。
   240|  >
  > Decimal 徹底も維持されている。`Risk` 内で float を受けるのは `to_decimal/1` の 1 節だけで（risk.ex L1019）、`LiveBalance.parse_decimal/1` は未知型を 0（許容なし）へ倒し、float を意図的に受けない（live_balance.ex L399-404）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **live 実発注が「設定 1 つ」では絶対に起きない多段ゲート（維持）** `+4`
  > `config/runtime.exs` を読み直して、ゲートが 6 段あることを再確認した。
  >
   250|  > 1. `TRADE_MODE` は allowlist。不正値は `ArgumentError` で起動停止（L83-98）
  > 2. `BITFLYER_LIVE_CONFIRM` が **UTC 当日の `YYYY-MM-DD`** と一致しないと `live_confirmed: false`（L100-108）。昨日の値を残しても通らない
  > 3. live かつキー両方ありのときだけ `exchange_client` を `Rest` に差す。欠ければ `Unavailable` のまま（L128-134, L150-153）
  > 4. `LiveSafety.apply_live_overrides!/3` が Strategy を既定無効にし、`FixedOnce` の有効化を拒否し、Risk 上限 7 本を環境変数必須にする（L156-169, live_safety.ex L26-44, L143-148）
  > 5. `require_max_open_age_ms!/1` が `BITFLYER_MAX_OPEN_AGE_MS` を必須にし、7 日を超える値も拒否する（live_safety.ex L112-134）。GTC 無期限を防ぐ
  > 6. `assert_live_products!/1` が spot 以外を起動停止（live_safety.ex L49-75）
  >
  > そのうえ `BITFLYER_WS_URL` の上書きは live で起動停止になる（runtime.exs L179-195 と `Config.WsUrl`）。「live へ切り替える操作は設定上で目立たせる」（overview L104）が、目立たせるどころか**うっかりでは到達できない**ところまで作り込まれている。開発既定は `dry_run`（runtime.exs L80、compose.yaml L39、compose.prod.yaml L73 すべて）。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

   260|- **開発と本番の Compose / Dockerfile が完全に分かれ、本番は非 root release + tini + loopback bind（維持）** `+3`
  > `Dockerfile.prod` は multi-stage で、runner 段に uid/gid 1000 の `app` ユーザーを `--shell /usr/sbin/nologin` で作り、release を `--chown=app:app` で配って `USER app` に落とす（L55-67）。PID 1 は `tini` で、ゾンビ回収とシグナル転送を任せている（L78-79）。開発 `Dockerfile` は 20 行で、ソースを焼かず bind mount 前提（L1）。
  >
  > `compose.prod.yaml` 側も詰まっている。`db` は `ports` ではなく `expose` だけ（L20-22）。アプリのホスト公開は既定 loopback（L57-59）で、`PHX_HTTP_IP` は allowlist 検証つき（runtime.exs L370-397）。`stop_grace_period: 45s` は「子 5s × 複数 + Repo」という予算から来ており（L60-61、config.exs L109-111 と対応）、healthcheck は `/health/live` を見るので WS 断でコンテナを再起動しない（L96-101、overview L145 と一致）。必須シークレットは `${VAR:?...}` で欠落時に起動を止める（L25, L68-69, L79-80）。
  > 対象ファイル: `Dockerfile.prod`, `Dockerfile`, `compose.prod.yaml`, `config/runtime.exs`

### CI / CD

- **ローカルと CI が同一の `mix precommit`、Actions は SHA ピン、audit と本番ビルドを分離（維持）** `+3`
  > `precommit` は 5 本で、うち 2 本が drift 検出に向いている。
  >
   270|  > ```elixir
  > # mix.exs L47-55
  > precommit: [
  >   "deps.unlock --check-unused",
  >   "format --check-formatted",
  >   "compile --warnings-as-errors",
  >   "ash.codegen --check --domains Bitflyer.Trading",
  >   "test --warnings-as-errors"
  > ]
  > ```
   280|  >
  > `test --warnings-as-errors` を別に付けているのは、`test/` が `compile` の対象外だからという理由がコメントにある（L53）。
  >
  > `ci.yml` は同じ `mix precommit` を 1 ステップで呼び（L71-72）、Actions は全部 commit SHA ピン（L45, L49, L55 など）。`deps.audit` は別ジョブで、ツール障害と advisory 検出を `bin/classify-deps-audit.sh` で分けて artifact に残す（L108-132）。`Dockerfile.prod` の push なしビルドまで PR で回す（L137-154）。本番シークレットは置かない方針が `ci-cd.md` L78-83 に書いてある。個人プロジェクトの CI としては上位である。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`, `bin/classify-deps-audit.sh`

---

## 横断評価層

### テスト戦略

   290|- **ハーネスに売り手数料の 2 モデルを持たせ、誤モデルが縦回帰で halt することを固定した** `+3`
  > 前回 `-1` だった「ハーネスが本番と同じ式を実装していて反証になっていない」を、提案どおりのスイッチで閉じた。
  >
  > ```elixir
  > # apps/bitflyer/test/support/live_exchange_harness.ex L127-132
  > 売り約定の残高モデル。既定は `:base_deduct`。
  > `:quote_mark` は手数料を quote の受取から引く旧仮説で、縦回帰の反証に使う。
  > @spec set_sell_fee_model(:base_deduct | :quote_mark) :: :ok | {:error, :open_orders}
  > ```
  >
  > 重要なのは、スイッチを足しただけでなく**誤モデルの帰結を縦経路で通して固定した**ことである。
   300|  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs L404-409
  > assert {:error, :reconcile_mismatch, %{kind: :balance_mismatch}} =
  >          Bitflyer.Startup.Reconcile.run(trade_mode: :live, exchange: LiveExchangeHarness)
  > assert {:error, :reconcile_mismatch} = Reconciler.run_now()
  > assert Readiness.get() == {:halted, :reconcile_mismatch}
  > ```
  >
  > 発注 → 約定同期 → `Reconciler.run_now` まで実際に通し、halt に落ちることを確認している。これで「内部式を `:quote_mark` に戻すと、この halt 期待か実測 explain の少なくとも片方が失敗する」という双方向の拘束が成立する。`:open_orders` があるあいだはモデル切替を拒む（L375）という細部も、途中で式が変わって整合が壊れないようにするためで、丁寧である。
   310|  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`, `apps/bitflyer/test/bitflyer/regression/live_balance_advance_test.exs`

- **705 本のテストが発注経路・冪等・モード分岐・突合・サーキット・鮮度を覆う（維持）** `+3`
  > `apps/bitflyer/test` と `apps/ui/test` の `test` / `property` 宣言を数えると 705 件（今サイクルで約 +80）。テストファイルは 60 本超で、モジュール構成と 1 対 1 に近い。
  >
  > 資金保全の回帰が独立したディレクトリにあるのが良い。`test/bitflyer/regression/` の 3 本（`capital_preservation_test` / `commission_unit_guard_test` / `live_balance_advance_test`）は、どれも「壊れたら資金に触る」性質のものだけを集めている。今サイクルで `live_balance_advance_test` は +236 行、`risk_test` は +240 行増えた。
  >
  > 副作用ゼロの担保もある。両 `test_helper.exs` が `Sandbox.mode(Bitflyer.Repo, :manual)`、`runtime.exs` は test 環境で API キーと BasicAuth を強制的に空／オフにして `.env` の漏れを断つ（L136-144, L296-299）。テスト注入は `Bitflyer.Risk` の `allow_test_injections` で守られ、本番経路では注入が**黙って無視されて正本が使われる**（risk.ex L610-613, L927-929）。注入で迂回できない、という設計は珍しい。
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/risk.ex`
   320|
### 可観測性

- **telemetry メタデータの allowlist と、発注経路から独立した Discord アダプタ（維持）** `+3`
  > `Bitflyer.Telemetry` が語彙の正本で、イベント名を先に固定し、リネームを避けるという方針まで moduledoc に書いてある（telemetry.ex L2-9）。メタデータは allowlist のみ通り、`execute/3` / `log/3` / `put_logger_metadata/1` の 3 経路すべてが `sanitize_metadata/1` を通る（L100-124）。「秘密キーを allowlist に入れないこと」という運用注意も同じ場所にある。`config.exs` の Logger metadata（L176-208）も同じ語彙で揃っている。
  >
  > Discord は overview L61 の方針どおり第 3 アプリではなくアダプタで、`Bitflyer.Observe.Discord` は `Application` の子として**発注経路の兄弟**に置かれている（application.ex L39-40）。HTTP は Task で、未設定・送信失敗でも取引は止まらない。`redact_reason/1` が失敗理由から URL を落とす（game_day_stage2.ex L397 の利用）。Webhook URL がログにも通知本文にも出ない、という overview L168 の要件が実装で担保されている。
  >
  > 板欠落と配信停止を分けるための出力も今サイクルで増えた（health.ex L174-191 の `book` / `all_books`、telemetry の `detail`）。理由が「後から説明できる」方向に一貫して足されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `config/config.exs`

   330|### プロジェクト全体設計・プロセス

- **improvement-plan の「完了」に観測 1 行を必須化し、消化済み全件へ遡って付けた** `+2`
  > 前回 `-2` を付けた「完了条件を満たさない項目を取り消し線で消している」を、ルール化で閉じた。
  >
  > ```
  > # .workspace/0_doc/evaluation/improvement-plan.md L7
  > 「完了」と書くときは、右列「完了の見方」を満たした根拠を 1 行必須にする。
  > 根拠は日付と、見方が真だと分かる観測（テスト名、証跡の差分、実行結果）を含む。
  > 「コード再読」だけでは根拠にしない。満たせない項目は取り消し線にせず **部分完了** と残す。
  > ```
  >
   340|  > 同じ規律が `.cursor/rules/evaluation.mdc` L299-307 に評価手順として入り、次回評価が矛盾を落とすところまで手続き化されている。
  >
  > 加点の実体は、**遡って全件に観測を付けたこと**である。消化済み表の 11 件すべてに、テスト名か実測差分か具体的な挙動が 1 行ずつ入っている（improvement-plan.md L17-30）。今回その全件をコード・テスト・証跡で読み直したが、見方と矛盾する「完了」は 1 件も見つからなかった。P1 #3 と P2 #10 は自ら部分完了に留め、残差を同じ行に書いている。
  >
  > 前回「次サイクルの評価者が『完了』を信用できなくなる」と書いた状態から、1 サイクルで信用が戻った。`+2` は実装ではなくこのプロセス転換に対するものである。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.cursor/rules/evaluation.mdc`

---

## 小計
   350|

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer — order-executor / 手数料会計 | +8 |
| apps/bitflyer — risk-manager | +13 |
| apps/bitflyer — market-data | +3 |
| apps/bitflyer — 診断タスク / 運用 | +4 |
| apps/bitflyer — datastore / Ash | +3 |
| 実行基盤 / 設定 | +7 |
| CI / CD | +3 |
   360|| 横断（テスト戦略） | +6 |
| 横断（可観測性） | +3 |
| 横断（プロジェクト全体設計・プロセス） | +2 |
| **合計** | **+52** |
