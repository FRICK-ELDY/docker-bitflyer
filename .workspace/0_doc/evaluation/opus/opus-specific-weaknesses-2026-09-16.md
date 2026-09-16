# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-16

対象コミット: `a387746`（`Merge pull request #112 from FRICK-ELDY/chore/p2-9-minor-debt-triad`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-13](./archive/2026-09-13/opus-specific-weaknesses-2026-09-13.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。
`mix precommit` は本評価では**未実行（省略）**。テスト結果に依拠した判定は含めていない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -16 点**

前回の -15 から 1 点悪化した。ただし内訳は大きく入れ替わっている。前回 13 件のうち **7 件（-9 点分）は解決を確認した**（HWM flush・突合窓の対称化・残高判定のねじれ・spread ゲート・`ash.codegen --check`・Sandbox mode・`README.md`）。1 件（保持方針）は再読の結果、減点から提案へ移した。

悪化の実体は **P0 #1/#2 を「完了」と宣言したことの妥当性** に集中している。実装の質は高いのに、根拠が推定で、反証テストが自モデルと同じ前提を共有している。加えて今サイクルで新設した診断タスクが**グローバル停止状態を消す**という新規の穴を持ち込んだ。

---

## 技術評価層 — apps/bitflyer

### order-executor / 手数料会計

- **commission 単位が推定のまま「完了」と宣言されており、売り側の会計は誰も検証していない** `-2`
  > 本サイクルで最も重い指摘である。実装の一貫性は高い（strengths で `+4`）。問題は**根拠の質**と、improvement-plan が自分で書いた完了条件との乖離である。
  >
  > 証跡は次の 3 つを自ら認めている。
  >
  > ```
  > # .workspace/0_doc/architecture/env/commission-unit-evidence.md L9-11, L25-26
  > API レスポンス自体は単位フィールドを持たない。
  > ...
  > 実口座の非ゼロ getexecutions は鍵が要るため本リポジトリには置かない。
  > 単位確定は上記公式に依拠し、会計モデルは fixture で固定する。
  > ```
  >
  > 引用されている公式記載は「単位: 各通貨ペアで異なります / Unit varies by Crypto Assets」であり、これは **BTC_JPY が BTC であることを述べていない**。BTC という結論は「かんたん取引所 BTC の Unit: BTC」からの類推である。improvement-plan P0 #1 の完了の見方は「**実応答（または公式が単位を明記した fixture）で口座 BTC/JPY の変化と内部 expected が許容幅で一致する**」だが、実応答も単位明記の公式 fixture も存在しない。したがって P0 #1 は自分の基準では完了していない。
  >
  > さらに重いのは**売り側モデル**である。証跡の会計表は売りを `JPY: +S·P − C·P` / `BTC: −S` とする。つまり BTC 建てで課された手数料を **JPY 換算して受取代金から引く**。コードもそのとおりで、
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/live_balance.ex L290-303
  > :sell when currency == base ->
  >   Decimal.negate(size)          # ← base は size だけ。fee を引かない
  >
  > :sell when currency == quote ->
  >   cond do
  >     fee_ccy == base -> Decimal.sub(notional, Decimal.mult(fee, fill.price))
  > ```
  >
  > `Positions.held_size/5` も売りでは `size` をそのまま返す（positions.ex L338）。**「BTC 建ての手数料は BTC 残高から引かれる（base: `−S − C`）」という少なくとも同程度にありそうな挙動**は、どこでも検討・記録されていない。もし現実がそちらなら、live の初回売り直後の突合で BTC は expected より `C` 少なく（許容は 1 satoshi の絶対床なので確実に超過）、JPY は expected より `C·P` 多い（増加＝入金として `fee_explained?` が即 false）。両通貨とも `balance_mismatch` になる。`cancel_on_halt` は `reconcile_mismatch` で `false`（config.exs L44）なので未約定は板に残り、復帰には人が Status の Resume を押す必要がある。
  >
  > 資金は失われない（fail-closed）。しかし「人が張り付かなくても資金を守れる」という Vision の要件に対して、**初回売りで確実に人を呼ぶ設計が、確率 5 割の推定に乗っている**。
  >
  > 改善方針: 3 択。(a) 最小ロットの買い 1 回 → `getexecutions` の `commission` と直前直後の `getbalance` 差分を証跡に貼り、売りはその記録が取れてから解禁する（Stage 3 を 3a/3b に割る）。(b) 売り側の fee 帰属を base 控除 / quote mark の**両方許容**にし、初回約定で観測された側へ確定して証跡に書く（`fee_side` を Fill か設定に持つ）。(c) 直さないなら improvement-plan の P0 #1 を `部分完了（買い側のみ検証済み）` に戻し、live 解禁条件に「初回売りは手動監視下」を明記する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

### risk-manager

- **成行の残高拘束が LTP 基準のままで、せっかく取った `best_ask` / `best_bid` を使っていない** `-1`
  > 今サイクルで bid/ask が Cache に載ったが、拘束額の計算は LTP のままである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L793-800
  > defp base_unit_price(_order_type, _price, command, opts) do
  >   case fetch_ltp(command, opts) do
  >     {:ok, ltp} -> {:ok, ltp}
  > ```
  >
  > `paper_unit_price/4` は paper の買いだけ不利化するので（L804-810）、**live の成行買いは `ltp × size` で probe / reserve する**。実際に支払うのは最良 ask 以上であり、`max_spread_pct: 0.5%` を通る板でも mid から片側 0.25% ぶん過小に拘束しうる。結果は 2 つ。(1) probe を通ったのに `reserve` が `:insufficient_balance` になる（Runner のバックオフに落ちる）。(2) 残高ギリギリで発注したとき、拘束が実効コストに足りずキャッシュ上の available が実残高より甘くなる。
  >
  > 金額としては小さいが、これは**入力が揃っているのに使っていない**類の負債である。`quote_notional` の成行分岐で買いは `best_ask`、売りの base 拘束は size のまま（売りは数量拘束なので影響なし）にするだけで閉じる。paper で LTP を使い続けたいなら `trade_mode` で分ければよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **ETS で上がった peak の flush 点火が mark price に依存しており、Feed が荒れた直後の再起動で HWM が戻る** `-1`
  > P1 #3 の実装は正しく入っている（strengths `+3`）。残るのは点火条件である。flush は `Equity.enforce/1` の中の `record_peak` からしか起きないが、`Equity.snapshot/1` は建玉がある状態で mark（ticker LTP）が stale だと `{:error, :stale, %{reason: :mark_price_unavailable}}` で先に落ちる（equity.ex L251-254）。`resolve_peak/4` はそこまで到達しない。
  >
  > つまり「認可で ETS peak が上がる → Feed が切れる / stale になる → その状態でプロセスが落ちる」の順で、**その peak は DB に残らない**。復帰後のドローダウンは一段低い過去 peak から測り直される。前回の `-2`（常に flush されない）からは大幅に縮んだが、残った窓は**相場が急変して Feed が不安定になった直後**という、ドローダウン保護が最も要る局面と重なる。
  >
  > 改善方針: 認可経路で ETS peak を上げた時点を記録し、mark に依存しない軽い flush 点（例: `Reconciler` の周期で `record_peak` 相当の flush のみを試す、または `prepare_peak` が `{:flush, ...}` を返したら `Equity` を経由せず `DailyEquityPeak.upsert/3` を直接呼ぶ）を 1 本足す。HWM の永続化は mark を必要としない（ETS の値をそのまま書くだけ）ので、依存を切れる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/equity.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **`DailyEquityPeak` の一意制約衝突検出が `inspect(error)` の文字列一致に依存している（前回から未解決）** `-1`
  > 前回と同じ実装のままである（今サイクルの diff は 3 行）。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex L142-145
  > defp unique_mode_day_taken?(error) do
  >   unique_mode_day_name?(inspect(error)) or
  >     error |> error_leaves() |> Enum.any?(&identity_collision?/1)
  > end
  > ```
  >
  > 構造マッチが 5 パターン（`:identity` / `vars.key` / `constraint` / `postgres.constraint` / `private_vars`）並んだうえでの保険なので今すぐ壊れるわけではないが、`inspect/1` は契約のない文字列であり、`Exception.message(other)` を `rescue _ -> false` で包む最終節も広すぎる（L167-172）。外れたときの挙動は `create_peak` が `{:error, _}` を返し → `peak_persist_failed` → 当該モード unsynced → `authorize` が `daily_loss_unsynced` で全拒否。fail-closed だが、**並行 Fill と周期 enforce が重なっただけで取引が止まる**経路が毎回 `record_peak` を通る。
  >
  > 改善方針: `Ash.Changeset.for_create(..., upsert?: true, upsert_identity: :unique_mode_day)` か AshPostgres の `ON CONFLICT ... DO UPDATE SET peak = GREATEST(excluded.peak, daily_equity_peaks.peak)` に寄せ、read → create → rescue → 条件付き update の 4 段を 1 文に畳む。HWM は単調増加なので `GREATEST` で意味論が完全に表現できる。`Circuit` が既に `upsert_identity: :unique_name` を使っているので（circuit.ex L155-156）、同じ書き方がリポジトリ内にある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

### market-data

- **板が crossed / ゼロのとき ticker を丸ごと破棄するため、板異常が「鮮度切れ」に化ける** `-1`
  > spread ゲートを入れるにあたり、`Normalize.from_ticker/1` は bid/ask 欠落・ゼロ・負・crossed で `:error` を返す（normalize.ex L32-37）。fail-closed の方向は正しい。副作用は 2 つある。
  >
  > (1) **失敗ドメインの統合**。bid/ask が一瞬でも壊れると `ltp` も Cache に載らない。停止理由は「板が壊れている」ではなく `stale_market_data`（あるいは `feed_disconnected`）として記録され、`/health/ready` は 503 になる。運用者は「配信が止まった」と読むが、実際は「値は来ているが板が異常」である。overview の Observable（切断・拒否の理由が残る）に対して、**原因の切り分けが停止理由から読めない**。
  >
  > (2) **Ready 化への波及**。live 突合の時計検査は `Normalize.from_ticker/1` を通す（reconcile.ex L254-259）。板が片側／ゼロの瞬間に突合が走ると `invalid_exchange_payload` で Ready にならない。BTC_JPY で常時起きるものではないが、Vision の「止めないこと」に対して**今サイクルで新しく作った結合**である。
  >
  > 改善方針: 値を `{ltp, book}` の 2 層に分け、板側だけ欠落を許す（`best_bid`/`best_ask` が nil の値も Cache に載せる）。`Risk.check_spread/3` は現状どおり nil を `:stale`（reason は `bid_ask_missing` で既に区別されている、risk.ex L572-575）で拒否すればよく、`ltp` を使う `check_freshness` / `check_price_deviation` / `Equity` の mark は生き残る。時計検査も `ltp` だけで足りる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **常時接続の中核が `websockex` 0.4 に載ったままで、その事実がどこにも記録されていない（6 サイクル連続）** `-1`
  > `apps/bitflyer/mix.exs` L38 の `{:websockex, "~> 0.4"}` は不変。リポジトリ全体（`deps` / `_build` / 評価文書を除く）を検索して当たるのは `mix.exs` 1 行と `socket.ex` の 5 行だけで、`.workspace/0_doc/architecture/` に `websockex` の記述は**依然ゼロ**である。`socket.ex` の moduledoc も 1 行（L3）のまま。
  >
  > コード側の設計はむしろ良い。`handle_disconnect/2` は自動再接続せず Feed に委ね（socket.ex L49-59）、`Socket.Client` behaviour で差し替え可能になっている。だからこそ**移行コストは既に低い**のに、「最終リリースは 2019 年、OTP 27 の TLS 既定変更への追随は保証されない」「`mix deps.audit` は Hex advisory しか見ないのでこの種の負債は CI に出ない」という 2 行が 6 サイクル残らない。
  >
  > 改善方針: `ci-cd.md` の「CI / CD が保証しないこと」に 1 行、`socket.ex` の moduledoc に既知リスクとして 1 行。移行するなら `Mint.WebSocket` + 自前 GenServer か `Fresh` へ behaviour 実装を差し替える。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `.workspace/0_doc/architecture/ci-cd.md`

### strategy

- **戦略が `FixedOnce` 1 本だけで、縦経路の「判定」がダミーのまま** `-1`
  > `apps/bitflyer/lib/bitflyer/strategy/` は `runner.ex` / `fixed_once.ex` / `revision.ex` の 3 本で、シグナル生成の実体は固定 1 回発注のみ。Vision が戦略の中身を後続バックログに送っているので方針違反ではない。
  >
  > ただし「起動 → 購読 → 判定 → リスク → 発注 → 突合 → 停止/再開」のうち**判定だけが配管疎通用のダミー**であり、`LiveSafety` は live で `FixedOnce` を禁止する（live_safety.ex L93-99）。つまり **live で有効化できる戦略が現時点で 1 本も無い**。live 解禁を議論している段階で、解禁しても動かせる戦略が無いという状態は、取引完成度として計上すべきである。安全側の土台は十分厚いので、明示的なエントリ / エグジット条件を持つ薄い戦略 1 本を通せば、この減点は加点に反転しうる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **開発コンテナが root で実行される（6 サイクル連続）** `-1`
  > 開発 `Dockerfile` は全 20 行で `USER` 指定なし。bind mount した `/app` 配下に root 所有の生成物が生まれる（`priv/static/assets`、`priv/contract/corpus`）。`Dockerfile.prod` は非 root 化し `--chown=app:app` まで付けているので方針は理解されている。開発側だけが 6 サイクル取り残されている。
  >
  > 改善方針: 開発 `Dockerfile` に uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる（`bin/docker-entrypoint.sh` で `chown` するか compose に `user: "1000:1000"`）。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

---

## 横断評価層

### テスト戦略

- **ハーネスが本番実装と同じ手数料モデルを実装しており、縦回帰と「反証」テストが反証になっていない** `-1`
  > `LiveExchangeHarness.apply_execution_balances/3` は本番と同一の式である。
  >
  > ```elixir
  > # apps/bitflyer/test/support/live_exchange_harness.ex L230-236（売り）
  > credited =
  >   if fee_ccy == base do
  >     Decimal.sub(notional, Decimal.mult(fee, exec.price))
  >   else
  >     Decimal.sub(notional, fee)
  >   end
  > ```
  >
  > `LiveBalance.fill_delta/2` の売り分岐（live_balance.ex L293-303）と同じ式であり、base 側も同じく `−size`（L240）。したがって `live_balance_advance_test` が緑であることは**内部整合の証明にとどまる**。
  >
  > `commission_unit_guard_test` も同型で、固定できているのは「`fee_currency` を JPY に決め打つと mismatch」「旧 quote 残高だと mismatch」という**自モデルからの逸脱**だけである。improvement-plan P0 #2 の完了の見方は「fixture だけで『JPY 決め打ち』を再現・防止できる」なので、その字面は満たしている。しかし P0 #2 の目的が「反証回帰」である以上、**自モデルが誤っている場合に全テストが緑のまま live で halt する**構造は目的を満たしていない。
  >
  > 改善方針: 取引所側の挙動はモックでは決められないので、境界を「観測して記録する」側に移す。ハーネスに `fee_side: :base | :quote_mark` のスイッチを持たせ、**両方のモデルで縦回帰を回す**（どちらでも halt しないか、少なくとも halt の kind が予測どおりか）。そのうえで実観測で片方に確定する。
  > 対象ファイル: `apps/bitflyer/test/support/live_exchange_harness.ex`, `apps/bitflyer/test/bitflyer/regression/commission_unit_guard_test.exs`

### 可観測性

- **別ホスト監視が実配備されておらず、live 解禁の最後の出口条件が未達（2 サイクル連続）** `-2`
  > 道具（`bin/watch-ready.ps1` / `register-watch-ready-task.ps1`）とドリル記録は前回時点で揃っている。今サイクルで変わったものは無く、証跡は 2026-09-13 のまま自ら未達を書いている。
  >
  > ```
  > # .workspace/0_doc/architecture/env/watch-ready-evidence.md L29, L74-75
  > | 常駐登録 | 未登録（bin/register-watch-ready-task.ps1 は手順のみ。取引ホストでは動かさない） |
  > ...
  > ## まだ閉じないこと
  > - VLAN1 本番 PC を READY_URL にした常駐は未登録（この記録の対象は開発 Compose）
  > ```
  >
  > improvement-plan 自身が「**残る live 解禁前の出口条件は P1 #5（監視配備）のみ**」と書いている項目である。現状で検知できるのは「アプリが 500 を返す」「ポートが死んだ」までで、**ホストごと落ちた場合（Windows Update の再起動、WSL2 のハング）は誰も気付かない**。Discord 心拍はアプリ内から出るので、アプリが死ぬと沈黙するだけで「静か」と区別がつかない。Vision L119-122 が本番 PC の予期しない再起動をリスクとして明記している以上、これは 24/365 の価値命題に直結する。前回は `-1` としたが、**live 解禁の単一残条件になったことで相対的な重みが上がった**ため `-2` に引き上げる。
  >
  > 改善方針: VLAN1 本番 PC を `READY_URL` にして作業用 PC1 で `register-watch-ready-task.ps1` を実行し、証跡に「本番向き常駐」の行を足す。1 回の作業で閉じる。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`

### 変更容易性・保守性

- **Game Day 診断タスクが `RiskState` と `Readiness` のグローバル状態を書き換え、live の停止理由を消しうる** `-2`
  > 今サイクルの新規である。`mix bitflyer.game_day_stage2` は `ensure_paper_mode!` で paper 限定にしているが（game_day_stage2.ex L78-89）、その内部で**モードに紐づかないグローバル状態**を 4 回書き換える。
  >
  > ```elixir
  > # apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex L98, L122-123, L134-135, L167-168
  > _ = Risk.clear_circuit()
  > ...
  > _ = Risk.clear_circuit()
  > :ok = Readiness.mark_ready()
  > ```
  >
  > `RiskState` は `name == "default"` の**単一行**で、`trade_mode` を持たない（circuit.ex L16, L39, L118, L130-144）。`Reconcile.restore/1` もこの 1 行を読む（reconcile.ex L662-668）。したがって paper でこのタスクを走らせると、**live 側が付けた `manual_halt` / `daily_loss_exceeded` / `reconcile_mismatch` の停止理由が消える**。`CircuitSync` は DB→ETS 方向に同期する設計なので、消えた停止理由は次回起動で「停止していない」として復帰する。開発機と本番で DB を分けている限り事故にはならないが、**停止理由の永続化という最も重い安全装置を、診断タスクが無条件に解除できる**という構造そのものが危うい。
  >
  > 副作用はもう一段ある。`Readiness.mark_ready()` を直接押すため、このドリルは **本番の Ready 遷移（reconcile 成功による Ready 化）を証明していない**。seed 段では「refusing mark_ready push-through」と正しく拒否しているのに（L107-111）、以後 3 段は押し通している。証明できているのは `Risk.authorize/2` の Feed ゲートが `feed_disconnected` を返すことまでで、[game-day.md](../../architecture/env/game-day.md) の「復帰: Feed 子を公式 URL に戻し `clear_circuit` + `mark_ready` 後に再認可成功」という記述はその限界を正しく書いている。Stage 3（live 最小ロット）の判断根拠としては弱い。
  >
  > 改善方針: (a) タスク開始時に `RiskState` の現在値を読み、`halted: true` なら**理由を表示して中断**する（消さない）。(b) `mark_ready` の代わりに `Reconciler.run_now()` の結果で Ready になることを要求し、ならなければ失敗として記録する。(c) 併せて `RiskState` に `trade_mode` を持たせるか、`name` をモード別にする案を overview で検討する（グローバル 1 行という設計判断自体が文書に無い）。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

### プロジェクト全体設計・プロセス

- **improvement-plan が自ら定めた「完了の見方」を満たさない項目を取り消し線で消している** `-2`
  > 実装ではなくプロセスとして独立に計上する。前回の `-1`（宣言 3 件に対し消化 0 件）とは逆方向の問題で、**今回は消化しすぎている**。
  >
  > ```
  > # .workspace/0_doc/evaluation/improvement-plan.md L24
  > | 1 | ~~commission 単位の確定と会計~~ | **完了 (2026-09-16)**。証跡 ...
  >     | 実応答（または公式が単位を明記した fixture）で口座 BTC/JPY の変化と内部 expected が許容幅で一致する |
  > ```
  >
  > 完了条件（実応答 or 単位明記 fixture）と証跡（実応答なし・公式は「ペアで異なる」）が同じ表の中で矛盾している。同様に P2 #7 の「認可通過→予約失敗の Tight loop が消える」は probe で近似が縮んだだけで TOCTOU は moduledoc が認めるとおり残る（消えたのは Tight loop でありレースではない）。
  >
  > improvement-plan の運用がこのプロジェクト最大の強みである以上、**判定の精度が落ちることは個別の実装欠陥より波及が大きい**。「完了」と書かれた項目を次サイクルの評価者が信用できなくなると、P0 の宣言そのものの意味が失われる。実際、今回の指示にも「improvement-plan の『完了』は信じずコード確認」と書かれている——それは前回サイクルで信頼が既に目減りしている証拠である。
  >
  > 改善方針: 完了宣言に「**完了条件を満たした根拠**」を 1 行必須にする（`実応答: 2026-09-XX の getexecutions id=...9012 と getbalance 差分が一致`）。書けないものは取り消し線を引かず `部分完了（買い側のみ / 売り側は未検証）` と残す。基準を下げる判断をするなら、完了条件そのものを先に書き換える（「公式記載＋fixture で足りる」と明記する）ほうが誠実である。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer — order-executor / 手数料会計 | -2 |
| apps/bitflyer — risk-manager | -3 |
| apps/bitflyer — market-data | -2 |
| apps/bitflyer — strategy | -1 |
| 実行基盤 / 設定 | -1 |
| 横断（テスト戦略） | -1 |
| 横断（可観測性） | -2 |
| 横断（変更容易性・保守性） | -2 |
| 横断（プロジェクト全体設計・プロセス） | -2 |
| **合計** | **-16** |

---

## 前回マイナス点の解決状況（コード再読で確認）

| 前回の指摘 | 前回 | 状況 | 根拠 |
|:---|:---:|:---|:---|
| 認可 HWM が永続化されず再起動で drawdown が緩む | -2 | **解決**（残差 `-1`） | ETS 行に `persisted_peak`、`prepare_peak` が `{:rise,...}` / `{:flush,...}` / `{:ok,...}` の 3 値（daily_loss.ex L570-581）。`commit_peak` が peak と persisted を別々に max（L585-605）。残るのは mark stale 時の点火依存のみ |
| `DailyEquityPeak` の衝突検出が `inspect` 文字列一致 | -1 | **未解決** | daily_equity_peak.ex L142-145 は不変 |
| 残高の検査と予約が別段（認可通過→予約失敗ループ） | -1 | **解決** | `BalanceCache.probe/4` が `reserve` と同じ `compare_available/3` を通る（balance_cache.ex L345-358）。`Risk` の本番経路は必ず probe（risk.ex L668-688）。Runner に銘柄単位バックオフ（runner.ex L283-309） |
| 突合窓が片側しか再同期されず即 halt | -2 | **解決** | `fill_sync_retries` で fill 再同期 → `restore(:live)` → snapshot 再取得を 1 回（reconcile.ex L329-349）。再試行時に注入 `:fills` を削除 |
| ticker 一本で spread ゲートが無い | -1 | **解決**（副作用 `-1`） | `Normalize` が bid/ask 必須（normalize.ex L32-37）。`Risk.check_spread/3` は成行のみ・mid 基準（risk.ex L549-577）。`max_spread_pct` は live で env 必須（live_safety.ex L22）。板異常が鮮度に化ける点は新規 `-1` |
| `websockex` 0.4 依存の記録なし | -1 | **未解決** | `mix.exs` L38 不変。`architecture/` に記述ゼロ |
| 永続データの保持方針が無く当日集計が全行読み | -1 | **提案へ移動** | `sum_realized/3` は `filled_at` の当日境界で絞る（daily_loss.ex L756-773）。前回「全行読み」と書いたのは不正確で、実際は当日分のみ。行数は日次出来高に比例し無限には育たないため、減点を取り下げて提案（retention + aggregate）に移す |
| `precommit` に `ash.codegen --check` が無い | -1 | **解決** | mix.exs L52。no-op migration と snapshot 4 本も追跡済み（`git ls-files` で確認） |
| 開発コンテナが root | -1 | **未解決** | `Dockerfile` に `USER` なし |
| `test_helper.exs` に Sandbox mode が無い | -1 | **解決** | 両ファイルに `Sandbox.mode(Bitflyer.Repo, :manual)` |
| improvement-plan の「毎サイクル 3 件必ず消す」が 0 件 | -1 | **解決** | P2 #9 の 3 件を消化（strengths `+1`）。ただし別方向の宣言精度問題が発生（本文 `-2`） |
| `apps/bitflyer/README.md` が TODO テンプレ | -1 | **解決** | 責務説明 10 行に置換 |

**解決 7 件（-9 点分）/ 提案へ移動 1 件 / 未解決 3 件（-3 点分）/ 残差付き解決 2 件。**

未解決 3 件のうち 2 件（Dockerfile root、`websockex` の記録）は **6 サイクル連続**である。今サイクルは軽微負債 3 件を宣言どおり消したので、この 2 件は「次で消す」と明記されている残りに含まれる。
