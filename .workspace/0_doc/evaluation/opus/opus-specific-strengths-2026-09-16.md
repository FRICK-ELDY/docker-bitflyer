# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-16

対象コミット: `a387746`（`Merge pull request #112 from FRICK-ELDY/chore/p2-9-minor-debt-triad`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-13](./archive/2026-09-13/opus-specific-strengths-2026-09-13.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。
`mix precommit` は本評価では**未実行（省略）**。compose 経由の再現・`mix deps.audit` も省略した。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +31 点**

前回の指摘のうち、**HWM 非永続（`-2`）・突合窓の非対称（`-2`）・残高判定のねじれ（`-1`）・spread ゲート欠如（`-1`）・軽微負債 3 件（`-3`）** はコード再読で解決を確認した。今サイクルは「穴を塞ぐ」だけでなく、**塞いだ穴の意味論を moduledoc に残す**方向に一貫して振れている。

---

## 技術評価層 — apps/bitflyer

### order-executor / datastore（手数料会計）

- **commission の単位を「銘柄由来の型」として一元化し、建玉・残高・PnL の 3 経路を同じ規約で並べた** `+4`
  > 手数料単位は自動売買が最も静かに壊れる場所である。今サイクルは「どこで単位を決めるか」を 1 関数に閉じ、それを使う側を全部そこへ寄せた。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L85-90
  > def fee_currency(product_code) when is_binary(product_code) do
  >   case market_type(product_code) do
  >     :spot -> base_currency(product_code)
  >     _ -> quote_currency(product_code)
  >   end
  > end
  > ```
  >
  > 効いているのは「単位を決めた」ことではなく、**単位が違うと結果が変わる 3 箇所を同一の分岐で書いた**ことである。
  >
  > 1. 建玉に載る数量は約定数量ではなく **inventory**。買いで base fee なら `size − fee` を載せ、0 以下なら `fee_exceeds_size` で fail-closed（positions.ex L323-336）
  > 2. 反対売買・ドテンの減算も `held` 基準（positions.ex L172-244）。`exec_size` で減らすと fee 分まで消し込む「過多決済」になる旨をコメントで明示している（L158-159）
  > 3. `realized_pnl` は quote 建に mark（`fee_to_quote/4`、L306-321）。`ETH_BTC` のように quote が BTC のときも同じ式で通る
  >
  > `Fill` 側は `fee` を「NULL = 未記録 / 0 = 記録済みの無料」と区別し（fill.ex L114-119）、`fee_currency` が NULL のレガシー行は読取時に `Product.fee_currency/1` で補完する。`LiveBalance.resolve_fee_currency/1` がその補完を実装しており（live_balance.ex L318-328）、`fee_allowance/3` は「fee 未記録の Fill だけ 20bps、記録済みは絶対床のみ」と許容幅を分けている（L330-354）。**移行期の 3 状態（未記録 / 記録あり通貨なし / 完全）を残高説明の許容幅の設計に落としている**のは、個人プロジェクトの水準を明確に超えている。
  >
  > `held_size` を買いにだけ適用して売りは `size` のままにした点（＝売りの fee は quote 受取から mark 控除）は**証跡が無い推定**であり、その一点は weaknesses に `-2` で計上した。会計モデルそのものの作り方は評価に値する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

### risk-manager

- **HWM の flush を `persisted_peak` 1 列と 3 値プロトコルで入れ、ホットパスから Ash を出さない構造を崩さなかった** `+3`
  > 前回 `-2` を付けた「認可で ETS だけ上がったピークが DB に流れない」は閉じた。実装は前回提示した方針そのままで、ETS 行に `persisted_peak` を足し、`prepare_peak` の戻りを 3 値にしている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L570-581
  > new_peak = equity_pnl |> Decimal.max(peak) |> Decimal.max(zero())
  >
  > cond do
  >   Decimal.compare(new_peak, peak) == :gt -> {:reply, {:rise, day, new_peak}, table}
  >   Decimal.compare(peak, persisted) == :gt and Decimal.compare(peak, zero()) == :gt ->
  >     {:reply, {:flush, day, peak}, table}
  >   true -> {:reply, {:ok, peak}, table}
  > end
  > ```
  >
  > 評価したいのは 3 点。
  >
  > (1) `commit_peak` が `peak` と `persisted` を**別々に max** する（L585-605）。Ash 呼び出し中に認可が ETS peak をさらに上げても、それを「flush 済み」に含めない。並行更新の窓を潰しにいっている。
  >
  > (2) `resolve_peaks/5` が同日と日付跨ぎで意味論を分けている（L705-711）。同日は ETS と DB の高い方、跨ぎは当日行だけ。「昨日の ETS を持ち越さない」が明示されている。
  >
  > (3) `DailyEquityPeak.update_peak/2` が無条件 update ではなく `peak < ^peak` の条件付き `bulk_update` である（daily_equity_peak.ex L185-199）。コメントに「150 の直後に 120 が書き戻ると再起動後の drawdown が緩む」と、防いでいる具体的な事故が書かれている。HWM が単調増加であることを DB 述語として表現している。
  >
  > 認可は依然 `persist: false`（risk.ex L640-645）で、DB 往復は Fill 後 / 突合 / resume の `Equity.enforce` に寄せたまま。**穴だけ塞いでホットパスの性質は変えていない**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **残高の「検査」と「予約」が同一比較関数を共有し、公開契約だけ意図的に書き分けられている** `+3`
  > 前回 `-1` を付けた「認可は近似・正本は reserve」のねじれが閉じた。`probe/4` と `reserve/4` は同じ `compare_available/3` を通る。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/balance_cache.ex L345-358
  > def handle_call({:probe, trade_mode, currency, amount}, _from, table) do
  >   case read_mode(table, trade_mode) do
  >     {balances, true, 0, _gen} when map_size(balances) > 0 ->
  >       case compare_available(balances, currency, amount) do
  > ```
  >
  > 単に共通化しただけではない。**同じ比較で戻り値の契約だけ変えている**。`probe` は通貨キー欠落を `{:error, :currency_missing, %{currency: ...}}` で返して観測に出し、`reserve` は同じケースを `:unsynced` に畳む（L388-390、「過大評価しない」とコメント付き）。認可は理由を細かく出したい、予約は安全側に潰したい、という要求の差が型に出ている。
  >
  > `Risk` 側も、テスト注入 `:balances` があるときだけ旧比較に落ちる分岐を残し、本番経路は必ず probe を通す（risk.ex L668-688）。moduledoc に「probe→reserve のあいだに残高が減れば認可通過後に `:insufficient_balance` になりうる（近似）」と TOCTOU の残差まで書いてある（L33-37）。前回「直さないなら少なくとも moduledoc に書け」と述べた内容が、**直したうえで書かれている**。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **fail-closed が「例外的な安全弁」ではなく既定の型として全域に通っている** `+3`
  > 今回もう一度横断して読み、以下がすべて「読めない・説明できない → 発注しない」に倒れていることを確認した。
  >
  > - `DailyLoss` の barrier / generation。`force: true` でも in-flight barrier を無視しない（daily_loss.ex L625-628 の `apply_one` が force を false に潰す）。Fill 記帳中の Ready 化を構造的に防ぐ
  > - `BalanceCache.reapply_holds!/2`。絶対残高 put のあとに未決済 hold を再減額し、足りなければ unsynced（balance_cache.ex L632-664）。tip の上書きで拘束が消えない
  > - `Equity` の stale 方針を**呼び出し元ごとに分けている**（equity.ex L19-28）。`authorize` / `Resume` は mark 欠落で fail-closed、周期 `enforce` は halt しない。「切断だけで永続 halt にしない」判断が moduledoc に理由付きで残っている
  > - `Risk.check_source_timestamp/3` は `source_timestamp` 欠落を常に `clock_skew`（risk.ex L424-427）
  > - `Positions.normalize_fee/1` は負の fee を `:negative_fee` で拒否（positions.ex L278-290）
  >
  > 個々は小さいが、**「fail-closed をどこに置くか」の判断が人によってぶれていない**。この一貫性は、規模が同程度の自動売買では滅多に見ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

### 起動・突合（live の意味論）

- **突合窓を両向きに対称化し、再試行時の入力汚染まで潰した** `+3`
  > 前回 `-2` を付けた「取引所が内部より先の向きは救済されず即 halt」が閉じた。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L329-349
  > {:error, :reconcile_mismatch, %{kind: :balance_mismatch} = meta} when fill_retries > 0 ->
  >   with :ok <- sync_live_fills(exchange),
  >        {:ok, internal2} <- restore(:live),
  >        {:ok, snapshot2} <- fetch_live_snapshot(exchange) do
  >     # 注入 :fills が残ると再同期後も古い Fill 列で再比較してしまう
  >     compare_with_window_retries(internal2, snapshot2, required,
  >       opts |> Keyword.delete(:fills) |> Keyword.put(:fill_sync_retries, fill_retries - 1), exchange)
  >   end
  > ```
  >
  > 設計判断として良いのは 2 点。
  >
  > (1) **向き判定をせず、任意の `balance_mismatch` で 1 回再同期する**。前回は「買いなら quote 減・base 増のときだけ」と提案したが、実装は判定を捨てて広く取った。入金でも 1 回無駄に sync が走るが、向き判定のロジックを持たない方が壊れにくい。コメントで「向き判定より広い。入金も sync 1 回走るが飲み込みはしない」と意図が明示されている（L294）
  >
  > (2) 再同期後に**内部も snapshot も両方取り直す**（`internal2` / `snapshot2`）。片方だけ更新すると、増えた Fill を古い残高と比べて「入金」と誤判定する。この失敗を先読みしてコメントに残している（L293）
  >
  > `balance_exchange_lag` が retry を使い切ったときも、`kind` を `balance_mismatch` に、`reason` を `balance_exchange_lag` に書き換えて halt 理由の分類を保っている（L322-327）。**観測のために理由を潰さない**という設計が徹底している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

### market-data

- **spread ゲートを入れるにあたり、正規化側を「壊れた板を Cache に載せない」方向で厳格化した** `+2`
  > `Normalize.from_ticker/1` は `best_bid` / `best_ask` を必須化し、ゼロ・負・crossed（`ask < bid`）を弾く。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/normalize.ex L32-37
  > {:ok, decimal_bid} <- cast_positive_decimal(bid),
  > {:ok, decimal_ask} <- cast_positive_decimal(ask),
  > true <- Decimal.compare(decimal_ask, decimal_bid) != :lt,
  > ```
  >
  > 認可側は成行だけを対象にし、mid 基準の spread% で判定する（risk.ex L549-577、`spread_pct/2` は L884-894）。指値は従来の LTP 乖離のまま。**「成行の実効価格を守る入力」と「指値の妥当性」を別の検査として分けた**のは正しい切り方である。bid/ask 欠落は `:stale` で fail-closed。
  >
  > 既定 `max_spread_pct: "0.5"` にはコメントで「corpus 正常帯 ~0.05% を通し薄商いを止める」と根拠が書かれ（config.exs L104-105）、live は `BITFLYER_MAX_SPREAD_PCT` が必須（live_safety.ex L22）。**閾値の出どころが記録されている**閾値は珍しい。
  >
  > 一方で「ltp と bid/ask の失敗ドメインを一つにした」副作用は weaknesses に `-1` で計上した。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `config/config.exs`

### strategy

- **`insufficient_balance` の Tight loop を、銘柄単位バックオフと同一 tick 打ち切りの 2 段で止めた** `+2`
  > 前回「`Runner` の `:insufficient_balance` 再試行にバックオフを付けろ」と述べた点が入っている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/strategy/runner.ex L263-271
  > # 同一 tick 内で残高不足になったら後続 command は送らない
  > if match?({:error, :limit_exceeded, %{limit: :insufficient_balance}}, result) do
  >   {:halt, {acc, cooldowns}}
  > ```
  >
  > cooldown は `product_code => monotonic_ms` で持ち、成功（`{:ok, _}` / `{:ok, _, :idempotent}`）で明示的に削除する（L283-309）。**枯渇が解消したら即座に戻る**設計で、固定 sleep ではない。monotonic 時刻が負になりうる前提で「未評価はキー欠如で表す」としている throttle 側の注意（L202）も同じ思想。
  >
  > あわせて `:max_spread_pct` を `@retryable_limit_kinds` に追加し、「一時的な薄商い。settle すると同一 intent が二度と出ない」と理由を書いている（L46-47）。新しい拒否理由を足すときに `settle?` の意味を考え直している点を評価する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### OTP / Application

- **監督ツリーの兄弟関係と `prep_stop` の drain が、停止時の「不明」を circuit に落とすところまで書かれている** `+2`
  > `Bitflyer.Observe.Discord` は発注経路の兄弟で、`@child_shutdown_ms 5_000` を明示（application.ex L29-36）。`prep_stop/1` は「Discord telemetry 解除 → `mark_not_ready_safe` → `InFlight.drain`」の順で、timeout 時は pending 注文を `submission_unknown` にして `Risk.open_circuit(:submission_unknown)` する（L108-123）。
  >
  > 効いているのは `finalize_drain_timeout/1` の分岐で、submit mark が無く cancel だけ残っていても `leftovers != []` なら circuit を開く。**「分からないまま次回起動で Ready にしない」**が実装されている。shutdown 予算を `Compose stop_grace_period 45s` と突き合わせてコメントに残している点（L8-11、config.exs L110-111）も運用として真っ当である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `config/config.exs`

---

## 技術評価層 — 実行基盤 / 設定

- **live 起動時の安全既定が「環境変数を要求する」だけでなく形式と上限まで検証している** `+3`
  > `LiveSafety` は live で 7 本の Risk 上限（`max_spread_pct` を含む）を必須化し、欠落・空・形式不正で起動を止める（live_safety.ex L15-23, L143-148）。加えて、
  >
  > - `FixedOnce`（開発用の自動成行）は live で有効化不可（L93-99）
  > - `MarketData.product_codes` が全部 spot でなければ起動停止（L50-75）。`getcollateral` 未実装という理由をエラーメッセージ本文に書いている
  > - `max_open_age_ms` は「有限だが実質無期限（年単位）」を 7 日上限で拒否（L12-13, L124-133）
  >
  > `runtime.exs` 側は `TRADE_MODE` 既定 `dry_run`、不正値で起動停止、`BITFLYER_LIVE_CONFIRM` が**当日 UTC 日付一致**でなければ live 確認扱いにしない（runtime.exs L80-108）。`:test` では live キーを空に固定し（L136-144）、`.env` の live 値がテストに漏れない。
  >
  > 「live 解禁が明示的か」という評価軸に対して、**明示の粒度が env の存在ではなく値の妥当性まで来ている**のは、この規模では上位である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **`precommit` に `ash.codegen --check` が入り、no-op migration が「消すな」の理由付きで残っている** `+2`
  > 5 サイクル残っていたドリフトゲートが閉じた（mix.exs L47-55）。良いのはゲート追加そのものより、そのために必要になった空 migration の扱いである。
  >
  > ```elixir
  > # apps/bitflyer/priv/repo/migrations/20260916101043_sync_handwritten_snapshots.exs L3-22
  > Ash resource_snapshots 同期のための **意図的 no-op migration。削除しないこと。**
  > ...
  > 空だからといって削除してよいファイルではない。
  > ```
  >
  > 「なぜ空か / なぜ残すか」が moduledoc に書かれ、`git ls-files` で snapshot 4 本と migration の両方が追跡済みであることを確認した。**将来の自分が「無意味なファイル」として消す事故**を先に潰している。1 行の負債返済にこれだけ理由を残すのは珍しい。
  > 対象ファイル: `mix.exs`, `apps/bitflyer/priv/repo/migrations/20260916101043_sync_handwritten_snapshots.exs`

---

## 横断評価層

### 取引完成度 / Game Day

- **Game Day Stage 2 を同一 BEAM の縦経路に置き換え、後始末まで task に入れた** `+3`
  > 前回「SQL 直投入と ready 503 だけの代替」だった Stage 2 が、`mix bitflyer.game_day_stage2` で paper Executor を実際に通す形になった。paper `submit_order` で建玉 → Feed を毒 URL に差し替えて `feed_disconnected` 拒否 → 復帰後に再 submit → Discord Webhook HTTP 2xx（game_day_stage2.ex L60-67）。
  >
  > 評価するのは**後始末の設計**である。
  >
  > ```elixir
  > # apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex L68-72
  > after
  >   # feed_reject 失敗時も毒 URL を残さない（長寿命 paper BEAM 対策）
  >   _ = safe_restore_feed()
  >   :ok = cleanup_paper_side_effects!()
  > end
  > ```
  >
  > `after` で Feed を公式 URL に戻し、paper 建玉・`gameday-paper-` 接頭辞の Order/Fill を削除し、tip を再投入する（L313-353）。**共有 DB と長寿命 BEAM を汚さない**ことを前提に書かれたドリルは、この種の自作 Game Day では稀である。`ensure_paper_mode!` で paper 以外は即 halt（L78-89）、`halt_if_failed!` で全ステップの `{:ok, _}` を要求（L245-267）。証跡も [game-day.md](../../architecture/env/game-day.md) の 2026-09-16 行に、前回の SQL 代替を卒業したことを含めて記録されている。
  >
  > ただしステップ間で `Readiness.mark_ready()` を直接押している点は本番の Ready 経路を証明しないため、weaknesses に `-1` で計上した。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`, `.workspace/0_doc/architecture/env/game-day.md`

### 自己改善サイクル

- **improvement-plan の「必ず消す」宣言を、今サイクルは実際に守った** `+1`
  > 前回 `-1` を付けた「宣言 3 件に対して消化 0 件」が是正された。P2 #9 の 3 件をコード再読で確認した。
  >
  > | 宣言 | 現状 |
  > |:---|:---|
  > | `ash.codegen --check` を precommit へ | `mix.exs` L52 に追加済み。snapshot / migration も追跡済み |
  > | 両 `test_helper` に Sandbox `:manual` | `apps/bitflyer` / `apps/ui` の両方に 2 行目として追加済み |
  > | `apps/bitflyer/README.md` を責務説明に | 生成テンプレを削除し、Repo / Domain・論理コンポ・品質ゲート・親ドキュメントへのリンクの 10 行に置換 |
  >
  > 加点は 3 件そのものではなく（1 行ずつの負債は本来 +0 相当）、**自分で書いた「必ず」を守った記録が付いた**というプロセス側の一点に対するものである。残り（Dockerfile USER / websockex 記録 / 保持方針）は明示的に次サイクルへ送られており、宣言と実績の差が縮んだ。
  > 対象ファイル: `mix.exs`, `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`, `apps/bitflyer/README.md`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer — order-executor / datastore（手数料会計） | +4 |
| apps/bitflyer — risk-manager | +9 |
| apps/bitflyer — 起動・突合 | +3 |
| apps/bitflyer — market-data | +2 |
| apps/bitflyer — strategy | +2 |
| apps/bitflyer — OTP / Application | +2 |
| 実行基盤 / 設定 | +5 |
| 横断（取引完成度 / Game Day） | +3 |
| 横断（自己改善サイクル） | +1 |
| **合計** | **+31** |
