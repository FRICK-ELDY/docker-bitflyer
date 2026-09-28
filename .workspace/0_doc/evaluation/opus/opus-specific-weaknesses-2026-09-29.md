# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-29

対象コミット: `afc46bb`（`Merge pull request #123 from FRICK-ELDY/fix/p2-10-completion-evidence`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-16](./archive/2026-09-16/opus-specific-weaknesses-2026-09-16.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。
`mix precommit` は本評価では**未実行**（親プロセスが品質ゲート実行中のため `_build` を奪わない）。CI 定義は静的に確認した。

## 採点基準

    10|
| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -9 点**

    20|前回 -16 から 7 点改善した。前回 13 件のうち **7 件（-11 点分）の解消を確認した**（commission 一次証跡、成行 ask 拘束、ticker 2 層化、`DailyEquityPeak` の `inspect` 一致、Game Day のグローバル `clear_circuit`、ハーネスの反証、improvement-plan の完了宣言精度）。HWM 認可後 crash 窓は残差のみ（`-1` 据え置き）。据え置きは 3 件（別ホスト監視 `-2`、開発 Dockerfile root `-1`、`websockex` 未記録 `-1`）で、いずれも資金経路ではなく滞留の問題である。

新規は 3 件（`-3` 分）で、すべて今サイクルで入った実装の周辺にある。**いずれも fail-closed 側で、資金を直接失う経路は見つからなかった。**

---

## 技術評価層 — apps/bitflyer

### risk-manager / HWM

- **ノード強制終了で `DailyLoss` と `PeakWriter` の両メモリが消える窓が残る（残差。前回 `-1` を据え置き）** `-1`
    30|  > P1 #3 の write-behind は正しく入っている（strengths `+4`）。残るのは「認可の戻り値より前に DB へ同期しない」という設計上の残差である。
  >
  > `Risk.check_daily_drawdown/2` は `persist: false` + `write_behind: true` で `Equity.enforce/1` を呼ぶ（risk.ex L660-672）。`DailyLoss.schedule_write_behind/4` は `PeakWriter` への `GenServer.call` が返った時点で `:ok` にし、DB 完了は待たない（daily_loss.ex L392-408）。`PeakWriter.handle_call({:enqueue, ...})` も pending マップへ入れて即 `:reply` する（peak_writer.ex L149-161）。
  >
  > つまり「認可で ETS peak が上がる → writer が受理する → DB へ書く前に `kill -9` / 電源断」の順で、その高値は残らない。`PeakWriter` 自身の moduledoc がこれを明記している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/peak_writer.ex L13-14
  > # ノード強制終了でこのプロセスと DailyLoss の両方が消えると、DB 未着の高値は残らない。
  > ```
  >
    40|  > 窓の幅は前回（mark stale 中の再起動すべて）から数十ミリ秒級まで縮んでおり、`terminate/2`（L209-212）と `prep_stop` の `drain/1`（application.ex L111-113）が通常停止を覆う。残るのは本当にホストごと落ちる場合だけで、Vision L119-122 が本番 PC のリスクとして挙げている Windows Update 再起動は SIGTERM 経由なので `prep_stop` に入る。したがって重みは `-1` のままとする。
  >
  > 改善方針: 完全に閉じるなら認可の戻り前に同期 upsert が要り、ホットパスの DB 往復と引き換えになる。現実的には「HWM が戻るのは強制終了時のみ」と `prod.md` に 1 行書き、`.wslconfig` / 電源設定の運用対策へ寄せるのが安い。improvement-plan の部分完了表記は妥当なので、これを完了に昇格させないこと。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`PeakWriter` の再試行が 50ms 固定で、DB 障害中に毎秒 20 本の `:error` ログを出し続ける（新規）** `-1`
  > 今サイクルの新規である。upsert が失敗すると `persist_attempt/5` は `mark_unsynced/4` を呼んでから `:retry` を返し、`flush_one/1` が 50ms 後に自分へ `:flush` を送る。
  >
  > ```elixir
    50|  > # apps/bitflyer/lib/bitflyer/risk/peak_writer.ex L23, L232-235
  > @retry_ms 50
  > ...
  >   :retry ->
  >     state = requeue(state, mode, day, peak, daily_loss)
  >     Process.send_after(self(), :flush, @retry_ms)
  > ```
  >
  > 間隔は固定で、バックオフも上限回数も無い。1 回ごとに `DailyLoss` の `{:peak_persist_failed, ...}` へ `GenServer.call` が飛び（L334-337）、受け側はそのつど `:error` レベルで記録する。
  >
  > ```elixir
    60|  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L752-757
  > Bitflyer.Telemetry.log(
  >   :error,
  >   "daily equity peak persist failed; marked unsynced",
  >   %{reason: inspect(reason), trade_mode: trade_mode, trading_day: Date.to_iso8601(day)}
  > )
  > ```
  >
  > DB が数分落ちれば同一メッセージが数千行積まれる。本番は `ConsoleReporter` と stdout ログが正本（overview L167）なので、**障害の原因行がこの繰り返しで埋まる**。資金は守られる（当該モードは unsynced で認可拒否）ので `-2` ではないが、Observable の観点では「落ちているあいだにログが読めなくなる」のは実害である。あわせて 20 回/秒の `GenServer.call` が `DailyLoss` の処理キューを占める（同プロセスは認可の `prepare_peak` も捌く）。
  >
    70|  > 改善方針: `@retry_ms` を指数バックオフ（50ms → 上限 5s）に変え、同一 `{mode, day, reason}` の `peak_persist_failed` ログは最初の 1 回と間隔つきの再掲だけにする。`DailyLoss` 側は既に unsynced なので、2 回目以降は状態遷移が無く、ログを落としても失うものが無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

### order-executor / 手数料会計

- **一次証跡は `BTC_JPY` 1 銘柄なのに、live 認可は spot allowlist 8 銘柄をそのまま通す（新規）** `-1`
  > P0 #1 は実測で閉じた（strengths `+5`）。残る穴は**その証跡の適用範囲と、認可が許す範囲がずれている**ことである。
  >
  > 手数料通貨は銘柄種別だけで決まる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L114-119
    80|  > def fee_currency(product_code) when is_binary(product_code) do
  >   case market_type(product_code) do
  >     :spot -> base_currency(product_code)
  >     _ -> quote_currency(product_code)
  >   end
  > ```
  >
  > `@spot_products` は `BTC_JPY` / `ETH_JPY` / `XRP_JPY` / `XLM_JPY` / `MONA_JPY` / `BCH_JPY` / `ETH_BTC` / `BCH_BTC` の 8 件（product.ex L12-21）。live のゲートは `Product.spot?/1` だけを見る（risk.ex L270-271）。起動時検査も同じで、`LiveSafety.assert_live_products!/1` は `spot?` で弾くだけである（live_safety.ex L60-72）。
  >
  > 一方で証跡とコメントは、他ペアが仮定であることを自ら書いている。
    90|  >
  > ```
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L108-111
  > - `:spot` — 当面 base。BTC_JPY は 2026-09-28 の実測で、買い `+S−C` / `−S·P`、
  >   売り `−(S+C)` / `+S·P`。`ETH_JPY` など他の spot はペア別の非ゼロ execution が
  >   無く、同じ式は仮定である
  > ```
  >
  > `MarketData.product_codes` を `ETH_JPY` に変えるだけで、**P0 #1 が閉じる前の BTC_JPY と同じ状態（推定の会計モデルで live 発注）へ戻れる**。実害は突合の `balance_mismatch` halt であり資金は失われないが、`cancel_on_halt` は `reconcile_mismatch` で `false`（config.exs L44）なので未約定は板に残り、人が Status の Resume を押すまで復帰しない。P0 #1 をわざわざ実測で閉じた以上、同じ基準を認可側にも入れるべきである。
  >
   100|  > 改善方針: `Product` に「一次証跡のある銘柄」集合（当面 `BTC_JPY` のみ）を持ち、`check_live_product/2` と `assert_live_products!/1` がそちらを見る。新しいペアは `commission-unit-evidence.md` に実測表を足してから集合に入れる。Vision の live 対象は既定 `BTC_JPY`（overview L113）なので、運用上の制約にはならない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### strategy

- **戦略が `FixedOnce` 1 本だけで、live で有効化できる戦略が依然ゼロ（前回から未解決）** `-1`
  > `apps/bitflyer/lib/bitflyer/strategy/` は `runner.ex` / `fixed_once.ex` / `revision.ex` の 3 本のまま。`FixedOnce.evaluate/3` は固定 1 回の成行買い意図を返すだけで、自身も live では空リストを返す（fixed_once.ex L14-18）。
  >
  > 起動側も二重に禁止している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/config/live_safety.ex L93-99
   110|  > def assert_strategy_allowed!(true, Bitflyer.Strategy.FixedOnce) do
  >   raise ArgumentError, """
  >   Bitflyer.Strategy.FixedOnce cannot be enabled when TRADE_MODE=live.
  > ```
  >
  > 方針違反ではない（Vision L27 が戦略の中身を後続バックログへ送っている）。しかし「起動 → 購読 → 判定 → リスク → 発注 → 突合 → 停止/再開」のうち**判定だけが配管疎通用のダミー**であり、live 解禁を議論している段階で解禁しても動かせる戦略が無い、という状態は取引完成度として計上する。安全側の土台は十分厚いので、明示的なエントリ / エグジットを持つ薄い戦略 1 本を通せば、この減点は加点に反転しうる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### 可観測性（RiskState）

- **`halted_at` が周期突合のたびに上書きされ、「最初にいつ止まったか」が残らない（新規）** `-1`
   120|  > `Reconciler` は既定 60 秒間隔で走る（config.exs L20-22）。突合が失敗するたびに `do_apply_result/2` の失敗節が `persist_risk_halt/1` を呼び、`halted_at` を現在時刻で書き直す。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconciler.ex L390-397, L411-414
  > defp persist_risk_halt(reason) do
  >   halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
  > ...
  >   {:ok, %RiskState{} = risk} ->
  >     case risk
  >          |> Ash.Changeset.for_update(:update, Map.take(attrs, [:halted, :reason, :halted_at]))
  > ```
   130|  >
  > `RiskState` は `name == "default"` の単一行で、履歴を持たない（circuit.ex L16, L150-158）。`balance_mismatch` のように突合が繰り返し失敗する停止では、60 秒ごとに `halted_at` が前進する。夜間に止まって朝に気付いたとき、DB に残るのは「1 分前に止まった」という記録だけで、**実際の停止時刻は失われている**。
  >
  > 同じ挙動は `boot?: true` の起動突合でも起きており、テストが意図として固定している。
  >
  > ```elixir
  > # apps/bitflyer/test/bitflyer/game_day_stage2_test.exs L122-125
  > assert {:ok, %RiskState{halted: true, reason: "manual_halt", halted_at: rewritten}} =
  >          read_default_risk_state()
  > assert DateTime.compare(rewritten, risk.halted_at) == :gt
   140|  > ```
  >
  > Game Day 経路（P1 #6b）は `halted_at` を書き換えないよう正しく直されたのに、常駐側の周期突合には同じ規律が入っていない。Vision の Observable（「約定、拒否、切断、再起動の理由を残す」）に対して、**理由は残るが時刻が残らない**。停止と相場・WS 断の時系列を後から突き合わせられないのは、事後説明の土台を欠く。
  >
  > 改善方針: `persist_risk_halt/1` を「既に `halted: true` かつ同一 `reason` なら `halted_at` を触らない」条件付き更新にする（理由が変わったときだけ更新）。より厚くするなら `halt_events` 追記テーブルを足して `RiskState` を現在値専用にする。前者は 5 行で閉じる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

---

   150|## 技術評価層 — 実行基盤 / 設定

- **開発 `Dockerfile` が root で実行される（7 サイクル連続。未解決）** `-1`
  > 開発 `Dockerfile` は全 20 行で `USER` 指定が無い（L1-20）。`compose.yaml` は `.:/app` を bind mount するので（compose.yaml L31-34）、`priv/static/assets` や `priv/contract/corpus`、そして今サイクルで増えた `/app/.data/hwm-drain-halt`（compose.yaml L49-50）が root 所有でホスト側に生まれる。
  >
  > `Dockerfile.prod` は uid/gid 1000 のユーザーを作り、`--chown=app:app` で配り、`USER app` まで付けている（Dockerfile.prod L55-67）。本番 Compose は `halt_marker` ボリュームを別サービスで `chown 1000:1000` までしている（compose.prod.yaml L41-47）。方針は完全に理解されていて、**開発側だけが 7 サイクル取り残されている**。
  >
  > 改善方針: 開発 `Dockerfile` に uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる（`bin/docker-entrypoint.sh` で `chown` するか `compose.yaml` に `user: "1000:1000"`）。
  > 対象ファイル: `Dockerfile`, `compose.yaml`
   160|

---

## 横断評価層

### 可観測性

- **別ホスト監視が実配備されておらず、live 解禁の最後の出口条件が未達（3 サイクル連続）** `-2`
  > 道具（`bin/watch-ready.ps1` / `bin/watch-ready.sh` / `bin/register-watch-ready-task.ps1`）とドリル記録は揃っている。今サイクルも変化は無く、証跡の最終更新は **2026-09-13 のまま**で、自ら未達を書いている。
  >
   170|  > ```
  > # .workspace/0_doc/architecture/env/watch-ready-evidence.md L2, L29, L74-75
  > 最終更新: 2026-09-13
  > ...
  > | 常駐登録 | 未登録（`bin/register-watch-ready-task.ps1` は手順のみ。取引ホストでは動かさない） |
  > ...
  > ## まだ閉じないこと
  > - VLAN1 本番 PC を `READY_URL` にした常駐は未登録（この記録の対象は開発 Compose）
  > ```
  >
   180|  > improvement-plan の P1 #5 は未完了のまま残っており（improvement-plan.md L50）、記述も前回と同一である。P0 #1 / #2 が閉じた今、**これが live 解禁の単一残条件**になった。
  >
  > 現状で検知できるのは「アプリが 503 を返す」「ポートが死んだ」までである。`/health/ready` は取引ホスト自身が返し、Discord HEARTBEAT も `Bitflyer.Observe.Discord` としてアプリ内から出る（application.ex L39-40）。したがって**ホストごと落ちた場合（Windows Update の再起動、WSL2 のハング）は沈黙と正常の区別が付かない**。Vision L119-122 が本番 PC の予期しない再起動をリスクとして明記している以上、これは 24/365 の価値命題に直結する。
  >
  > 改善方針: VLAN1 本番 PC を `READY_URL` にして作業用 PC1 で `register-watch-ready-task.ps1` を実行し、証跡に「本番向き常駐」の行と、取引ホストを止めて alert が出た記録を足す。1 回の作業で閉じる。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`

### 変更容易性・保守性

- **常時接続の中核が `websockex` に載ったままで、その事実が `architecture/` に 1 行も無い（7 サイクル連続）** `-1`
   190|  > `apps/bitflyer/mix.exs` L38 の `{:websockex, "~> 0.4"}` は不変。`mix.lock` L56 は 0.5.1 に上がっているので「2019 年で止まっている」という前サイクルまでの記述は現状に合わないが、**記録が無いという指摘自体は変わっていない**。
  >
  > リポジトリ全体（`deps` / `_build` / 評価文書を除く）で当たるのは `mix.exs` の 1 行と `socket.ex` だけで、`.workspace/0_doc/architecture/` にはゼロ件である。`ci-cd.md` の「CI / CD が保証しないこと」は 6 項目あるが（ci-cd.md L69-76）、常時接続の依存に関する行は無い。`socket.ex` の moduledoc も 1 行のままである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/socket.ex L2-4
  > @moduledoc """
  > Lightstream JSON-RPC WebSocket（WebSockex）。
  > """
  > ```
   200|  >
  > コード側の設計はむしろ良い。`handle_disconnect/2` は自動再接続せず Feed に委ね（socket.ex L49-59）、`Socket.Client` behaviour で差し替え可能になっている。だからこそ**移行コストは既に低い**のに、「常時張る唯一の外部接続が 1 依存に集約されている」「`mix deps.audit` は Hex advisory しか見ないのでメンテ停滞は CI に出ない」という 2 行が 7 サイクル残らない。P3 #15 に載っているが着手されない、という運用構造の問題である。
  >
  > 改善方針: `mix.exs` の制約を `~> 0.5` へ上げて lock と揃え、`ci-cd.md` の非保証欄に 1 行、`socket.ex` の moduledoc に既知リスクとして 1 行。移行するなら `Mint.WebSocket` + 自前 GenServer か `Fresh` へ behaviour 実装を差し替える。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `.workspace/0_doc/architecture/ci-cd.md`

---

## 小計

   210|| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer — risk-manager / HWM | -2 |
| apps/bitflyer — order-executor / 手数料会計 | -1 |
| apps/bitflyer — strategy | -1 |
| apps/bitflyer — 可観測性（RiskState） | -1 |
| 実行基盤 / 設定 | -1 |
| 横断（可観測性） | -2 |
| 横断（変更容易性・保守性） | -1 |
| **合計** | **-9** |
   220|

---

## 前回マイナス点の解決状況（コード再読で確認）

| 前回の指摘 | 前回 | 状況 | 根拠 |
|:---|:---:|:---|:---|
| commission 単位が推定のまま「完了」宣言・売り側未検証 | -2 | **解決** | `commission-unit-evidence.md` L44-62 に 2026-09-28 の買い …6098 / 売り …6123 の実差分。`LiveBalance.fill_delta/2` の売りが `−(S+C)`（live_balance.ex L290-297）。`live_balance_test.exs` L452-518 が実測値を固定 |
| 成行の残高拘束が LTP 基準で `best_ask` を使わない | -1 | **解決** | `base_unit_price(:live, :buy, :market, ...)` が `fetch_bid_ask` の ask を返す（risk.ex L825-834）。paper は LTP のまま（L836-845） |
| HWM の flush 点火が mark price に依存 | -1 | **解決（残差 `-1`）** | 認可は `write_behind: true`（risk.ex L660-672）。`PeakWriter` が mark 非依存に upsert（peak_writer.ex L292-317）。残るのはノード強制終了のみ |
| `DailyEquityPeak` の衝突検出が `inspect` 文字列一致 | -1 | **解決** | `INSERT ... ON CONFLICT DO UPDATE SET peak = GREATEST(...)` の 1 文（daily_equity_peak.ex L105-118）。`inspect` 経路は消滅 |
   230|| 板が crossed / ゼロで ticker を丸ごと破棄 | -1 | **解決** | `cast_book/2` が `nil` を返し LTP は載る（normalize.ex L43-50, L243-251）。`book/1` は層があるとき平坦へ落ちない（L122-137） |
| `websockex` 依存の記録なし | -1 | **未解決** | `mix.exs` L38 不変。`architecture/` に記述ゼロ（`ci-cd.md` L69-76 にも無し） |
| 戦略が `FixedOnce` 1 本 | -1 | **未解決** | `strategy/` は 3 ファイルのまま。`LiveSafety` L93-99 が live での有効化を拒否 |
| 開発コンテナが root | -1 | **未解決** | `Dockerfile` に `USER` なし（全 20 行） |
| ハーネスが本番と同じ手数料モデルで反証になっていない | -1 | **解決** | `set_sell_fee_model/1` で `:base_deduct` / `:quote_mark` を切替（live_exchange_harness.ex L127-146）。`live_balance_advance_test.exs` L363-409 が `:quote_mark` の売りで `{:halted, :reconcile_mismatch}` を固定 |
| 別ホスト監視が未配備 | -2 | **未解決** | `watch-ready-evidence.md` L2 の最終更新が 2026-09-13 のまま。L29 / L74-75 が未登録と明記 |
| Game Day が `RiskState` / `Readiness` を無条件に書き換える | -2 | **解決** | `persisted_start_block/0` で Repo だけ読み halted / unsynced は中断（game_day_stage2.ex L66-76, L122-139）。`clear_circuit` / `mark_ready` の直接呼び出しは全段から消滅。Ready は `require_ready_via_reconcile/0` 経由のみ（L226-238） |
| improvement-plan が完了条件を満たさない項目を消している | -2 | **解決** | 完了宣言ルールを improvement-plan.md L7 と `.cursor/rules/evaluation.mdc` L299-307 に置き、消化済み 11 件すべてに観測 1 行が付いた。今回の再読で見方との矛盾は見つからなかった |

**解決 7 件（-11 点分）/ 残差付き解決 1 件 / 未解決 4 件（-5 点分）/ 新規 3 件（-3 点分）。**
   240|
未解決 4 件のうち 2 件（開発 Dockerfile root、`websockex` の記録）は **7 サイクル連続**である。いずれも 1〜2 行で閉じる。別ホスト監視は 3 サイクル連続で、かつ live 解禁の単一残条件になった。
