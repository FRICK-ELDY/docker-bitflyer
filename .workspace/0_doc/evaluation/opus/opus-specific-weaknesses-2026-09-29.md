# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-29

対象コミット: `80c486f`（`docs: 作業PCの ready 常駐で監視条件を閉じ、解除手順を残す`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
種別: **同日の上書き再評価**（同日の朝に書いた自系統の下書きを、P1 #3 の実装と P1 #5 の完了宣言の後で採点し直したもの）

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。
行番号は**本サイクルで実際に読んだ箇所**だけを記す。
`mix precommit` は本再評価では**未再実行**。親が #3 実装後に実行して成功（bitflyer doctest 1 + テスト 668、ui 38、失敗 0）を確認済みという情報を受け取っているが、本評価者は再実行していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -8 点**

朝の下書きは -9 だった。差分は 2 件である。

- **`-1` 消滅**: HWM 認可後の強制終了窓。`PeakWriter.enqueue/4` が非 suspend で upsert 成功と ack まで待って `:ok` を返すようになったので、この減点は残さない（strengths `+5` へ移した）。
- **`-2` 消滅 / `-1` 新規**: 別ホスト監視。所有者が P1 #5 の「完了の見方」を「作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残り、解除手順がある」に書き換えた。書き換え後の見方はスクリプトと証跡で満たされているので**完了を採用し、専用監視PCの不在は減点しない**。ただし証跡文書が自分の冒頭に書いた完了条件と矛盾したまま完了を宣言しているので、そこだけ `-1` を新規に計上する。

残る 8 件はいずれも fail-closed 側で、**資金を直接失う経路は本サイクルでも見つからなかった**。

---

## 技術評価層 — apps/bitflyer

### risk-manager / HWM

