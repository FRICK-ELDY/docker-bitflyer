# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-10

対象コミット: `490fb5a`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/prod.md](../../architecture/env/prod.md) / [ci-cd.md](../../architecture/ci-cd.md)
前回（自系統）: [opus/archive/2026-09-09](./archive/2026-09-09/opus-specific-weaknesses-2026-09-09.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -33 点**

---

## 技術評価層 — apps/bitflyer

### risk-manager

- **`max_daily_loss` が本番経路で構造的に発火しない（検査は存在するが常に 0 を見る）** `-4`
  > `Risk.authorize/2` の検査列には `check_daily_loss/2` が確かに入っている（risk.ex L59）。しかし損失値の解決は次のとおりで、`:daily_loss` を注入しなければ常に `0` が返る。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L425-429
  >     :error ->
  >       # 損失計測の正本が無い間は 0（未知の損失を捏造しない）。
  >       # 明示注入または将来の Fill / Balance 差分で上書きする。
  >       {:ok, Decimal.new(0)}
  > ```
  >
  > そして `:daily_loss` を注入している呼び出し元は `lib/` 配下に **1 件も無い**（一致するのは `risk_test.exs` L292/L322 と `capital_preservation_test.exs` L436 のテストのみ）。実際の発注経路は `Strategy.Runner.submit_command/1` → `Bitflyer.System.submit_order/1` → `OrderExecutor.submit/2` → `Risk.authorize(command, opts)` で、`opts` は Runner から渡らない（runner.ex L316）。つまり **本番では `daily_loss = 0 > max_daily_loss = 100000` が成立せず、日次損失サーキットは永久に開かない**。`config/config.exs` L50 に `max_daily_loss: "100000"` が書かれ、README L28 は「損失…implemented」と書いているため、「設定してあるから守られている」と誤読される構造になっている。Vision の設計原則 Safety first（「利益より、想定外の損失を止めることを優先する」）と、prod.md L62「注文サイズ、建玉、日次損失、発注回数にハードリミットを置く」の中核が、コード上は空振りしている。サイズ・建玉・頻度は効くので「小口を負け続けても止まらない」が具体的な失敗像になる。
  > 改善方針: 損失の正本を先に作る（後述の約定明細 Resource）。最小実装なら、`BalanceSnapshot`（live は `getbalance` 突合時に毎回 append する）の当日始値と現在値の差、または `Order` の `filled_size`/`price` と `Position` の平均単価から実現損益を日次集計し、`Risk.authorize/2` の既定 opts に注入するヘルパ（`Risk.current_daily_loss/1`）を置く。正本ができるまでは、`max_daily_loss` を「未計測」として `Limits.current/0` で `:unmeasured` を返し、live のときは `authorize` を `{:error, :unsynced, %{reason: :daily_loss_unmeasured}}` に倒す（fail-closed）ほうが、いまの「静かに 0」より安全かつ正直。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `config/config.exs`

- **残高検査も同様に本番経路で無効（`:balances` 未注入でスキップ）** `-2`
  > `check_available_balance/2` は `fetch_balances/1` が空リストを返すと即 `:ok` を返す。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L432-438
  > defp fetch_balances(opts) do
  >   case Keyword.fetch(opts, :balances) do
  >     {:ok, balances} -> {:ok, balances || []}
  >     # ホットパスで DB を叩かない。残高検査は明示注入時のみ。
  >     :error -> {:ok, []}
  >   end
  > end
  > ```
  >
  > 「ホットパスで DB を叩かない」という判断そのものは正しい（ここは加点した）。問題は、**注入する側が本番に存在しない**こと。`OrderRate` は ETS のウォームキャッシュを用意して同じ問題を解いているのに、残高だけはキャッシュが用意されていない。結果として `insufficient_balance` 拒否は live でも paper でも発生しない。overview.md L38 の risk-manager 責務「サイズ、損失、頻度、価格逸脱、**残高**を検査する」のうち残高が抜けたままである。
  > 改善方針: `Risk.OrderRate` と同じ形の `Bitflyer.Risk.BalanceCache`（ETS）を置き、live は突合ごと、paper は擬似約定ごとに書き込む。`authorize/2` は注入が無ければそのキャッシュを読み、キャッシュも空なら live に限り `:unsynced` へ倒す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`

- **連続障害・署名エラーでサーキットが開かない** `-2`
  > `Risk.open_circuit/2` を呼ぶ本番経路は 4 つだけ（`Live.handle_place_error/2` の `submission_unknown`、`Live.place/2` の `persist_failed`、`Live.Cancel.do_cancel/2` の `submission_unknown`、`Risk.check_daily_loss/2` の `daily_loss_exceeded`）。prod.md L64 は「**連続障害、署名エラー、想定外残高変動**でサーキットブレーカを開く」と定めているが、いずれも実装が無い。具体的には、`BITFLYER_API_SECRET` を取り違えた場合、`Rest.request/4` の 401 は `Decode.map_error/2` L169 で `:rejected_by_exchange` になり、`Live.@definite_rejection_reasons` に含まれるため **注文ごとに静かに `rejected` されるだけ**で、halt もアラートも起きない。Runner 側も `:exchange_error` を `@retryable_errors` に入れていないため terminal 扱いにはなるが、別の `internal_order_id` が来れば再び REST を叩く。「鍵が違う」「取引所が連続 5xx」といった、人が即座に気付くべき状況で盲目運転が続く。
  > 改善方針: `Bitflyer.Risk.FailureRate`（ETS のスライディングウィンドウ）を `OrderRate` と同型で追加し、`place_order` / `cancel_order` / `fetch_order` の `{:error, _}` を記録する。窓内 N 回で `open_circuit(:consecutive_exchange_errors)`。401/403 は 1 回で `open_circuit(:auth_failed)` に倒してよい（署名エラーは再試行しても直らない）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **時計ずれ（clock skew）を拒否理由にできない** `-1`
  > 前回指摘から未解決。`clock_skew` / `skew` はリポジトリ全体で 0 件。`Exchange.Auth.timestamp/0`（auth.ex L41-44）は `System.system_time(:millisecond)` をそのまま署名に使うが、取引所時刻との差を測る仕組みが無い。`Cache` が monotonic 時刻を使うため鮮度判定自体は壁時計の跳びに強い（加点済み）が、**署名の失効はホスト時計に直結する**。Vision L122 が本番PC（Windows 11 + WSL2）の時刻ずれを明示的なリスクとして挙げ、prod.md L47 も稼働要件に「時刻同期（NTP 等）が生きている」を入れているのに、生きていることを確認する手段が無い。ずれると 401 が連発し、上記のとおり静かに `rejected` され続ける。
  > 改善方針: `Rest.request/4` のレスポンス `Date` ヘッダとホスト時刻の差を毎回記録し、telemetry イベント（`:clock_skew`）として出す。閾値超過で `Risk` の拒否理由 `:clock_skew` に加え、さらに大きければ `open_circuit(:clock_skew)`。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/auth.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`OrderRate` が ETS のみで、再起動のたびに発注頻度カウンタがゼロに戻る** `-1`
  > `Risk.OrderRate` はテーブルを `:ets.new/2` で作るだけで永続化しない（order_rate.ex L83-85）。プロセスがクラッシュして Supervisor に再起動されると `max_orders_per_minute: 20` の窓が即座に空になる。`Readiness` が起動直後 `:not_ready` で fail-closed のため、実際に上限を素通りするには boot reconcile が毎回通る必要があり、確率は低い。とはいえ「クラッシュループしながら発注し続ける」という、頻度リミットが本来いちばん守りたい場面で無効化されるのは筋が悪い。
  > 改善方針: `Order.inserted_at` に既にインデックスがある（order.ex L19）ので、`OrderRate` の `init/1` で直近 1 分の件数を DB から一度だけ読んで ETS を温める。ホットパスは ETS のままでよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`

### order-executor / live

- **`submission_unknown` から自動回復する手段が無く、人手の紐付け手順も文書化されていない** `-2`
  > 不明状態を作らないこと（halt して再送しない）は正しく実装されており、そこは高く評価した。問題はその**後**である。bitFlyer の `sendchildorder` はクライアント側注文 ID を受け付けず、`Rest.build_send_body/1`（rest.ex L214-231）も `internal_order_id` を送っていない。したがって `submission_unknown` になった注文は `exchange_order_id` が `nil` のままで、取引所側の注文と結び付ける鍵が存在しない。起動突合では、取引所に注文が残っていれば `compare_open_orders/2` の `internal_map` に `nil` キーの行が入り、L299-303 の `open_order_missing_exchange_id` で必ず halt する。安全ではあるが、**halt から抜ける道が無い**。`mix bitflyer.resume` は再突合が成功したときだけ解除するので、この状態では何度叩いても失敗する。prod.md L102-124 の再開手順にも「1. 不整合の原因を直す（残高・建玉・設定・取引所側）」としか書かれておらず、この特定ケース（内部に ID が無い注文をどう始末するか）の具体手順が無い。無人稼働を前提にしている以上、いちばん起きやすい障害の出口が塞がっている。
  > 改善方針: 2 段構え。(1) 発注直後に `getchildorders`（`product_code` + 時刻窓 + `side`/`size` 一致）で候補を引き当てる回収処理を `LiveFills` に足し、一意に決まるときだけ `exchange_order_id` を埋める。(2) 一意に決まらないときのために、`mix bitflyer.orphan` 相当（不明注文の一覧表示と、オペレータが指定した `exchange_order_id` を紐付ける／取引所に無いと確認済みなら `cancelled` に落とす）を用意し、prod.md の再開手順に節を足す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **確定拒否かどうかの判定が取引所エラーメッセージの部分文字列に依存している** `-1`
  > `Decode.map_error/2` は 4xx 本文を小文字化して `String.contains?` で分類する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex L166-171
  > cond do
  >   String.contains?(lowered, "insufficient") -> :insufficient_funds
  >   String.contains?(lowered, "invalid") -> :invalid_order
  >   status == 401 or status == 403 -> :rejected_by_exchange
  >   true -> :rejected_by_exchange
  > end
  > ```
  >
  > ここで返る atom はすべて `Live.@definite_rejection_reasons` に含まれる＝「取引所に注文は無い」と断定する分岐なので、分類ミスは資金保全に直結する。HTTP 4xx が返った時点で未受注なのは事実なので現時点の実害は小さいが、判定根拠が英語メッセージの部分一致であることは脆い（bitFlyer は `status` に数値エラーコードを返す）。加えて 429（レート超過）が `:rejected_by_exchange` に丸められるため、リトライ可能な状況とそうでない状況が区別できない。
  > 改善方針: `status` フィールド（bitFlyer の数値エラーコード）を第一の分類キーにし、メッセージ一致はフォールバックに落とす。429 は `:rate_limited` として別建てにし、Runner の再試行対象に入れる。分類テーブルは fixture テストで固定する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

### market-data

- **WebSocket が「つながったまま無言になる」状態を検知して張り直す仕組みが無い** `-2`
  > `Feed` の再接続トリガは `{:socket_disconnected, reason}` と `{:EXIT, pid, reason}` の 2 つだけ（feed.ex L122-130）。TCP が生きたままフレームが来なくなる（取引所側の配信停止、経路上のアイドル切断、`WebSockex` プロセスの応答不能）と、`state.connected?` は `true` のまま、`reconnect_attempt` も 0 のままで、**Feed は永久に何もしない**。結果は次のとおり。
  >
  > - `Cache` が更新されない → `Risk.check_freshness/3` が全注文を `:stale` で拒否（安全）
  > - `OperationalStatus.classify/4` が `:stale_market_data` → StatusLive は「STOPPED」（可視）
  > - `/health/ready` は 503（外部監視は気付ける）
  > - しかし **Feed 自身は復旧しようとしない**。人が `docker compose restart app` するまで停止したまま
  >
  > 資金保全としては fail-closed で正しい。だが Vision の「24時間365日」「人が張り付かなくても…回し続ける」に対しては明確な未達で、しかも自己修復できる種類の障害である。`gap_fill_on_connect?` も再接続時にしか走らないため、REST による穴埋めも起きない。
  > 改善方針: `Feed` に最終 tick 時刻（`Cache.monotonic_ms/0`）を持たせ、`Process.send_after` の watchdog（例: `market_data_max_age_ms` の 3 倍）で無通信を検知したら `emit_disconnected(:stale_watchdog)` → `stop_socket` → `schedule_reconnect` を走らせる。再接続の副作用として gap-fill も走るので、追加コードは 30 行程度で済む。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **ticker 一本のままで、板・約定ストリームが無く paper の約定モデルが本番と乖離している** `-2`
  > 前回指摘から未解決。`Normalize` は `ltp` 1 フィールドしか取り出さず（normalize.ex L10-20）、購読チャネルも `lightning_ticker_*` のみ。その帰結が `OrderExecutor.Paper` に出ている。`decide_fill/3` は成行を **LTP でそのまま即時全量約定**（paper.ex L70-74）、指値も LTP 交差で **指値ちょうどの価格で全量約定**（L77-88）させる。スプレッド・板の厚み・部分約定・手数料のいずれもモデル化されていないため、paper の損益は本番より必ず楽観になる。overview.md L100「同じ経路を通さないペーパーは、本番で初めて壊れる」の趣旨は経路だけでなく約定モデルにも及ぶはずで、いま paper で戦略を検証しても「勝てるはず」という誤った確信しか得られない。さらに W1（日次損失リミット不発）と組み合わさると、paper 検証で損失シナリオを踏むこともできない。
  > 改善方針: まず `lightning_executions_*` を購読して直近約定を `Cache` に持つ（板より実装が軽い）。paper の約定価格を「直近約定価格 + 固定スリッページ bp + 手数料率」にし、係数は `config` で持つ。板（`lightning_board_snapshot_*` / 差分）は後回しでよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/market_data.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **常時接続の中核が更新の止まった依存（`websockex` 0.4）に載っている** `-1`
  > `apps/bitflyer/mix.exs` L38 で `{:websockex, "~> 0.4"}`。`websockex` は 2019 年の 0.4.3 が最終リリースで、OTP 27 での TLS 既定変更や `:ssl` の非推奨 API 追随が保証されていない。24/365 で張り続ける唯一の外部接続がここに集約されているため、依存の停滞は可用性リスクそのものになる。加えて `mix deps.audit` は Hex advisory しか見ないので、「メンテされていない」ことは CI に一切現れない。実装側は `Bitflyer.MarketData.Socket.Client` behaviour で差し替え可能にしてある（socket/client.ex）ので、移行コストが低い設計になっている点は救い。
  > 改善方針: behaviour の実装を `Mint.WebSocket`（+ 自前 GenServer）または `Fresh` に差し替える。`Socket.Local` がテスト用実装として既にあるので、Feed 側のテストは無改修で通る。移行前でも、依存の保守状況を `ci-cd.md` の「非保証」欄に明記しておくとよい。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket.ex`

### datastore / Ash

- **約定明細（Fill / Execution）が永続化されず、損益も監査証跡も残らない** `-1`
  > `Bitflyer.Trading` の Resource は `Order` / `Position` / `BalanceSnapshot` / `RiskState` の 4 つ（trading.ex L11-16）。`LiveFills.apply_fill_transaction/4` は取引所の約定を `Order.filled_size` と `Position` に畳み込むだけで、`exchange.fetch_executions/1` が返した 1 件ごとの `id` / `price` / `size` / `executed_at`（client.ex L92-100 で型まで定義済み）は**捨てている**。そのため、(a) 実現損益を後から算出できない、(b) 同じ約定を二重に取り込んでいないかを `id` で検証できない、(c) 「いつ・いくらで・どれだけ約定したか」を人が事後に説明できない。Vision の Observable（「約定、拒否、切断、再起動の理由を残す」）のうち約定だけが集計値でしか残らない。W1（日次損失が計測できない）の根本原因でもある。
  > 改善方針: `Bitflyer.Trading.Fill`（`exchange_execution_id` を unique、`order_id` 参照、`price` / `size` / `side` / `executed_at` / `trade_mode`）を足し、`LiveFills` と `Paper` の両方から同一トランザクションで書く。unique 制約が取り込みの冪等性も同時に担保する。日次損益はここから導出する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **戦略パラメータの適用履歴 Resource が無い** `-1`
  > 前回指摘から未解決。overview.md L114-120 が挙げる永続化の最低限 6 項目のうち「戦略パラメータの適用履歴」だけ Resource が存在しない。現在は `config/config.exs` L38-52 のコンパイル時設定（strategy の `size` / `side` / `throttle_ms`、risk の 5 リミット）で、いつ誰がどの値に変えたかは git 履歴にしか残らない。本番はイメージ digest 固定でデプロイするため、「稼働中のコンテナが実際にどの上限で動いているか」を DB から確認する手段が無い。前回は strategy 自体が無かったので軽く扱ったが、いまは `Strategy.Runner` が本番で動いているぶん重みが増している。
  > 改善方針: `Bitflyer.Trading.ParameterRevision`（適用日時・スコープ・値の JSON・適用者・理由）を足し、起動時に現在の実効設定を 1 行書く（前回と同値ならスキップ）。UI に「いま効いている上限」を出せるようになる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `config/config.exs`

- **`Bitflyer.System.Heartbeat` が用途を失ったまま残っている** `-1`
  > 前回指摘から未解決。`Heartbeat` は `note` 文字列 1 個の Resource で、`lib/` 配下に読み書きする箇所が無い（一致するのは `system.ex` の `resource` 宣言と 2 本のマイグレーションのみ）。`Bitflyer.System` は今や `check_database/0` / `health*/1` / `readiness/0` / `submit_order/2` / `resume/1` を並べたファサードで、Ash Domain である必然性は `resources do resource Heartbeat end` を保つためだけになっている。`config/config.exs` L6 の `ash_domains`、CI の `mix ash.setup --domains Bitflyer.System,Bitflyer.Trading`、README L100、entrypoint の 4 箇所がこの残骸に引きずられている。
  > 改善方針: `Heartbeat` を削除し、`heartbeats` を落とすマイグレーションを 1 本足す。`Bitflyer.System` は通常モジュールにして、`ash_domains` と `--domains` 引数を `Bitflyer.Trading` だけにする。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`, `apps/bitflyer/lib/bitflyer/system.ex`, `config/config.exs`

### 復帰と観測

- **停止理由が再起動をまたぐと `risk_halted` に丸められる** `-1`
  > `Circuit.persist_halt/1` は理由をそのまま文字列化して保存する（circuit.ex L107 `reason: Atom.to_string(reason)`）ので、DB には `"submission_unknown"` や `"daily_loss_exceeded"` が入る。ところが読み戻し側は既知 4 種以外を捨てる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L99-105
  > case reason do
  >   "reconcile_mismatch" -> :reconcile_mismatch
  >   "restore_failed" -> :restore_failed
  >   "exchange_unavailable" -> :exchange_unavailable
  >   "risk_halted" -> :risk_halted
  >   _ -> :risk_halted
  > end
  > ```
  >
  > 結果、`submission_unknown` で止まったシステムを再起動すると、StatusLive も `/health` も Discord も「`halted:risk_halted`」としか言わなくなる。いちばん理由を知りたい局面（受注不明で止まった直後の再起動）で理由が消える。`Reconciler.persist_risk_halt/1` 側は逆に `reason_to_string/1`（reconcile.ex L112-118）で未知理由を `"reconcile_mismatch"` に書き換えており、2 つの経路で丸め方も違う。
  > 改善方針: `@known_reasons` に `submission_unknown` / `persist_failed` / `daily_loss_exceeded` / `fill_sync_failed` を加え、それでも未知なら `String.to_existing_atom/1` を `rescue` 付きで試す（`to_atom` は使わない）。丸めた事実自体をログに残す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

---

## 技術評価層 — apps/ui

- **未約定滞留・日次損益・不整合の中身が画面に無い** `-1`
  > `StatusLive` は前回から大きく改善し、発注可否バッジ（status_live.ex L69-94）・モード色分け（L285-292）・Feed・鮮度・DB を出すようになった。ここは加点済み。残る差分は prod.md L72-78 が「最低限、次を見る」とした 6 項目との対比で、画面に出ているのは「WebSocket の切断時間とデータ遅延」だけである。**未約定注文の滞留**（`Order` の `pending` / `partially_filled` 件数と最古の経過）、**内部状態と取引所状態の不一致**（halt 理由の `kind` / `currency` / `product_code`）、**日次損益とリミット接近**が無い。halt 理由も atom 名しか出ないため（L252 `reason_label/1`）、`reconcile_mismatch` としか分からず、どこがずれたのかは結局ログを読むことになる。
  > 改善方針: `OperationalStatus.snapshot/1` に `open_orders`（件数・最古の経過秒）と直近 halt の詳細メタを足し、UI はそれを描くだけにする（現在のロジックレス方針は維持する）。日次損益は W1 の正本ができてから。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **Phoenix 生成テンプレの残骸が運用画面のヘッダを占有している** `-1`
  > 前回指摘から未解決。`Layouts.app/1` のヘッダは `v{Application.spec(:phoenix, :vsn)}`（layouts.ex L42）と Phoenix のマーケティングリンク 3 本（`Website` L49、`GitHub` L53、`Get Started →` L61-63）のままで、`StatusLive` の最上部に出る。BasicAuth を突破して開いた運用者が最初に見るのが「Get Started →」であるのは、画面の文脈を誤らせる。`UiWeb.PageController` / `page_html` はルータのどこからも参照されておらず（router.ex L23-39）、`Ui.Mailer` / `:swoosh` / `/dev/mailbox`（L54）も自動売買システムでは用途が無い。
  > 改善方針: ヘッダを「アプリ名 / 取引モードバッジ / readiness / 言語切替」に置き換える。`PageController` / `page_html` / `Ui.Mailer` / `:swoosh` / `/dev/mailbox` は削除する。
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`, `apps/ui/lib/ui_web/controllers/page_controller.ex`, `apps/ui/lib/ui/mailer.ex`, `apps/ui/mix.exs`

---

## 技術評価層 — 実行基盤 / 設定

- **本番に telemetry の集計先が存在しない（メトリクスがどこにも溜まらない）** `-2`
  > `Bitflyer.Telemetry` は 9 種のイベントを定義し（telemetry.ex L25-34）、`UiWeb.Telemetry.metrics/0` は bitflyer カウンタを 9 本すべて宣言している（ui/telemetry.ex L56-71）。しかし **その metrics を消費する reporter が 1 つも起動していない**。
  >
  > ```elixir
  > # apps/ui/lib/ui_web/telemetry.ex L11-18
  > children = [
  >   {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
  >   # Add reporters as children of your supervision tree.
  >   # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
  > ]
  > ```
  >
  > 唯一の消費者である LiveDashboard は `Application.compile_env(:ui, :dev_routes)` の中にしかマウントされていない（router.ex L42-56）ので、本番イメージには `/dev/dashboard` が存在しない。つまり本番で観測できるのは構造化ログ（`stdout`）と Discord 通知の 2 つだけで、**「WebSocket の切断時間」「拒否の内訳」「リミット接近」のような時系列は一切残らない**。prod.md L72-78 の監視項目のうち、率・推移で見るべきものが全部この穴に落ちる。overview.md L157 の「LiveDashboard の metrics に bitflyer カウンタを載せる」は満たしているが、それが dev 限定であることが文書に書かれていないのも問題。
  > 改善方針: 段階的でよい。(1) `Telemetry.Metrics.ConsoleReporter` を prod でも有効にし、少なくとも数値が定期的にログへ出るようにする。(2) `TelemetryMetricsPrometheus.Core` を足して `/metrics`（BasicAuth 配下、または loopback 限定）を生やす。(3) prod で LiveDashboard を BasicAuth 配下にマウントする判断を `prod.md` に明記する。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`, `apps/ui/lib/ui_web/router.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **`mix precommit` に Ash マイグレーションのドリフト検査が無い** `-1`
  > 品質ゲートは `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `test --warnings-as-errors` の 4 本（mix.exs L47-53）。ここに `mix ash.codegen --check`（未生成のマイグレーションがあれば失敗）が無い。Resource の attribute を変えてもマイグレーションを作り忘れれば、CI はテスト DB を既存マイグレーションから作るため**緑のまま通る**。気付くのは本番で `ash.setup` / `migrate` を回したときか、実際にカラムが無くて落ちたときになる。Ash + AshPostgres 構成でいちばん踏みやすい落とし穴で、しかも 1 行で塞げる。
  > 改善方針: `precommit` に `"ash.codegen --check --domains Bitflyer.System,Bitflyer.Trading"` を `compile` の後に足す（CI と同じ `--domains` 指定でよい）。resource snapshot が既にコミットされているので、追加コストはほぼゼロ。
  > 対象ファイル: `mix.exs`

- **本番イメージのビルドが CI で検証されず、タグを打つまで壊れていても分からない** `-1`
  > `ci.yml` は `mix precommit` だけを回し、`Dockerfile.prod` に一切触れない。`cd.yml` は `v*` タグ push か `workflow_dispatch` でしか動かない（cd.yml L6-15）。つまり `assets.deploy`（tailwind / esbuild のダウンロードを含む）や `mix release`、`rel/overlays/bin/server` の権限付与といった本番固有の工程は、**リリースしようとした瞬間に初めて実行される**。`Dockerfile.prod` は `mix deps.get --only prod` を使うため、`only: [:dev, :test]` 指定の `mix_audit` のように環境差で表面化する問題もここでしか出ない。ロールバック手段が整備されている（`bin/deploy-prod.sh rollback`）ので致命ではないが、「デプロイしたい日にビルドが通らない」は運用上いちばん避けたい失敗。
  > 改善方針: CI に `docker/build-push-action`（`push: false`、`cache-from: type=gha`）で `Dockerfile.prod` をビルドするジョブを足す。`main` への push 時だけでもよい。ビルドしたイメージを起動して `/health/live` を叩くところまで行けば、`prod-entrypoint.sh` と release の起動も同時に守れる。
  > 対象ファイル: `.github/workflows/ci.yml`, `Dockerfile.prod`

- **開発コンテナが root で実行される** `-1`
  > 前回指摘から未解決。`Dockerfile`（開発用）に `USER` 指定が無いため、bind mount した `/app` 配下に root 所有のファイルが作られる。`Dockerfile.prod` は `useradd --uid 1000` で非 root 化されている（Dockerfile.prod L55-66）ので方針自体は理解されており、開発側だけが取り残されている。開発用途としては許容範囲だが、ホスト（WSL2）側で生成物の所有者が食い違うのは日常的な摩擦になる。
  > 改善方針: 開発 `Dockerfile` にも uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` ボリュームの所有者を合わせる。
  > 対象ファイル: `Dockerfile`

---

## 横断評価層

### テスト戦略

- **`test_helper.exs` に Sandbox のモード指定が無い** `-1`
  > 前回指摘から未解決。`apps/bitflyer/test/test_helper.exs` は `ExUnit.start()` の 1 行のみで、`Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` が呼ばれていない。現在は DB を触るテストがすべて `Bitflyer.DataCase` / `UiWeb.ConnCase` 経由で `start_owner!/2` するため実害は出ていない（今回の実行でも 187 + 23 テストが 0 failures）。ただし明示が無いぶん、`use` を書き忘れたテストが 1 本入った時点でテスト DB に実データが残り、しかも他テストの `read_one` が壊れて初めて気付く形になる。1 行で「checkout していないプロセスは DB に触れない」が保証できる。
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加する。
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`

- **取引所 API の契約テストが自作 fixture だけで、実応答との突き合わせ記録が無い** `-1`
  > `Bitflyer.Exchange.Rest` は `:http_client` を差し替えられる良い設計で、`rest_test.exs` も存在する。しかし fixture はすべて手書きで、bitFlyer の実応答から採取したものではない。`Decode` が読むキーは `child_order_acceptance_id` / `executed_size` / `average_price` / `currency_code` / `exec_date` と実 API 依存が濃く（decode.ex L44-147）、しかも `to_decimal/1` が未知の値を `Decimal.new("0")` にフォールバックする（L22）ため、**キー名が変わっても静かに 0 が入る**。`filled_size = 0` が入れば `LiveFills.apply_order_info/3` は「約定なし」と判断するので、実約定を取りこぼす経路になりうる。public API（`/v1/ticker` 等）は dry_run でも叩けるので、記録の仕組み自体は作れる。
  > 改善方針: 実応答を JSON ファイルとして `test/fixtures/bitflyer/` に採取し（キーは伏せる必要が無い public / 匿名化した private）、`Decode` のテストはそのファイルを読む形にする。採取日をファイル名に入れ、定期的に取り直す手順を `ci-cd.md` に書く。あわせて `to_decimal/1` の「未知は 0」を「未知は `:error`」に変え、呼び出し側で `nil` を返して弾く。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/exchange/rest_test.exs`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

### 保守性

- **`Reconcile.read_latest_balances/1` だけが生 Ecto クエリで、例外を広く握っている** `-1`
  > 前回指摘から未解決（コードは 1 文字も変わっていない）。同じモジュール内の他の読み出し（`read_risk_state/0` L351-358、`read_positions/1` L360-367、`read_open_orders/1` L384-392）はすべて `Ash.Query` 経由で `{:ok, _} | {:error, _}` を返すのに、この関数だけ関数内 `import Ecto.Query` + `distinct` の生クエリ + `rescue error -> {:error, error}` で締める。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L369-382
  > defp read_latest_balances(trade_mode) do
  >   import Ecto.Query
  >   query = from(b in BalanceSnapshot, where: b.trade_mode == ^trade_mode,
  >     distinct: b.currency, order_by: [asc: b.currency, desc: b.captured_at])
  >   {:ok, Bitflyer.Repo.all(query)}
  > rescue
  >   error -> {:error, error}
  > end
  > ```
  >
  > `DISTINCT ON` が Ash で書きにくいという事情は理解できるが、**理由がコード上に 1 行も書かれていない**ため、次に読む人は「Ash でも書けるのに手を抜いた」のか「書けないから逃げた」のか判断できない。このモジュールは他の箇所で判断理由を丁寧に残しているだけに、ここだけ浮いている。`rescue` が全例外を捕まえる点も、他の読み出しの `{:error, _}` と粒度が揃っていない（`ArgumentError` のようなプログラミングエラーまで `restore_failed` に化ける）。
  > 改善方針: 最低でも「なぜ Ash ではなく Ecto か」を 1 行コメントで残す。可能なら `BalanceSnapshot` に最新行を引くための識別子（`(trade_mode, currency)` の latest フラグ、または `Ash.Query.sort` + `limit` を通貨ごとに回す）を用意して Ash で完結させる。`rescue` は `Postgrex.Error` / `DBConnection.ConnectionError` に絞る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

### ドキュメント

- **README のコンポーネント表が risk-manager を過大に申告している** `-1`
  > README L28 は risk-manager を `implemented` とし、メモに「サイズ・建玉・**損失**・頻度・価格逸脱・**残高**」と書く。前回「README が実装より古い」と指摘した点は完全に直っており、コンポーネント表という形式も良い（加点済み）。しかし今度は逆方向に 1 行だけずれた。W1 / W2 のとおり損失と残高は本番経路で発火しないため、この表を信じた人は「日次損失で止まる」前提で live 解禁のチェックリスト（prod.md L198-204）を通してしまう。README だけで現状が分かる、という改善の趣旨からいちばん外れるのが、安全装置の過大申告である。
  > 改善方針: 表に `partial` を使う（improvement-plan #14 が元々 `implemented / partial / unavailable` の 3 値を想定していた）。risk-manager を `partial` にし、メモを「サイズ・建玉・頻度・価格逸脱は有効。損失・残高は検査経路のみで計測正本が未実装」に直す。W1 / W2 を解消したら `implemented` に戻す。
  > 対象ファイル: `README.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| 技術評価層 — apps/bitflyer（risk-manager） | -10 |
| 技術評価層 — apps/bitflyer（order-executor / market-data） | -8 |
| 技術評価層 — apps/bitflyer（datastore / 復帰・観測） | -4 |
| 技術評価層 — apps/ui | -2 |
| 技術評価層 — 実行基盤 / 設定 | -5 |
| 横断評価層（テスト戦略 / 保守性 / ドキュメント） | -4 |
| **合計** | **-33** |
