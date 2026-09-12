# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-12

対象コミット: `1cfb413`（`Merge pull request #86 from FRICK-ELDY/fix/p2-deps-audit-gate`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-10_2](./archive/2026-09-10_2/opus-specific-weaknesses-2026-09-10_2.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。すべての判定は当該コードの再読に基づく。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -18 点**

前回の -24 から 6 点改善した。前回の 19 件のうち 11 件（-16 点分）はコード再読で解決を確認した。特に前回の live ブロッカー 2 件（FX にスポット残高モデル、部分約定の累積 VWAP）はどちらも解けている。

一方で **新規に 5 件（-10 点分）** を見つけた。うち 3 件は「P0 #2 を spot 限定で解いた結果、spot の残高・建玉の意味論が未整備のまま残った」ことに由来する。部品は揃ったが、live の突合ループが 1 回目の残高変動で必ず止まる状態である。

---

## 技術評価層 — apps/bitflyer

### 起動・突合（live の意味論）

- **live の残高突合が「固定 baseline との厳密一致」で、最初の残高変動で必ず `balance_mismatch` halt になる** `-4`
  > live の突合は内部 `BalanceSnapshot` の先端と取引所 `getbalance` を**厳密一致**で比較する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L536-548
  > defp balance_match?(left, right) do
  >   ...
  >   Decimal.eq?(left_amount, right_amount) and
  >     Decimal.eq?(left_available, right_available)
  > end
  > ```
  >
  > 問題は、live で内部 `BalanceSnapshot` を**更新する書き手が存在しない**ことである。書き手は 2 つしかない。(1) `Startup.Baseline.import/1` — 必須通貨のうち tip が無いものだけを書き、全部揃っていれば `:baseline_already_complete` を返して拒否する（baseline.ex L157-170, L340-355）。(2) `OrderExecutor.Balances.apply_fill/2` — paper の擬似約定専用（balances.ex L11-12）。`LiveFills` は moduledoc で明示的に「残高: **触らない**」と書いており（live_fills.ex L5-6）、`Reconciler` も突合成功後に `BalanceCache.put(:live, balances, clear_holds: true)` で **ETS だけ**を更新して DB には書かない（reconciler.ex L284-287）。
  >
  > 結果として、live の突合は「baseline を取った瞬間の残高」と「現在の取引所残高」を比べ続ける。指値を 1 本置けば取引所側の `available` が下がり、約定が 1 回入れば `amount` も動く。手数料でも動く。どちらも次の定期突合（`interval_ms: 60_000`、reconciler.ex L51）で `{:error, :reconcile_mismatch, %{kind: :balance_mismatch}}` になり、`Readiness.halt/1` + RiskState 永続化で停止する。しかも `reconcile_mismatch` は `cancel_on_halt` が `false`（config.exs L40）なので未約定はそのまま板に残り、復旧には人手が必要で、その人手の正規手順（`mix bitflyer.baseline`）は `baseline_already_complete` で拒否される。DB を直接いじる以外に戻る道がない。
  >
  > これは fail-closed なので資金は減らない。しかし Vision の「人が張り付かなくても回し続ける」「いつ落ちても永続化した状態から再開できる」に正面から反する。さらに README が「spot の内部 `Position` は…**Fill 後の Position ドリフトは残高突合と LiveFills に依存する**」（README.md L186）と書いているとおり、spot の安全網は残高突合しかない。その唯一の安全網が「最初の 1 回で誤検知して永久停止する」形で実装されている。prod.md L232 の「live 運用中の残高更新は引き続き紙の append ではなく取引所突合が正本」という一文は意図としては正しいが、コードは「取引所を正本にして内部を更新する」ではなく「内部を正本にして取引所を検査する」になっている。
  >
  > 改善方針: live の残高突合を「取引所を正本、内部 tip は監査記録」に反転させる。具体的には (a) 突合成功時に取引所残高から新しい `BalanceSnapshot` を append し（`captured_at` は取得時刻）、次回比較の基準を前進させる、(b) `balance_match?` の厳密一致をやめ、**前回 tip からの変化が内部の Fill 合計と手数料許容幅で説明できるか**を検査して、説明できない差分だけ `balance_mismatch` にする、(c) `Baseline` は初期化専用と明示し、別途 `--rebaseline`（承認 + hash）を用意する。最低でも (a) は live 解禁の前提条件である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/startup/baseline.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **live spot では建玉突合が完全に無効化され、ドローダウンゲートの入力が一度も取引所と照合されない** `-2`
  > P0 #2 の spot 限定に伴い、突合は spot 建玉を内外とも除外する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L287-292
  > # spot は getpositions 対象外。内部 Position は Risk 用の補助で、突合正本は getbalance。
  > internal = Enum.reject(internal, &spot_position_row?/1)
  > external = Enum.reject(external, &spot_position_row?/1)
  > ```
  >
  > `Exchange.Rest.get_positions_for/1` も spot では REST を呼ばず `{:ok, []}` を返す（rest.ex L162-173）。判断自体は妥当で（bitFlyer の spot に建玉概念はない）、overview.md L111-114 と README.md L182-186 に明記されている。問題は、その内部 `Position` が**資金保全ゲートの入力**になっていることである。`Risk.Equity.position_unrealized/3` は `Position.average_price` と `Position.size` から含み損を出し（equity.ex L224-257）、それが `max_daily_drawdown` の判定に入る（risk.ex L474-495）。`check_position_size/3` の建玉上限も同じ行を見る。
  >
  > つまり **live spot では、ドローダウンサーキットと建玉上限が「一度も外部照合されない内部カウンタ」だけで動く**。`LiveFills` の記帳が正しい限り正しいが、それは前提であって検証ではない。しかも同一 API キー口座で手動売買が入れば内部 Position は無音でずれる（README も「監視しない」と認めている）。照合材料はある。`getbalance` の BTC `amount` は在庫数量の正本で、内部 `Position.size`（+ 未約定売りの拘束分）と突き合わせられる。使っていないだけである。
  >
  > 改善方針: spot では `getbalance` の base 通貨 `amount` と「内部 Position size + 未約定売り拘束」を許容幅付きで突合し、超過を `position_mismatch` にする。平均単価は取引所に存在しないので比較対象外であることをコードのコメントに残す。あわせて `Equity` の `unrealized` が「内部平均単価に依存する推定値」であることを prod.md の安全装置節に明記する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

### risk-manager

- **当日 equity ピーク（HWM）が永続化されておらず、プロセス再起動でドローダウンゲートが緩む** `-2`
  > `Risk.Equity` の `drawdown = peak − equity_pnl` は良い設計で、`peak` は `DailyLoss` の ETS に持つ。ところが `DailyLoss.init/1` は実現 net を Fill から再集計する一方、`peak` には常に 0 を入れる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L217-221
  > case load_modes(@trade_modes, now) do
  >   {:ok, rows} ->
  >     Enum.each(rows, fn {mode, day, loss, net, true} ->
  >       insert_row(table, {mode, day, loss, net, true, 0, 0, zero()})
  >     end)
  > ```
  >
  > `record_peak` は `base = if row_day == day, do: peak, else: zero()` から `max(equity_pnl, base, 0)` を取る（L343-354）ので、再起動直後の最初の `snapshot/1` で `peak` は「その瞬間の equity_pnl（負なら 0）」に置き換わる。当日 +10 万まで伸びてから +2 万に落ちた状態（drawdown 8 万）で再起動すると、`peak = 2 万`・`drawdown = 0` になり、`max_daily_drawdown` を 5 万に設定していても止まらない。
  >
  > `max_daily_loss`（実現のみ）は Fill から再集計されるので守られる。守られないのは「実現益を出したあと含み損で溶ける」という、P2 #11 が塞ぐために作られたまさにそのケースである。improvement-plan の完了条件「建玉持ち越し・実現益後の含み損でもドローダウンで止まる」は、**再起動を挟むと満たされない**。Vision L119-122 は本番PC（Windows 11 + WSL2）の予期しない再起動をリスクとして明記しており、24/365 でこの経路を踏む確率は低くない。`Equity.mark_position` が stale で fail-closed になる設計まで詰めてあるのに、ピークだけが揮発性なのはちぐはぐである。
  >
  > 改善方針: `(trade_mode, trading_day, peak)` を永続化する。`RiskState` に 2 カラム足すか、軽量な `DailyEquityPeak` Resource を作り、`record_peak` で上昇時のみ upsert、`init/1` で当日行を読み戻す（読取失敗は unsynced で fail-closed、`OrderRate` / `FailureRate` と同型にできる）。書き込み頻度はピーク更新時のみなので負荷は無視できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **`Risk.authorize/2` が Feed 接続を見ず、Status STOPPED / `/health/ready` 503 と認可結果が矛盾する** `-1`
  > P1 #9 で観測側は統一された。`Health.classify_ready/4` と `OperationalStatus.classify/5` が同じ `market_feed_gate/2` を呼ぶ（health.ex L219-224、operational_status.ex L210-213）。しかし発注ゲートは統一されていない。`Risk.authorize/2` の鮮度検査は `Cache.fresh?/3` だけである（risk.ex L278-288）。モジュール自身が残差として認めている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/operational_status.ex L11-15
  > ## 残差（P1 #9 完了条件外）
  >
  > 実行時の `Risk.authorize/2` は Cache 鮮度のみを見る。Feed 切断直後〜stale までの
  > 短時間は Status が STOPPED・`/health/ready` が 503 でも authorize が通りうる。
  > ```
  >
  > 窓は `market_data_max_age_ms`（既定 5s）なので実害は小さい。ただし「画面が STOPPED と言っているのに注文が通った」は事故調査のときに最も混乱する種類の不整合で、しかも 1 段の `with` 節で塞げる。自認して放置するより塞ぐほうが安い。
  >
  > 改善方針: `check_freshness/3` の前に Feed 接続検査を挟み、`{:error, :stale, %{reason: :feed_disconnected}}` で拒否する（`MarketData.enabled?` が false のときはスキップ）。`Feed.status/0` の `GenServer.call` をホットパスに入れたくないなら、`Feed` が接続状態を `Cache` か `:persistent_term` に反映し、`authorize` はそれを読むだけにする。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **残高の「検査」と「予約」が別段のままで、認可通過 → 予約失敗の再試行ループが残る（前回から未解決）** `-1`
  > `Risk.authorize/2` の `check_available_balance/2` は `BalanceCache.get/2` の値を読んで比較するだけ（risk.ex L497-568）。実際の減額は認可後の `OrderExecutor.reserve_balance/3` → `BalanceCache.reserve/4`（order_executor.ex L447-472）。予約は GenServer 内で原子的に不足を弾くので資金は守られるが、`Runner` は `:insufficient_balance` を明示的に再試行対象にしている。
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
  > 混雑時は「認可 → 予約失敗 → throttle 後に再試行」が回り続ける。`OrderRate` は `reserve_balance_releasing/4` で release されるので枠は漏れないが（order_executor.ex L474-483）、`AuthorizedOrder` の mint/consume と REST 前の往復は毎回消費される。前回指摘した「検査と予約が同じ場所にないねじれ」は変わっておらず、`Risk` の moduledoc にも「残高判定は近似であり正本は reserve」という設計意図が書かれていない（他の残差はきちんと書いてあるだけに目立つ）。
  >
  > 改善方針: `BalanceCache` に `probe/4`（予約せず同一ロジックで可否だけ返す）を足して `authorize` から呼び、判定コードパスを 1 本にする。それが重いなら少なくとも `Risk` の moduledoc に近似であることを書き、`Runner` の `:insufficient_balance` 再試行にバックオフを付ける。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

### order-executor

- **`getexecutions` の件数上限を超える分割約定は、ページングせず恒久 fail-closed になる** `-1`
  > P0 #1 の coverage 検査は良い設計だが、取得側に上限がある。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/exchange/rest.ex L112-115
  > # getchildorders と同様、既定件数を明示（API 既定超えの分割約定で coverage 失敗を防ぐ）。
  > # bitFlyer の count 上限はおおむね 500。1 注文がそれを超えるとページ欠けで fail-closed のまま。
  > |> maybe_put_query("count", Map.get(request, :count) || 500)
  > ```
  >
  > 1 注文の約定明細が 500 件を超えると `exec_total != remote_filled` になり、`ensure_execution_coverage/4` が `:execution_size_mismatch`（`hint: :execution_page_may_be_truncated`）で拒否する（live_fills.ex L382-399）。fail-closed は正しいが**恒久的**で、その注文は以後どの経路でも記帳できない。`fill_price_unavailable` は `cancel_on_halt` が `true` なので未約定は取消されるが、既約定分の建玉・実現損益・DailyLoss は永久に内部へ載らない。`getexecutions` は `before` / `after` を受けるので、ページングは実装可能である。
  >
  > `max_order_size` を小さく保つ運用なら踏まない。ただし薄い板で成行を割られると 500 分割は起こりうるし、そのとき「安全に止まる」ではなく「安全に止まったまま戻れない」のが問題である。
  >
  > 改善方針: `fetch_executions` に `before`（execution id 降順のカーソル）でのページングを入れ、取り切ったことを `exec_total == remote_filled` で確認する。ページ数に上限を置き、超過時のみ現在の fail-closed に落とす。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

### market-data

- **ticker 一本のままで、板・約定ストリームが無い（前回から未解決）** `-1`
  > `Normalize.from_ticker/1` が取り出すのは `ltp` と `source_timestamp` の 2 つだけ（normalize.ex L20-32）、購読も `lightning_ticker_*` のみ。README L191-196 の表も `lightning_board_*` / `lightning_executions_*` を「—」としており、現状認識は正確である。
  >
  > 影響は 2 つに絞られている。(1) `Paper.decide_fill/3` が板の厚みを見ないため、大口の部分約定・不成立を paper で再現できない（`FillPricing` の不利化で楽観バイアスは大きく減った）。(2) `Risk` に spread ゲートが無く、異常スプレッド時の成行を拒否できない（P3 #16 として backlog にある）。live を spot 最小ロットで始める前提なら実害は小さいので `-1` に留める。
  >
  > 改善方針: まず `lightning_executions_*` を購読して直近約定列を `Cache` に置き、paper の約定サイズを出来高で頭打ちにする。ticker の `best_bid` / `best_ask` は REST の gap-fill でも取れているので、spread ゲートはそこから先に作れる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **常時接続の中核が更新の止まった依存（`websockex` 0.4）に載ったままで、その事実がどこにも記録されていない（前回から未解決）** `-1`
  > `apps/bitflyer/mix.exs` L38 の `{:websockex, "~> 0.4"}` は変わっていない。最終リリースは 2019 年の 0.4.3 で、OTP 27 の TLS 既定変更への追随は保証されない。`mix deps.audit` は Hex advisory しか見ないため（今回の実行も `No vulnerabilities found.`）、「メンテされていない」は CI に現れない。
  >
  > 前回の改善方針は「移行するか、`ci-cd.md` の非保証欄に明記する」だった。どちらも行われていない。`ci-cd.md` L69-76 の「CI / CD が保証しないこと」は 6 項目あるが、`websockex` の保守状況は含まれていない（GitHub タグ依存と Docker イメージの脆弱性は書いてある）。差し替え可能性は `MarketData.Socket.Client` behaviour と `Socket.Local` で確保されているので技術的難易度は低い。
  >
  > 改善方針: `Mint.WebSocket` + 自前 GenServer か `Fresh` へ behaviour 実装を差し替える。当面移行しないなら `ci-cd.md` の非保証欄に 1 行足し、`socket.ex` の moduledoc にも既知リスクとして残す（1 行の負債が 4 回連続で残っているのは、記録さえされていないからである）。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `.workspace/0_doc/architecture/ci-cd.md`

### datastore / Ash

- **永続データの保持・剪定方針がどこにも無い（前回から未解決 / P3 #17 未着手）** `-1`
  > `fills` / `balance_snapshots` / `orders` / `strategy_parameter_revisions` / `baseline_imports` はいずれも append-only で、削除・アーカイブ・パーティションのどれも無い。`prune` / `retention` / `delete_all` で当たるのは ETS の窓剪定（`OrderRate.prune/4`、`FailureRate.prune/4`）だけである。
  >
  > 今回のサイクルでこの負債は少し重くなった。`DailyLoss.load_modes/2` は当日分の Fill を **Ash で全行読んで Elixir 側で合算**する（daily_loss.ex L447-463）。`Reconciler` は 60 秒ごとに `DailyLoss.reload()` と `Equity.enforce()` を回すので（reconciler.ex L107-118）、約定が増えるほど毎分の読取量が増える。live を execution 単位 Fill にしたぶん行数は以前より増える設計になった。`balance_snapshots` は paper で通貨 2 行/約定ずつ伸びる。512 GB（vision.md L118）で当面破綻はしないが、「ETS は消えても再構築できる／DB は無限に育つ」の非対称がコードにも文書にも扱われていない。
  >
  > 改善方針: `prod.md` に保持期間（例: fills 2 年、balance_snapshots 90 日で日次ロールアップ）を書き、`mix bitflyer.compact` を用意する。当面剪定しないなら「しない。判断閾値は行数 N / サイズ M」と文書に残す。あわせて `DailyLoss.sum_realized/3` を `Ash.aggregate(:sum)` か生 SQL の `SUM` に変える（行を BEAM へ運ばない）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `.workspace/0_doc/architecture/env/prod.md`

---

## 技術評価層 — 実行基盤 / 設定

- **`mix precommit` に Ash マイグレーションのドリフト検査が無い（4 回連続）** `-1`
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
  > `mix ash.codegen --check` が無いので、Resource の attribute を変えてマイグレーションを書き忘れても CI は緑で通る（テスト DB は既存マイグレーションから作られる）。今回のサイクルはまさにドリフトしやすい変更を入れた。`Fill` に `order_id` 属性と `custom_indexes` と `identities` を足し、マイグレーション `20260912130000_add_fills_execution_evidence.exs` を手書きし、`priv/resource_snapshots/repo/fills/20260912130000.json` を追加している。今回は整合しているが、それは人が気を付けた結果で、ゲートが保証した結果ではない。
  >
  > 改善方針: `precommit` の `compile` の後に `"ash.codegen --check --domains Bitflyer.Trading"` を 1 行足す。snapshot は既にコミット済みなので追加コストはほぼゼロである。
  > 対象ファイル: `mix.exs`

- **開発コンテナが root で実行される（4 回連続）** `-1`
  > 開発用 `Dockerfile` は全 20 行で `USER` 指定が無い。bind mount した `/app` 配下（`.:/app`、compose.yaml L32）に root 所有のファイルが生まれる。`deps` / `_build` は名前付きボリュームに逃がしてあるが、`priv/static/assets` や `priv/contract/corpus`（`mix bitflyer.contract --write-corpus` の出力先）のようにホスト側へ落ちる生成物は root 所有になる。
  >
  > `Dockerfile.prod` は `groupadd --gid 1000 app` / `useradd --uid 1000` で非 root 化し `--chown=app:app` まで付けているので、方針そのものは理解されている。開発側だけが取り残されており、WSL2 ホストでの日常的な摩擦になる。
  >
  > 改善方針: 開発 `Dockerfile` にも uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる（`bin/docker-entrypoint.sh` で `chown` するか、`user: "1000:1000"` を compose に足す）。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

---

## 横断評価層

### テスト戦略

- **`test_helper.exs` に Sandbox のモード指定が無い（4 回連続）** `-1`
  > `apps/bitflyer/test/test_helper.exs` は `ExUnit.start()` の 1 行のみで、`apps/ui/test/test_helper.exs` も同じ。`Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` が呼ばれていない。
  >
  > 現状は DB を触るテストがすべて `Bitflyer.DataCase` / `UiWeb.ConnCase` 経由で `start_owner!/2` するため実害は出ていない（今回の実行でも 483 + 38 テストが 0 failures）。ただし明示が無いぶん、`use` を書き忘れたテストが 1 本入った時点でテスト DB に実データが残り、他テストの `read_one` が壊れて初めて気付く形になる。テストは前回 387 本から 521 本に増え、うち `live_fills_test.exs` の 24 本のように DB 状態に強く依存するものが増えた。事故時の原因特定コストは上がっている。1 行で「checkout していないプロセスは DB に触れない」が保証できる。
  >
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加する。
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`

### ドキュメント

- **`apps/bitflyer/README.md` が生成テンプレのまま残っている（2 回連続）** `-1`
  > リポジトリ全体で `TODO` / `FIXME` を検索して当たるのはこの 1 箇所だけである。
  >
  > ```
  > apps/bitflyer/README.md L3
  > **TODO: Add description**
  > ```
  >
  > 中身は Hex 公開用のテンプレ（`{:bitflyer, "~> 0.1.0"}` を deps に足せ、HexDocs で公開せよ）で、umbrella の中核アプリの説明としては誤情報でもある。ルート `README.md` が 236 行、`apps/ui/README.md` も存在し、`.workspace/0_doc/` が丁寧に整備されているだけに落差が目立つ。P3 #19「軽微負債一括」に載ってはいるが 2 サイクル着手されていない。
  >
  > 改善方針: 10 行程度で責務（取引所連携・ドメイン・エンジンの正本、論理コンポーネントの配置、ルート README と overview.md へのリンク）を書く。不要なら削除する。
  > 対象ファイル: `apps/bitflyer/README.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer — 起動・突合（live の意味論） | -6 |
| apps/bitflyer — risk-manager | -4 |
| apps/bitflyer — order-executor | -1 |
| apps/bitflyer — market-data | -2 |
| apps/bitflyer — datastore / Ash | -1 |
| 実行基盤 / 設定 | -2 |
| 横断（テスト戦略） | -1 |
| 横断（ドキュメント） | -1 |
| **合計** | **-18** |

---

## 前回マイナス点の解決状況（コード再読で確認）

| 前回の指摘 | 前回 | 状況 | 根拠 |
|:---|:---:|:---|:---|
| 既定 FX にスポット残高モデル | -3 | **解決** | `Product.market_type/1` の spot allowlist（product.ex L12-64）、`LiveSafety.assert_live_products!/1` が live 起動を拒否（live_safety.ex L45-71）、`Risk.check_live_product/2` が認可を拒否（risk.ex L217-236）。config / README / overview / backlog も一致 |
| 部分約定に累積 VWAP | -2 | **解決** | `apply_one_execution/3` が `exec.price` を使い `filled_notional` を対で進める（live_fills.ex L466-494）。回帰 `successive partial fills use incremental prices for position VWAP` ほか |
| live 発注 1 回で全件照会 2 回 | -2 | **解決** | `do_submit/2` から再同期を削除（order_executor.ex L104-122）。`sync_live_fills_before_authorize/2` のみ。`LiveFills.Gate` が最小間隔 1s と直列化を担う |
| `Fill.exchange_execution_id` が常に nil | -1 | **解決** | `Positions.insert_fill/5` が `opts[:exchange_execution_id]` を書き、`(trade_mode, exchange_execution_id)` に部分一意（fill.ex L120-124、20260912130000 L25-29） |
| `Fill.filled_at` がホスト壁時計 | -1 | **解決** | `execution_filled_at/1` が `exec.executed_at` を優先（live_fills.ex L496-497） |
| 残高検査と reserve のねじれ | -1 | **未解決** | risk.ex L497-568 と order_executor.ex L447-472 は変わらず。`Runner.@retryable_limit_kinds` に `:insufficient_balance`（runner.ex L36-40） |
| `FailureRate` に再起動復元が無い | -1 | **解決** | `init/1` → `replace_from_db/2` が rejected Order 窓から warm、失敗は unsynced（failure_rate.ex L168-184, L266-325） |
| `BalanceCache.load_latest/1` が全件読 | -2 | **解決** | `BalanceSnapshot.latest_tips/1`（`DISTINCT ON`）へ委譲（balance_cache.ex L667-672、balance_snapshot.ex L80-95）。索引も 20260911120000 で追加 |
| 永続データの保持方針が無い | -1 | **未解決** | `prod.md` に保持期間の記述なし。P3 #17 未着手 |
| `Fill` が `Order` を文字列参照のみ | -1 | **解決** | `order_id` + `references(:orders, on_delete: :restrict)`（20260912130000 L20） |
| ticker 一本 | -1 | **未解決** | normalize.ex L20-32 は `ltp` / `source_timestamp` のみ |
| `websockex` 0.4 依存 | -1 | **未解決** | mix.exs L38 変更なし。`ci-cd.md` の非保証欄にも無い |
| `read_latest_balances` の生 Ecto + 広い rescue | -1 | **解決** | `BalanceSnapshot.latest_tips/1` へ集約。rescue は `DBConnection.ConnectionError` / `Postgrex.Error` に限定、選定理由も moduledoc に記述 |
| StatusLive に未約定 / 損益 / 不整合が無い | -1 | **解決** | `Observe.Exposure`（314 行）+ StatusLive の建玉 / 未約定 / 当日損益 / halt 復帰手順 |
| `precommit` に `ash.codegen --check` が無い | -1 | **未解決** | mix.exs L47-53 変更なし |
| 開発コンテナが root | -1 | **未解決** | `Dockerfile` に `USER` なし |
| `test_helper.exs` に Sandbox mode が無い | -1 | **未解決** | 1 行のまま |
| API 契約が手書き fixture のみ | -1 | **解決** | `priv/contract/corpus/`（実ホスト採取 + 匿名化 + manifest）と `Contract.check_corpus/1`、`mix bitflyer.contract` |
| `apps/bitflyer/README.md` が TODO テンプレ | -1 | **未解決** | L3 変更なし |

**解決 11 件（-16 点分）/ 未解決 8 件（-8 点分）。** 未解決 8 件のうち 5 件（`ash.codegen`、Dockerfile root、Sandbox mode、`websockex`、保持方針）は 3〜4 サイクル連続で残っている。いずれも 1〜2 行で片付く種類で、前回も同じことを書いた。「improvement-plan の P3 に載っているが着手されない」という運用上の穴が固定化しつつある。P0/P1/P2 を毎サイクル完走する実行力があるのだから、P3 のうち 1 行で終わるものは別枠（「毎サイクル 3 件まで必ず消す」等）にしたほうが早い。