- **`PeakWriter` の再試行が 50ms 固定で、DB 障害中に毎秒 20 本の `:error` ログを出し続ける** `-1`
  > upsert が失敗すると `persist_attempt/5` が `mark_unsynced/4` を呼んでから `:retry` を返し、`flush_one/1` が 50ms 後に自分へ `:flush` を送る。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/peak_writer.ex L26, L242-245
  > @retry_ms 50
  > ...
  >   :retry ->
  >     state = requeue(state, mode, day, peak, daily_loss)
  >     Process.send_after(self(), :flush, @retry_ms)
  > ```
  >
  > 間隔は固定で、バックオフも上限回数も無い。1 回ごとに `DailyLoss` の `{:peak_persist_failed, ...}` へ `GenServer.call` が飛び（peak_writer.ex L330）、受け側は同日なら**そのつど無条件に** `:error` で記録する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L751-755
  > Bitflyer.Telemetry.log(
  >   :error,
  >   "daily equity peak persist failed; marked unsynced",
  >   %{reason: inspect(reason), trade_mode: trade_mode, trading_day: Date.to_iso8601(day)}
  > )
  > ```
  >
  > DB が数分落ちれば同一メッセージが数千行積まれる。本番の metrics / ログ出口は `ConsoleReporter` と stdout（overview L167）なので、**障害の原因行がこの繰り返しで埋まる**。資金は守られる（当該モードは unsynced で認可拒否）ので `-2` ではないが、Observable の観点では「落ちているあいだにログが読めない」のは実害である。あわせて毎秒 20 回の `GenServer.call` が `DailyLoss` の処理キューを占め、同プロセスは認可の `prepare_peak`（daily_loss.ex L675）も捌く。
  >
  > 2 回目以降の情報量はゼロである。`{:peak_persist_failed, ...}` は既に `synced: false` の行へ同じ値を書き直すだけで、状態遷移が無い（daily_loss.ex L745-757）。
  >
  > 改善方針: `@retry_ms` を指数バックオフ（50ms → 上限 5s）にし、同一 `{mode, day, reason}` の `peak_persist_failed` ログは最初の 1 回と間隔つきの再掲だけにする。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **認可ホットパスが DB 往復するようになったのに、`Risk` の moduledoc と overview は「往復しない」と述べたまま（新規）** `-1`
  > P1 #3 の直し方そのものは正しい（strengths `+5`）。問題は、その直しが**このシステムで最も強く明文化されていた不変条件を反転させたのに、正本の記述が 1 箇所だけ更新されていない**ことである。
  >
  > 実装は同期になった。認可の `check_daily_drawdown/2` が `persist: false` + `write_behind: true` で `Equity.enforce/1` を呼び（risk.ex L660-671）、`DailyLoss.schedule_write_behind/4` が `PeakWriter` へ 5 秒タイムアウトの `GenServer.call` を出し（daily_loss.ex L393-403）、`handle_call({:enqueue, ...})` の非 suspend 節が `persist_attempt/5` を**返答より前に**実行する（peak_writer.ex L163-175）。つまり認可は DB の `INSERT ... ON CONFLICT` 1 往復（daily_equity_peak.ex L102-131）を待つ。
  >
  > 修正コミットは `daily_loss.ex` と `equity.ex` の moduledoc を書き換えたが、`risk.ex` は取り残されている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L27, L30-31（現在も残っている記述）
  > 発注ホットパスでは RiskState・発注頻度・日次損失・残高・HWM 永続化のために DB 往復しない。
  > ...
  > ドローダウン HWM の上昇は認可では ETS のみ。同期の `DailyEquityPeak` upsert はせず、
  > 監督下 `PeakWriter` へ単調 upsert を cast する。
  > ```
  >
  > 「cast する」は現在の実装では偽である。`architecture/overview.md` L97 の「板・Ticker・判定ループは ETS または GenServer に置き、ホットパスから Resource を呼ばない」も、判定ループが単一 GenServer 経由の DB 書き込みでブロックしうる現状に対して更新されていない。
  >
  > これは表記の好みではなく、**次に触る人が誤った前提で最適化・変更を入れる**種類の齟齬である。実際に測るべき値（新高値ごとに 1 往復、失敗・遅延時は最大 5 秒で `:unsynced` へ倒れる）が、モジュールの正本に書かれていない。トレードオフ自体は Safety first として正しいのだから、そう書けばよい。
  >
  > 改善方針: `risk.ex` の当該 3 行を「HWM の上昇だけは DB upsert 成功まで待つ（失敗・5 秒超は `:unsynced` で拒否）。他の検査は ETS のみ」に差し替え、overview L97 に同じ例外を 1 行足す。`:write_behind` というオプション名も実態は write-through なので、あわせて改名する（提案参照）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `.workspace/0_doc/architecture/overview.md`

**小計: -2 点**

### order-executor / 手数料会計

- **一次証跡は `BTC_JPY` 1 銘柄なのに、live 認可は spot allowlist 8 銘柄をそのまま通す** `-1`
  > P0 #1 は実測で閉じた（strengths `+5`）。残る穴は**証跡の適用範囲と、認可が許す範囲がずれている**ことである。
  >
  > 手数料通貨は銘柄種別だけで決まる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L114-119
  > def fee_currency(product_code) when is_binary(product_code) do
  >   case market_type(product_code) do
  >     :spot -> base_currency(product_code)
  >     _ -> quote_currency(product_code)
  >   end
  > ```
  >
  > `@spot_products` は `BTC_JPY` / `ETH_JPY` / `XRP_JPY` / `XLM_JPY` / `MONA_JPY` / `BCH_JPY` / `ETH_BTC` / `BCH_BTC` の 8 件（product.ex L12-21）。live のゲートは `Product.spot?/1` だけを見る（risk.ex L262 の `check_live_product/2`、product.ex L66-67）。起動時検査も同じで、`LiveSafety.assert_live_products!/1` は `spot?` で弾くだけである（live_safety.ex L60-72）。
  >
  > 一方でコードと証跡は、他ペアが仮定であることを自ら書いている。
  >
  > ```
  > # apps/bitflyer/lib/bitflyer/trading/product.ex L108-110
  > - `:spot` — 当面 base。BTC_JPY は 2026-09-28 の実測で、買い `+S−C` / `−S·P`、
  >   売り `−(S+C)` / `+S·P`。`ETH_JPY` など他の spot はペア別の非ゼロ execution が
  >   無く、同じ式は仮定である
  > ```
  >
  > 証跡側も同じ（commission-unit-evidence.md L63「`ETH_JPY` 等の単位は未実測で、余白だけこの上限を使う」）。`MarketData.product_codes` を `ETH_JPY` に変えるだけで、**P0 #1 が閉じる前の BTC_JPY と同じ状態（推定の会計モデルで live 発注）へ戻れる**。実害は突合の `balance_mismatch` halt であって資金喪失ではないが、わざわざ実口座を往復して閉じた規律を認可側が引き継いでいない。
  >
  > 改善方針: `Product` に「一次証跡のある銘柄」集合（当面 `BTC_JPY` のみ）を持ち、`check_live_product/2` と `assert_live_products!/1` がそちらを見る。新しいペアは `commission-unit-evidence.md` に実測表を足してから集合へ入れる。live 対象は既定 `BTC_JPY`（overview L113）なので運用上の制約にはならない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

**小計: -1 点**

### strategy

- **戦略が `FixedOnce` 1 本だけで、live で有効化できる戦略が依然ゼロ（継続）** `-1`
  > `apps/bitflyer/lib/bitflyer/strategy/` は `runner.ex` / `fixed_once.ex` / `revision.ex` の 3 本のまま（本サイクルで再確認）。起動側は二重に禁止している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/config/live_safety.ex L93-98
  > def assert_strategy_allowed!(true, Bitflyer.Strategy.FixedOnce) do
  >   raise ArgumentError, """
  >   Bitflyer.Strategy.FixedOnce cannot be enabled when TRADE_MODE=live.
  >
  >   Leave BITFLYER_STRATEGY_ENABLED unset (strategy stays disabled) for observe-only live,
  > ```
  >
  > 方針違反ではない（Vision L28 が戦略の中身を後続バックログへ送っている）。しかし「起動 → 購読 → 判定 → リスク → 発注/記録 → 突合 → 停止/再開」（evaluation.mdc L151）のうち**判定だけが配管疎通用のダミー**であり、live 解禁を議論している段階で解禁しても動かせる戦略が無い。安全側の土台は十分厚いので、明示的なエントリ / エグジットを持つ薄い戦略 1 本が通れば、この減点は加点へ反転しうる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

**小計: -1 点**

### 可観測性（RiskState）

- **`halted_at` が周期突合のたびに上書きされ、「最初にいつ止まったか」が残らない** `-1`
  > `Reconciler` の突合が失敗するたびに失敗節が `persist_risk_halt/1` を呼び、`halted_at` を現在時刻で書き直す。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconciler.ex L390-398, L411-414
  > defp persist_risk_halt(reason) do
  >   halted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
  >
  >   attrs = %{name: "default", halted: true, reason: ..., halted_at: halted_at}
  > ...
  >   {:ok, %RiskState{} = risk} ->
  >     case risk
  >          |> Ash.Changeset.for_update(:update, Map.take(attrs, [:halted, :reason, :halted_at]))
  > ```
  >
  > `RiskState` は `name == "default"` の単一行で履歴を持たない。`balance_mismatch` のように突合が繰り返し失敗する停止では、周期実行のたびに `halted_at` が前進する。夜間に止まって朝に気付いたとき、DB に残るのは「たった今止まった」という記録だけで、**実際の停止時刻は失われている**。
  >
  > 同じ経路の成功側は正しく書かれているのが対照的である。`{:ok, %RiskState{halted: true}}` の節は「成功突合は停止を解除しない。解除は Resume だけ」として何も書かない（reconciler.ex L380-383）。**解除しない規律はあるのに、停止の起点を保つ規律が無い。**
  >
  > Vision の Observable（L36「約定、拒否、切断、再起動の理由を残す」）に対して、**理由は残るが時刻が残らない**。停止と相場・WS 断の時系列を後から突き合わせられないのは、事後説明の土台を欠く。
  >
  > 改善方針: `persist_risk_halt/1` を「既に `halted: true` かつ同一 `reason` なら `halted_at` を触らない」条件付き更新にする（理由が変わったときだけ更新）。厚くするなら `halt_events` 追記テーブル（提案参照）。前者は 5 行で閉じる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

**小計: -1 点**

---

## 技術評価層 — 実行基盤 / 設定

- **開発 `Dockerfile` が root で実行される（継続）** `-1`
  > 開発 `Dockerfile` は全 20 行で `USER` 指定が無い（L1-20 を再読）。`compose.yaml` はリポジトリを bind mount するので、`priv/static/assets` や `priv/contract/corpus`、`/app/.data/hwm-drain-halt` が root 所有でホスト側に生まれる。
  >
  > `Dockerfile.prod` は uid/gid 1000 のユーザーへ `--chown=app:app` で配り、`USER app` まで付けている（Dockerfile.prod L61-67）。本番 Compose は `halt_marker` ボリュームを使い捨てサービスで `chown 1000:1000` までしている（compose.prod.yaml L46）。方針は完全に理解されていて、**開発側だけが取り残されている**。
  >
  > 改善方針: 開発 `Dockerfile` に uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる（`bin/docker-entrypoint.sh` で `chown` するか `compose.yaml` に `user: "1000:1000"`）。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

**小計: -1 点**

---

## 横断評価層

### 変更容易性・保守性

- **常時接続の中核が `websockex` に載ったままで、その事実が `architecture/` に 1 行も無い（継続）** `-1`
  > `apps/bitflyer/mix.exs` L38 の `{:websockex, "~> 0.4"}` は不変。`mix.lock` L56 は 0.5.1 なので制約と lock がずれたまま緩い。
  >
  > 「常時張る唯一の外部接続が 1 依存に集約されている」「`mix deps.audit` は Hex advisory しか見ないのでメンテ停滞は CI に出ない」の 2 行が、`architecture/` にも `socket.ex` の moduledoc にも無い。
  >
  > コード側の設計はむしろ良く、`Socket.Client` behaviour で差し替え可能なので**移行コストは既に低い**。にもかかわらず記録だけが残らない、という運用構造の問題である。
  >
  > 改善方針: `mix.exs` の制約を `~> 0.5` へ上げて lock と揃え、`ci-cd.md` の非保証欄に 1 行、`socket.ex` の moduledoc に既知リスクとして 1 行。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `.workspace/0_doc/architecture/ci-cd.md`

**小計: -1 点**

### プロジェクト全体設計・プロセス

- **`watch-ready-evidence.md` が自分の冒頭に書いた完了条件と矛盾したまま「完了」を宣言している（新規）** `-1`
  > **この減点は専用監視PCの不在に対するものではない**（所有者が見方を書き換えたので、それは評価しない）。文書が同一ファイル内で自分の判定基準を否定していることに対するものである。
  >
  > 冒頭は今も次のとおりである。
  >
  > ```
  > # .workspace/0_doc/architecture/env/watch-ready-evidence.md L6-7
  > 完了条件は **取引ホストが死んでも、外の監視ホストが非 ready / 到達不能を残す** こと。
  > 同一ホストの Compose healthcheck や localhost cron では閉じない。
  > ```
  >
  > 本サイクルで追記された完了宣言は、その「閉じない」と書かれた構成そのものである。
  >
  > ```
  > # .workspace/0_doc/architecture/env/watch-ready-evidence.md L97-99, L105
  > ## 常駐（2026-09-29）
  >
  > 作業 PC `FRICK` に、開発 Compose の `http://127.0.0.1:4000/health/ready` へ向いた常駐を登録した。P1 #5 はこの配備で完了とする。
  > ...
  > | READY_URL | 開発 Compose `127.0.0.1:4000/health/ready` |
  > ```
  >
  > 書き換え後の見方（作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残り、解除手順がある）を満たす証拠は揃っている。タスク名と常駐化は `bin/register-watch-ready-task.ps1` L43-54（`New-ScheduledTaskTrigger -AtLogOn`、`RestartCount 3`、`Register-ScheduledTask -TaskName "BitflyerWatchReady"`）、`READY_URL` を含む wrapper を `%LOCALAPPDATA%` に置く扱いは同 L19-41、解除は `bin/unregister-watch-ready-task.ps1` L18-32（停止 → `Unregister-ScheduledTask` → wrapper 削除、証跡ログは残す）で、`prod.md` L150 にも解除行が追記されている。証跡ログの失敗 2 行は L107 に記録されている。**だから P1 #5 の完了は採用する。**
  >
  > 残る問題は、evaluation.mdc L305 が「基準を下げるときは、先に『完了の見方』を書き換えてから状態を付ける」と要求しているのに対し、**書き換えが improvement-plan 側だけで行われ、証跡文書の完了条件が旧基準のまま残った**ことである。この状態の文書を次サイクルの評価者（あるいは半年後の本人）が読むと、L6-7 を基準に L97-105 を読んで「これは完了ではない」と判定する。2 つの基準が同居している文書は、完了宣言の再検証という手続き自体を壊す。
  >
  > 改善方針: L6-7 を現在の見方へ書き換え、旧基準は「次の段（VLAN1 本番 PC を `READY_URL` にしたホスト死検知）」として L110 の「まだ閉じないこと」へ移す。2 行の移動で閉じる。同時に、L107 の証跡が `http=000`（到達不能）2 行だけで、登録後に `"status":"ready"` を引けた行が 1 つも無いことも書き添えると、記録としての精度が上がる。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

**小計: -1 点**

---

## 小計一覧

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer — risk-manager / HWM | -2 |
| apps/bitflyer — order-executor / 手数料会計 | -1 |
| apps/bitflyer — strategy | -1 |
| apps/bitflyer — 可観測性（RiskState） | -1 |
| 実行基盤 / 設定 | -1 |
| 横断（変更容易性・保守性） | -1 |
| 横断（プロジェクト全体設計・プロセス） | -1 |
| **合計** | **-8** |

---

## 朝の下書きからの差分（同日の再読で確認）

| 下書きの指摘 | 下書き | 再読後 | 根拠 |
|:---|:---:|:---|:---|
| ノード強制終了で `DailyLoss` と `PeakWriter` の両メモリが消える窓 | -1 | **消滅（減点しない）** | `peak_writer.ex` L163-175 が非 suspend で `persist_attempt/5` を返答前に実行。`enqueue` の doc（L43-44）が「upsert 成功と ack まで待って `:ok`」。失敗は `{:error, :unsynced}`。`peak_writer_test.exs` L139-158 が `:ok` 後に `Process.exit(pid, :kill)` → `DailyLoss.reinit()` で 160000 の復元を固定 |
| 別ホスト監視が未配備 | -2 | **消滅（見方の書き換えを受けて採用）** | `watch-ready-evidence.md` L97-108 の常駐記録、`register-watch-ready-task.ps1` L43-54、`unregister-watch-ready-task.ps1` L18-32、`prod.md` L150 |
| `PeakWriter` の 50ms 固定再試行とログ増幅 | -1 | **据え置き** | `peak_writer.ex` L26, L242-245 / `daily_loss.ex` L751-755 |
| 一次証跡 `BTC_JPY` のみで認可は spot 8 銘柄 | -1 | **据え置き** | `product.ex` L12-21, L108-119 / `risk.ex` L262 / `live_safety.ex` L60-72 |
| `halted_at` 上書き | -1 | **据え置き** | `reconciler.ex` L390-398, L411-414 |
| 戦略が `FixedOnce` 1 本 | -1 | **据え置き** | `strategy/` 3 ファイル / `live_safety.ex` L93-98 |
| 開発 `Dockerfile` root | -1 | **据え置き** | `Dockerfile` L1-20 に `USER` なし |
| `websockex` の記録なし | -1 | **据え置き** | `mix.exs` L38 / `mix.lock` L56 |
| — | — | **新規 `-1`** | 認可が DB 往復するのに `risk.ex` L27, L30-31 が「往復しない / cast する」のまま |
| — | — | **新規 `-1`** | `watch-ready-evidence.md` L5-6 と L97-104 が同一ファイル内で矛盾 |

**消滅 2 件（-3 点分）/ 据え置き 6 件（-6 点分）/ 新規 2 件（-2 点分）。差引 -9 → -8。**

新規 2 件は、どちらも**直したこと自体は正しいのに、その直しに合わせて正本の記述が更新されていない**という同じ形をしている。コードが先に進み、文書が 1 歩遅れている状態である。
