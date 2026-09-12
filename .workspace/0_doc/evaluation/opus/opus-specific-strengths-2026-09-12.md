# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-12

対象コミット: `1cfb413`（`Merge pull request #86 from FRICK-ELDY/fix/p2-deps-audit-gate`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-10_2](./archive/2026-09-10_2/opus-specific-strengths-2026-09-10_2.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。すべての判定は当該コードの再読に基づく。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 些細だが良い。標準的な良習慣を守っている |
| +2 | 明確に良い。設計意図が読み取れ、代替案より妥当 |
| +3 | 優れている。同種の個人プロジェクトでは通常見られない配慮 |
| +4 | 卓越。商用システムと比べても遜色ない設計・実装 |
| +5 | 傑出。このクラスの個人プロジェクトでは見たことがないレベル |

**合計: +203 点**

比較軸は同種の自動売買 bot / OTP 常駐システム / Phoenix 運用基盤である。前回の +185 から 18 点増。加点の中心は order-executor（+40）と risk-manager（+35）で、前回 live ブロッカーだった 2 件をどちらも「回避」ではなく「設計の作り直し」で閉じたことを反映している。

---

## 技術評価層 — apps/bitflyer

### market-data

- **Feed の再接続・REST gap-fill・stall watchdog を 1 プロセスで閉じた構成** `+3`
  > `MarketData.Feed` は WS 切断時に指数バックオフで再接続し、再接続の穴を REST `getticker` で埋め、さらに「接続しているのにメッセージが来ない」状態を watchdog で検出して切断扱いに落とす。WS 常駐系で最も見落とされるのが 3 番目（TCP は生きているが板が止まる）で、それを最初から入れているのは常駐運用を実際に想定した設計である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **取引所時刻を `source_timestamp` として保持し、欠落は `nil` のまま Risk 側で fail-closed にする** `+3`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/normalize.ex L4-8
  > `ltp` に加え、取引所 `timestamp` を `source_timestamp`（UTC `DateTime`）として保持する。
  > 公開 ticker のオフセット無し日時は UTC とみなす（Private API の JST 契約とは別）。
  > 欠落は `nil`（Risk の skew は fail-closed）。
  > ```
  > オフセット無し日時を公開 API では UTC、Private API では JST と扱い分ける判断を明示的に書いている。取引所 API を実際に触った者にしか書けない区別で、しかも「欠落を 0 や現在時刻で埋めない」を貫いている。`cast_source_timestamp/1` は「値が有るのにパースできない場合のみ `:error`」という非対称も意図的に選んでいる（L81-101）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **`Cache` が鮮度付き ETS で、消えても再構築できる位置に置かれている** `+2`
  > `fresh?/3` / `entry_fresh?/3` が monotonic 時刻で判定し、保存値は `Decimal`。Feed から独立した ETS なので Feed が落ちても値は残り、古くなれば自動的に「使えない」に変わる。「揮発するが復元可能」と「永続だが正本」の切り分けが一貫している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

### strategy

- **strategy が取引所 API を直接叩けない境界設計** `+3`
  > `Strategy` behaviour が受け取るのは市場スナップショットと現在状態で、戻すのは意図（command）だけ。発注は `Runner` → `System.submit_order` → `Risk.authorize` → `OrderExecutor` の 1 本道を必ず通る。「戦略が勝手に注文を出せる」構造を最初から作っていないので、Risk を迂回する経路が物理的に存在しない。`Runner` 側も `@retryable_errors` と `terminal_rejection?/1` で「一時的な失敗は再試行、確定拒否は settled、未知理由は throttle 付き再試行（誤って永続停止しない）」を分類しており、分類の既定値の向きも正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **戦略パラメータの改訂を永続化し、Order 側にも適用改訂を記録する** `+2`
  > `StrategyParameterRevision` と `Order` の戦略 3 属性により、「どの注文がどのパラメータで出たか」が後から辿れる。バックテストや事後検証を前提にした記録設計で、パラメータをコードに直書きして終わる実装とは水準が違う。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`, `apps/bitflyer/lib/bitflyer/strategy/revision.ex`

- **live では戦略が既定で無効、`FixedOnce` は起動ごと拒否される** `+4`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/config/live_safety.ex
  > # live では戦略は既定オフ。BITFLYER_STRATEGY_ENABLED=true の明示が必要。
  > # FixedOnce（検証用）は live で有効化できない。
  > ```
  > 「検証用戦略が本番で動く」という最も起こりやすい事故を、env 1 個の取り違えでは起こせない形にしている。加えて `BITFLYER_MAX_*` 6 本（order_size / position_size / daily_loss / daily_drawdown_jpy / orders_per_minute / price_deviation_pct）を live で必須にし、形式検証まで行って未設定なら**起動を止める**。開発既定の 1 BTC が本番に漏れる経路を塞いでいる。「安全側の既定値」ではなく「明示しなければ起動しない」を選んだのが正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### risk-manager

- **live の対象銘柄を spot allowlist に限定する二重ゲート（P0 #1 の前回ブロッカー解消）** `+4`
  > 前回「既定 FX にスポット残高モデルを適用している」を -3 とした箇所が、起動時と認可時の 2 段で塞がれた。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/product.ex
  > @spot_products MapSet.new(["BTC_JPY", "ETH_JPY", ...])
  > def market_type(code) do
  >   cond do
  >     MapSet.member?(@spot_products, code) -> :spot
  >     fx_or_cfd?(code) -> :fx
  >     true -> :unsupported
  >   end
  > end
  > ```
  > 未登録銘柄が黙って spot 扱いにならず `:unsupported` になる点が重要である（allowlist の既定が「拒否」側）。起動時は `LiveSafety.assert_live_products!/1` が空 / 非 spot で raise、実行時は `Risk.check_live_product/2` が認可を拒否する。`config.exs` の `product_codes: ["BTC_JPY"]`、README、overview.md の 3 つが同じことを言っており、宣言とコードの乖離が無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`OrderRate` の原子的枠予約（reserve / commit / release）で check-then-act を排除（P0 #4）** `+4`
  > 前回まで「窓内件数を数えてから発注する」だったため、並行時に上限超過が通り得た。今回は枠の確保を GenServer 境界の内側に閉じている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/order_rate.ex
  > def handle_call({:reserve, trade_mode, now_ms, limit, window_ms}, _from, state) do
  >   prune(...)
  >   count = count_window(...)
  >   if count < limit do
  >     ref = make_ref()
  >     :ets.insert(table, {key, ref, :reserved, now_ms})
  >     {:reply, {:ok, ref}, state}
  >   ...
  > ```
  > 秀逸なのは warm の扱いで、`replace_from_db/2` は `:committed` 行だけを削除して**進行中の予約を残す**。起動直後の DB 同期が in-flight な予約を消してしまう事故を最初から避けている。warm 失敗時は `synced: false` にして `reserve` が `{:error, :unsynced}` を返す（数えられないなら出さない）。`Risk.authorize` は予約後の全失敗経路で `release/1` を呼ぶので、枠のリークも無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`Risk.Equity` による実現＋含み損の日次ドローダウンゲート（P2 #11）** `+4`
  > `drawdown = 当日ピーク − equity_pnl`、`equity_pnl = 実現 net + 含み損益（Position × LTP）` という定義で、「実現損は小さいのに含み損で口座が溶ける」を止められるようにした。個人 bot が最も落ちる穴である。
  >
  > 実装の質が高いのは stale 方針を 3 層に分けたところである。`authorize` と `resume` は `snapshot` の `:unsynced` / `:stale` を fail-closed で拒否し、周期実行の `enforce/1` は「既に halt 済み / 鮮度切れ / 未同期のときは halt しない」（価格が取れないだけで勝手に止めない）。さらに `mark_position/2` は未知 side を 0 ではなく `:unsynced` に落とす。「わからないときに 0 とみなす」を全経路で避けており、これは前回の累積 VWAP 問題と同じ種類の誤りを構造的に排除している。表示専用の `record_peak: false` を用意して、画面表示がピークを書き換えないようにしている点も丁寧である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/equity.ex`

- **`FailureRate` の起動 warm と未同期 fail-closed（P1 #7）** `+3`
  > `init/1` が trade_mode ごとに `status == :rejected` の Order を窓幅ぶん読み戻し、warm に失敗したら `synced: false` にして `evaluate` が `{:halt, :failure_rate_unsynced}` を返す。「再起動でサーキットが緩む」を塞いだ。時間軸に `updated_at` を採ったこと、`:order_not_found` を意図的に計上対象外にしたこと、「rejected 全件を数えるので過大側 = 安全側」という残差を moduledoc に自認していることまで含めて、判断の跡が読める。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`

- **`OpenOrderPolicy` + `HaltCancelGate` による「halt の出口」設計（P1 #10）** `+4`
  > halt 理由ごとに cancel-all するかを config の真偽値表で持ち、`after_halt` は `force: true` で実行し、さらに `ensure_halt_cancels` を起動時・`CircuitSync` 経由・`halt_trading` の 3 経路から呼ぶ。「halt したが未約定が板に残ったまま誰も取消さない」という現実の事故を、複数の入口から冪等に回収する形にしている。
  >
  > `HaltCancelGate` の状態機械（in-flight ロック + `Task` の monitor + バックオフ 30s + `:cleared` で省略 + `in_flight_stale_ms` 600s で失効）も、取消が失敗し続ける場合に REST を叩き潰さないよう設計されている。テストログに `HaltCancelGate cancel worker died before finish` が出ており、worker 死亡経路まで回帰で踏んでいることが確認できた。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/open_order_policy.ex`, `apps/bitflyer/lib/bitflyer/risk/halt_cancel_gate.ex`

- **`BalanceCache` の hold（予約）会計** `+4`
  > 単に残高をキャッシュするのではなく「注文で拘束中の額」を hold として持ち、約定に応じて `consume_hold_proportional` / `align_hold_to_filled` で按分消費し、取消・失効で `release` する。売り注文では base 通貨を、買い注文では quote 通貨を拘束するという通貨方向の扱い分けもある。取引所残高が更新される前の短い窓で過剰発注しないための会計であり、個人 bot にはほぼ無い層である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **テスト注入が本番では物理的に効かない構造** `+3`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex
  > # :daily_loss / :balances / :positions / :recent_order_count は
  > # allow_test_injections: true のときだけ尊重する。
  > ```
  > `allow_test_injections` が無ければ注入 opts を無視して正本を読む。テスト容易性のために作った穴を、本番で踏めない形に閉じている。「テスト用フックが本番設定で有効になっていた」という古典的事故を設計で防いでいる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **`HaltReason` allowlist と `HaltRecovery` の理由 → 復帰手順マッピング** `+3`
  > halt 理由を allowlist（`to_existing_atom` + rescue）で閉じ、未知理由は `:invalid_halt_reason` に落とす。DB や外部から任意 atom が入って atom テーブルを汚す経路を塞いでいる。さらに `HaltRecovery` が理由ごとに復帰手順（順序付きステップ）を返し、UI がそれを人間語で出す。「止まった。で、どうすればいい？」に機械可読で答える仕組みは、商用の運用基盤でもしばしば欠けている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/halt_reason.ex`, `apps/bitflyer/lib/bitflyer/risk/halt_recovery.ex`

- **`Circuit` / `CircuitSync` による別 BEAM の halt 反映** `+3`
  > `mix bitflyer.halt` のような別プロセスからの停止が RiskState に書かれ、稼働中のノードが `CircuitSync` で ETS に取り込む。「Docker の外から緊急停止できる」と「稼働ノードがそれを即座に見る」を両立させており、キルスイッチの経路が UI 依存になっていない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit_sync.ex`

- **認可検査の順序と fail-closed の一貫性** `+3`
  > `authorize/2` は validate → live 銘柄 → sync → 失敗率 → 鮮度 → 時計ずれ → 注文サイズ → 建玉サイズ → 価格乖離 → レート枠予約 → 日次損失 → ドローダウン → 残高、という順で `with` を積む。安い検査を先に、副作用を伴う予約を後に置く順序が正しく、予約後のどの失敗でも `OrderRate.release` を通す。各検査が「わからない → 拒否」に倒れており、例外扱いが無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

### order-executor

- **live 約定を execution 単位で記帳する増分価格モデル（P0 #1 の前回ブロッカー解消）** `+5`
  > 前回 -2 とした「複数回の部分約定で累積 VWAP を増分価格として使う」を、部品の差し替えではなく記帳モデルの作り直しで解いている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex L466-494
  > defp apply_one_execution(%Order{} = order, info, exec) do
  >   fill_price = exec.price
  >   new_filled = Decimal.add(order.filled_size || Decimal.new("0"), size)
  >   new_notional =
  >     Decimal.add(order.filled_notional || Decimal.new("0"), Decimal.mult(fill_price, size))
  >   delta_order = %{order | size: size, filled_size: size}
  >   ...
  > ```
  > 評価すべき点が 4 つある。(1) `getexecutions` の明細 1 件ずつをその約定価格で記帳するので、VWAP の再計算という概念自体が消えた。(2) `filled_size` と `filled_notional` を**対で**進め、`ensure_consistent_filled_baseline/1` が「片方だけ正の値」という状態では増分計算を拒否する。(3) `ensure_execution_coverage/4` が「明細 id 欠落」「明細合計 ≠ 取引所 filled」「新規明細合計 ≠ 差分」の 3 条件で fail-closed し、500 件到達時は `:execution_page_may_be_truncated` のヒントまで付ける。(4) 全体が 1 トランザクションで、`DailyLoss` 更新は世代 barrier で守られる。
  >
  > 回帰テストの張り方も水準が高い。`successive partial fills use incremental prices for position VWAP` / `partial open then partial close keeps realized_pnl and DailyLoss consistent` / `filled_notional survives DB reload between successive partial fills` の 3 本が、この設計が守るべき不変条件をそのまま検査している。最後の 1 本（DB 往復を挟んでも増分が壊れない）は、ETS 上でしか成立しない実装を弾く意図で書かれており、テスト設計者が failure mode を理解している。資金保全の中核でこの厳密さに達しているのは、このクラスのプロジェクトでは見たことがない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **`(trade_mode, exchange_execution_id)` 部分一意 + `order_id` FK + 取引所時刻という Fill 証跡（P1 #8）** `+4`
  > 前回 -1 が 3 件（execution id が常に nil / `filled_at` がホスト壁時計 / Order を文字列参照のみ）あった箇所が、まとめて閉じた。
  >
  > ```elixir
  > # priv/repo/migrations/20260912130000_add_fills_execution_evidence.exs
  > add :order_id, references(:orders, type: :binary_id, on_delete: :restrict)
  > create unique_index(:fills, [:trade_mode, :exchange_execution_id],
  >          where: "exchange_execution_id IS NOT NULL")
  > ```
  > `nils_distinct?: true` の部分一意で「paper は nil のまま / live は取引所 id で二重記帳不可」を 1 本のインデックスで両立させている。`on_delete: :restrict` は「約定証跡がある注文は消せない」という意思表示で、`cascade` を選ばなかったのが正しい。さらに `Positions` が `duplicate_execution_error?` / `constraint_name_collision?("unique_trade_mode_exchange_execution_id")` で制約違反を多層に識別し、重複を「エラー」ではなく「既に記帳済み」として扱えるようにしている。DB 制約とアプリの冪等性が同じ方向を向いている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `priv/repo/migrations/20260912130000_add_fills_execution_evidence.exs`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **旧 Fill（execution id が nil）の上に追加約定を載せることを明示拒否し、デプロイ前確認 SQL を残している** `+2`
  > `has_legacy_nil_execution_fills?/2` が live で id nil の Fill を検出したら `:legacy_nil_execution_id` で同期を拒否する。さらに `Fill` の moduledoc とマイグレーションに、デプロイ前に流すべき確認 SQL が書かれている。「スキーマを変えたが既存データがどうなるか」まで面倒を見た移行設計であり、個人プロジェクトでほぼ見ない配慮である。テストログにも `live fill refused: legacy nil exchange_execution_id baseline` が出ており、経路が回帰で踏まれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **認可前 fill 同期の単一化と、post-place 同期失敗の非対称な扱い（P0 #5）** `+3`
  > 前回 -2 とした「1 回の発注で全件照会が 2 回走る」は、`do_submit/2` から同期を削除して `sync_live_fills_before_authorize/2` の 1 箇所に寄せることで解消した。さらに良いのは、発注**後**の同期失敗を別扱いにしたことである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live.ex
  > open_circuit_or_log!(:fill_sync_failed, ...)
  > {:error, :fill_sync_failed, %{order_accepted: true}}
  > ```
  > 「注文は受け付けられたが約定を記帳できていない」を `order_accepted: true` で上位に伝え、サーキットを開ける。これを普通のエラーと混ぜると、上位が再送して二重発注になる。`@definite_rejection_reasons` の allowlist と `submission_unknown` の区別も同じ思想で、「失敗 = 注文が存在しない」と決めつけない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **`LiveFills.Gate` による REST 同期の直列化とレート保護** `+4`
  > 最小間隔 1 秒、単一スロット、`Process.monitor` による保有者死亡時の自動解放、`force` 要求の待機キュー（`:queue`）、そして「失敗しても時計を前進させる」設計。
  >
  > 特に評価すべきは最後の 2 点である。`force` を「割り込んで即実行」ではなく「待って必ず実行」にしたので、halt 後の取消前同期が落とされない。同期が失敗し続けても時計が進むので REST を連打しない。GenServer が時計を所有し、昇格時に `last_ms` を再取得するので、待機中に他者が走った場合も間隔が守られる。この粒度の同時実行制御を自作して、しかも解放漏れ耐性まで入れているのは商用水準である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills/gate.ex`

- **`AuthorizedOrder` ワンショットトークンで Risk → Executor 境界を型で強制** `+4`
  > `OrderExecutor.submit/2` は `%AuthorizedOrder{}` しか受け取らず、トークンは `consume` で 1 回だけ使える。Risk を通らない発注は書こうと思っても書けない。ETS に実体を持ち、偽造トークンを拒否する回帰テストまである。「レビューで気を付ける」ではなく「コンパイル時と実行時の両方で通れない」にしたのが正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **`submission_unknown` を一級の状態として扱い、確定拒否だけを allowlist で分離している** `+4`
  > 発注 REST の失敗を「確定拒否（注文は存在しない）」と「不明（存在するかもしれない）」に分け、不明は `submission_unknown` として永続化し、サーキットを開ける。タイムアウトを楽観的に「失敗」と読んで再送する実装が事故を起こす典型で、そこを最初から分けている。`prep_stop` でも drain し切れなかった in-flight を `submission_unknown` に落として停止するので、プロセス終了経路でも取りこぼさない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **`SubmissionRecovery` の承認付き回収プロトコル** `+4`
  > `mix bitflyer.recover` は (1) 現状を提示して hash を返し、(2) その hash と操作者名を添えて実行する二段構え。曖昧な候補があるときは注文 ID の明示を要求し、取引所側に存在しないことを確認する `--absent` 経路も分ける。回収後も hold は残す（残高予約を勝手に解放しない）。「不明状態を人の承認なしに自動解決しない」という Vision の Least privilege / Idempotent actions をそのまま実装に落としている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`, `apps/bitflyer/lib/mix/tasks/bitflyer.recover.ex`

- **`Paper.FillPricing` の不利化と、認可拘束・約定価格の一致** `+3`
  > paper の擬似約定に slippage / fee を bps で乗せ、成行は LTP に両方、指値交差後は指値に fee のみ（スリッページ無し）という現実に即した分け方をしている。しかも認可時の残高拘束と約定価格が同じ計算を通るので、paper で「認可は通るが約定で残高が足りない」という不整合が起きない。paper を「楽観的なダミー」ではなく「保守的な検証環境」として作っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper/fill_pricing.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **`InFlight` 追跡と `prep_stop` の drain、そして shutdown 予算の数値整合** `+4`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/application.ex
  > # prep_stop: ゲートを閉じる → in-flight を drain → timeout 分は
  > # submission_unknown に落として :submission_unknown サーキットを開ける
  > ```
  > 順序が正しい（先に新規を止め、次に進行中を待ち、最後に残りを安全な状態に確定させる）。さらに `compose.yaml` の `stop_grace_period: 45s` が「1 子 5s × 複数 + Repo」という根拠付きのコメントで書かれており、`@child_shutdown_ms 5_000` / drain 10s と数値が整合している。「graceful shutdown を書いた」ではなく「予算を配分した」水準で、Docker 常駐の OTP アプリとして正しい。テストログの `prep_stop: in-flight drain timed out` から、タイムアウト経路も回帰で踏まれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`, `compose.yaml`

- **発注失敗の種類ごとに残高 hold を「保持する / 解放する」を分けている** `+3`
  > `exchange_halted` / `exchange_error` のような確定失敗は hold を解放し、`submission_unknown` / `persist_failed` は hold を保持する。「注文が存在するかもしれない間は資金を空けない」という保守側の判断で、エラー処理を 1 本の rescue で潰していない。失敗パスの分類が資金勘定に正しく接続されている例である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

### datastore / Ash

- **`BalanceSnapshot.latest_tips/1` の `DISTINCT ON` + 一致インデックス + 絞った rescue（P1 #6）** `+3`
  > 前回 -2（全件読）と -1（生 Ecto + 広い rescue）の 2 件が同時に閉じた。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex
  > distinct: b.currency,
  > order_by: [asc: b.currency, desc: b.captured_at, desc: b.id]
  > ```
  > `ORDER BY` の列順と追加したインデックスの列順が揃っており、`DISTINCT ON` が索引だけで解けるようになっている。rescue を `DBConnection.ConnectionError` / `Postgrex.Error` に限定したうえで、「なぜ Ash ではなく Ecto を直接使うのか」を moduledoc に書いている。前回の指摘に対して現象を直すだけでなく、判断の記録まで残したのは良い応答である。`BalanceCache.load_latest/1` と `Reconcile.read_latest_balances/1` の両方がここへ委譲しており、重複実装も消えた。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

- **`DailyLoss` の世代 + barrier による再集計プロトコル** `+3`
  > `invalidate/2` → DB コミット → `reload(generation:, release_barrier: true)` の 3 段で、「無効化してから再集計する間に古い値で認可が通る」を塞いでいる。世代番号で遅い再集計の結果を破棄でき、barrier 中は fail-closed になる。JST 取引日の切り替え（`@jst_offset_seconds`）を UTC 保存のまま計算する扱いも正しい。実現損益を `Fill.realized_pnl` から再集計するので、ETS が消えても当日実現損は復元される。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **`Order` の validations と 2 本の unique 制約** `+3`
  > 成行 pending には price を持たせない、`filled_size <= size`、といった不変条件を Resource 側で強制し、`internal_order_id` の冪等キーと取引所 id の一意を DB 制約で持つ。「アプリで気を付ける」ではなく「入らない」形にしている。冪等キーを一意制約に載せたうえで、重複挿入を `{:ok, order, :idempotent}` として扱う経路まで用意しているのが実務的である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **Ash を永続状態に限定し、ホットパスは ETS に置く分離** `+2`
  > Order / Fill / Position / BalanceSnapshot / RiskState / BaselineImport のような「消えてはいけないもの」を Ash Resource にし、レート窓・失敗窓・残高キャッシュ・鮮度のような「消えても再構築できるもの」を ETS にする。層の選択基準が一貫しており、フレームワークを使う場所と使わない場所の判断ができている。金額はすべて `Decimal` で、float が混入していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`

- **`Startup.Baseline` の二段階 hash 承認 + advisory lock** `+3`
  > live の初回残高 baseline を、現状提示 → hash 承認 → 取り込み の 2 段にし、操作者名を `BaselineImport` に残し、`pg_advisory_xact_lock` で多重実行を防ぐ。しかも取り込みは Ready を勝手に立てない。「資金の正本を人の承認なしに書き換えない」を守っており、監査行が残る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **paper の残高更新を通貨順の advisory lock で直列化している** `+2`
  > `Balances.apply_fill/2` は `pg_advisory_xact_lock` を通貨コード順に取ってから append する。デッドロックを順序で避ける定石を、個人プロジェクトのシミュレーション経路にまで適用している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`

### 起動・突合・取引所境界

- **起動シーケンスと `Readiness` の fail-closed 状態機械** `+3`
  > `:not_ready` / `:ready` / `{:halted, reason}` の 3 状態で、起動直後は必ず `:not_ready`、halt から Ready へ直接は戻れない。`Reconciler` が boot 突合に成功し、かつ `DailyLoss` と `BalanceCache` の両方が同期済みのときだけ Ready になる。「起動したから発注できる」ではなく「照合できたから発注できる」になっており、Vision の Safety first がそのまま構造になっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **`Startup.Reconcile` の両建て net 正規化と hedged 時の平均単価比較除外** `+3`
  > 取引所側の建玉を net に正規化して比較し、両建てのときは平均単価の比較を外す。bitFlyer FX の建玉表現を実際に理解していないと書けない処理で、「単純比較して誤検知 halt」を避けている。突合の不一致も `kind`（`position_missing_internal` / `balance_mismatch` など）で分類して telemetry に載せる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **`Startup.Resume` が再突合成功のみで解除し、equity では fail-closed になる** `+3`
  > `mix bitflyer.resume` / UI の resume は、その場で突合をやり直して成功したときだけ halt を解く。さらに `Equity.snapshot` が stale / unsynced なら resume を拒否する（テストログの `resume blocked: equity not resumable`）。「止めたものを人の一押しで無条件に戻せる」を作らなかったのが正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/resume.ex`

- **Endpoint と取引監督を兄弟に置き、Discord を発注経路から独立させている** `+2`
  > UI が落ちても取引は続き、取引が止まっても UI は状態を見せられる。通知アダプタも別プロセスで、Webhook が死んでも取引判断には影響しない（通知経路死は別ホストの `/health/ready` で見るという役割分担まで `.env.example` に書かれている）。障害の伝播範囲を意識した監督ツリーである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

- **`Permissions.assert_safe` による API キー権限の起動時検査** `+3`
  > `getpermissions` を見て出金系パスが含まれていたら `unsafe_api_permissions` で halt する。キー発行時の人為ミス（全権限キーを貼ってしまう）を、コードが起動時に拒否する。テストログに `boot reconcile halted: unsafe_api_permissions` が出ており回帰も張られている。Least privilege を運用手順だけでなく実行時検査で担保しているのは珍しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/permissions.ex`

- **`Exchange.Client` behaviour と既定 `Unavailable` の fail-closed** `+3`
  > 取引所クライアントを behaviour で抽象し、live + キーが揃ったときだけ実 REST を注入し、それ以外の既定は「常に失敗する」`Unavailable`。設定ミスで実 API を叩く経路が既定に存在しない。テストでの差し替えも同じ仕組みで済み、抽象化がテストのためだけでなく安全のために働いている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `apps/bitflyer/lib/bitflyer/exchange/unavailable.ex`, `config/runtime.exs`

- **`Decode` の strict 化と `:skip` allowlist の空維持（P0 #3）** `+4`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex L5-8
  > 数値は strict（不正・欠損・NaN/Inf は `:invalid_number`）。
  > 識別子欠落・未知 side / status は snapshot/list 全体失敗
  > `:skip` は明示 allowlist に載った無関係行のみ（現状は空。条件追加時はここに書く）。
  > ```
  > `@allowlisted_skip_order_states MapSet.new([])` を空のまま置き、`@payload_errors` の 6 種を `payload_error?/1` で判定して snapshot 全体を失敗させる。「知らない side が来たら 1 行だけ黙って捨てる」という最も危険な省略を、allowlist を空にすることで構造的に禁止している。`:invalid_number` で 0 に丸めないこと、`exec_date` 欠落だけは許容して不正文字列は拒否するという非対称まで意図を書いている。境界層の設計として理想的である。テストログに `unknown_side ... failing snapshot` / `missing_identifier` / `invalid_number` の 3 経路が出ており、すべて回帰で踏まれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

- **HMAC 署名と秘密のログ非出力** `+2`
  > `Exchange.Auth` が署名を組み立て、署名文字列・API シークレットはログに出さない。`.env.example` にも「値は .env のみ。Git・イメージ・ログに出さない」と書いてある。基本だが、ここを外す実装は多い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/auth.ex`

### observe

- **`Observe.Exposure` を正本にした Status の情報密度（P2 #13）** `+4`
  > 前回 -1 とした「未約定・当日損益・不整合が見えない」が、単に項目を足すのではなく「観測用の正本モジュールを 1 つ作る」形で解けた。建玉（mark / unrealized 付き）、未約定（件数 + 上限 20 件 + 最古の経過時間 + `submission_unknown` の強調）、当日損益（実現 / 含み / equity / ピーク / ドローダウン / 各 headroom）、halt 復帰手順、通貨別残高を一括で返す。
  >
  > 実装上の配慮も揃っている。`Ash.count` と `limit` を併用して全件を BEAM に運ばない、`record_peak: false` で表示がピークを書き換えない、rescue / catch を張って観測の失敗で UI を落とさない。「見えないものは運用できない」に対して、見る側のコストと安全性の両方を詰めている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **`Observe.Contract` + 匿名化 corpus + 禁止パス（P2 #14）** `+3`
  > 前回 -1（契約が手書き fixture のみ）に対し、実ホストから採取して匿名化した corpus を `priv/contract/corpus/` に置き、`Contract.check_corpus/1` をネット不要の検査として `precommit` に組み込んだ。現行 API は人が `mix bitflyer.contract` で叩き、CI は叩かない。
  >
  > 良いのは検査の中身が意味論に踏み込んでいることである（`ask >= bid` の crossed book 検査、正の LTP、ISO 先頭の timestamp、executions の id / side / price / size）。加えて `@forbidden_private_paths` で発注・取消 REST をコードレベルで禁止し、`--write-corpus` は注文 ID を自動で伏せる。「契約テストが誤って実発注する」という最悪の事故を設計で塞いでいる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/contract.ex`, `apps/bitflyer/priv/contract/corpus/`

- **外部監視の手順・探針を用意し、かつ「完了は手順まで」と限界を明記している（P2 #12）** `+3`
  > `bin/watch-ready.sh`（単発 / 常駐 / strikes 付き）、`compose.observe.yaml`（node_exporter）、Windows での windows_exporter 手順、Discord HEARTBEAT の 4 点で「ホストごと死んだら気付く」を組んだ。
  >
  > より評価したいのは、improvement-plan と prod.md が「計画上の完了は手順と探針であり、別ホストの常駐ジョブは live チェックリスト側」と自ら線を引いていることである。監視は「作った」と言いやすい領域で、そこで過大申告していない。
  > 対象ファイル: `bin/watch-ready.sh`, `compose.observe.yaml`, `.workspace/0_doc/architecture/env/prod.md`

- **telemetry メタデータの allowlist と秘密の落とし込み** `+3`
  > イベントごとに出して良いメタデータを allowlist で決め、それ以外は落とす。logger の metadata も `config.exs` で明示列挙されている。ログに API キー・署名・生の注文 ID が混入する経路を、実装規約ではなくコードで塞いでいる。イベント語彙を overview.md に表で持っているので、増やすときに揺れない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `config/config.exs`

- **Discord アダプタの独立性・cooldown・HEARTBEAT** `+3`
  > 通知は Task で投げ、同種通知の cooldown で連投を抑え、起動直後 + 既定 15 分の HEARTBEAT で「通知経路そのものの死」を検知できるようにしている。Webhook 失敗で取引は止まらない。通知系を「あれば便利」ではなく「死活監視の一部」として設計している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **`Health` の 3 プローブ分離と選定理由の記録** `+3`
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/health.ex L5-15
  > - `live_snapshot` / `GET /health/live` — プロセス生存。常に 200。
  >   Compose の restart 判定用。WS 断や stale では落とさない（Feed が再接続する）。
  > - `ready_snapshot` / `GET /health/ready` — 外形 readiness。
  > ```
  > liveness と readiness の役割を混ぜず、「なぜ `/health/live` なのか（LiveView Socket が `/live` を使う）」という実装制約まで書いてある。`classify_ready/4` が `OperationalStatus.market_feed_gate/2` を共有するので、画面と外部監視が同じ判断をする（P1 #9）。公開 JSON に DB エラー詳細を載せない方針も明記されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`

---

## 技術評価層 — apps/ui

- **StatusLive の非同期更新・streams・二重押し防止** `+3`
  > `start_async` で 5 秒ごとに更新し、再入ガードで多重取得を防ぎ、建玉 / 未約定 / 残高は LiveView streams で持つ。kill / resume / reconcile_now の操作は `ops_busy` で二重押しを禁止し、結果ごとにフラッシュを出し分ける。893 行あるが、責務は「取得 → 表示 → 操作結果の提示」に収まっている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **BasicAuth が prod で必須、LiveView 側にも session ガード** `+3`
  > `UI_BASIC_AUTH_USERNAME` / `PASSWORD` が prod で未設定なら起動が失敗する。dev は両方揃ったときだけ有効。`/health*` は認証不要（監視のため）という切り分けも正しい。plug だけでなく LiveView 側でも session を検証しているので、WebSocket 経路での迂回が無い。`PHX_HTTP_IP` の既定が `127.0.0.1` で allowlist 検証付きという公開面の絞り込みも一貫している。
  > 対象ファイル: `apps/ui/lib/ui_web/plugs/basic_auth.ex`, `apps/ui/lib/ui_web/router.ex`, `config/runtime.exs`

- **UI が `Bitflyer.System` の公開 API しか触らず、判断ロジックを持たない** `+3`
  > 画面は `operational_status/0` と `exposure/0` を呼ぶだけで、halt 判定や損益計算を自前でやらない。`halt_step_label/1` のような表示変換に留まる。umbrella の依存方向が `ui → bitflyer` の一方向に保たれており、「画面の都合でドメインに穴を開ける」が起きていない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **Status の i18n（ja / en）** `+1`
  > gettext で日英を持ち、locale 切り替えを用意している。運用画面としては過剰にも見えるが、表示文言をコードから分離したことで halt 理由の語彙が一箇所に集まる副作用がある。
  > 対象ファイル: `apps/ui/priv/gettext/`

---

## 技術評価層 — 実行基盤 / 設定

- **`runtime.exs` の環境別 fail-fast** `+4`
  > TRADE_MODE を stdlib だけで解釈し許可値以外は起動失敗、live はキー必須（`:test` を除く）、prod は `SECRET_KEY_BASE` と BasicAuth 必須、`PHX_HTTP_IP` は allowlist 検証。
  >
  > 最も評価したいのは `:test` の扱いである。テスト環境では取引所クレデンシャルと BasicAuth を**強制的に空・無効にする**。ローカルの `.env` が読まれてテストが実 API を叩く、という事故を構造的に不可能にしている。設定の危険を「書き方で避ける」のではなく「環境ごとに強制する」水準に達している。`config.exs` に `MIX_ENV` を注入しない理由（`preferred_envs` が効かなくなる）まで compose と `.env.example` の両方に書いてある。
  > 対象ファイル: `config/runtime.exs`, `config/config.exs`

- **開発 / 本番 Compose の分離、healthcheck、停止猶予** `+3`
  > 開発は bind mount + `mix phx.server`、本番は `Dockerfile.prod` のリリース + `compose.prod.yaml` + `APP_IMAGE` digest 固定と、目的の違う 2 系統を混ぜていない。db に `pg_isready` healthcheck と `depends_on: service_healthy`、app に `/health/live` の healthcheck、`stop_grace_period: 45s` は根拠コメント付き。`docker compose config --quiet` と本番 config 検証がどちらも通る（今回実行して確認）ので、構成そのものが検証可能になっている。
  > 対象ファイル: `compose.yaml`, `compose.prod.yaml`, `Dockerfile.prod`

- **`Dockerfile.prod` の非 root 化と CI でのビルド検証** `+3`
  > uid/gid 1000 の専用ユーザー、`--chown` 付き COPY、マルチステージでビルド依存を最終イメージに残さない。CI の `docker-prod` ジョブが push なしでビルドだけ回すので、「デプロイ直前に初めてビルドが壊れる」を防いでいる。
  > 対象ファイル: `Dockerfile.prod`, `.github/workflows/ci.yml`

- **`deps-audit` を precommit から分離し、3 値分類をスクリプト化してテストで固定した（P2 #15）** `+4`
  > ```bash
  > # bin/classify-deps-audit.sh
  > # clean / vulnerabilities_found（exit 1）/ audit_tool_or_fetch_failed（exit 0 + ::warning::）
  > ```
  > 「advisory が見つかったときだけ落とす。ツール障害やネットワーク障害では落とさない」という分類を明示した。監査を precommit に入れると外部要因で開発が止まり、結果として監査を外す圧力がかかる。それを避けつつ検出は失わない設計で、判断が運用現実に即している。
  >
  > さらに良いのは、このシェルスクリプトの分類ロジックを **Elixir のユニットテストで固定している**ことである（`test/ci/classify_deps_audit_test.exs`）。CI 補助スクリプトは普通テストされず、静かに壊れて「常に緑」になる。そこに回帰を張ったのは、CI を信頼できる状態に保つという意図の表れである。JSON 解析も `grep` ではなく `elixir -e` で行い、artifact と meta を残す。
  > 対象ファイル: `bin/classify-deps-audit.sh`, `.github/workflows/ci.yml`, `apps/bitflyer/test/ci/classify_deps_audit_test.exs`

- **CI がローカルと同一の `mix precommit` を単一ゲートにし、Actions を SHA ピンしている** `+3`
  > CI 固有の検査列を持たず、`docker compose run --rm app mix precommit` と同等を回す。Postgres サービス + `ash.setup` で DB 依存テストも走る。使用する Actions はすべてコミット SHA 固定で、Dependabot が更新 PR を出す。供給網の可変性を意識した設定である。
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/dependabot.yml`

- **CD が digest 固定・最新 CI success 前提・rollback 単位まで定義されている** `+3`
  > ```
  > # .workspace/0_doc/architecture/ci-cd.md L62-64
  > | CI 前提 | **対象 SHA の最新 `ci.yml` run が workflow 全体 success**…過去の success は見ない（**自動 wait なし**） |
  > | ロールバック単位 | 直前の `APP_IMAGE`（digest）へ戻して `compose up -d` |
  > ```
  > 「過去の success は見ない」「自動 wait はしない」という判断を明示的に選んでいる。タグ trigger + GitHub Environment で人の承認を挟み、本番 PC への自動デプロイはしない（人が pull する）。個人運用のリスク許容度に合った設計で、しかも「保証しないこと」を 6 項目で列挙している。
  > 対象ファイル: `.workspace/0_doc/architecture/ci-cd.md`, `.github/workflows/cd.yml`

- **`.env.example` が値を持たず、運用上の落とし穴を注記している** `+2`
  > 実キーは 1 つも無く、live 専用 env・BasicAuth・出金権限を付けない旨・「MIX_ENV は書かない（`preferred_envs` が効かない）」まで書いてある。設定ファイルがそのまま運用手引きになっている。
  > 対象ファイル: `.env.example`

---

## 横断評価層

### テスト戦略

- **521 テスト / 0 failures を `--warnings-as-errors` で維持している** `+4`
  > 今回の実行で `bitflyer` が 1 doctest + 483 tests、`ui` が 38 tests、いずれも 0 failures。前回の 387 本から 134 本増え、増分の大半が live 約定記帳・equity・halt cancel の周辺である。警告ゼロを CI の落ちる条件にしているので、警告が積もって意味を失う状態にならない。個人プロジェクトでこの規模とこの厳しさを両立しているのは稀である。

- **障害注入と fail-closed の回帰が「安全側に倒れること」を直接検査している** `+4`
  > テストが検査しているのは正常系ではなく拒否の正しさである。実行ログから確認できた経路だけでも、`submission_unknown` の critical、`persist_failed` の critical、boot 突合の halt 5 種（`balance_baseline_missing` / `clock_skew` / `invalid_number` / `unsafe_api_permissions` / `position_missing_internal`）、`daily drawdown exceeded; circuit opened`、`live fill refused` 3 種（`inconsistent filled_notional baseline` / `legacy nil exchange_execution_id baseline` / `terminal filled_size mismatch`）、`prep_stop: in-flight drain timed out`、`order rate warm failed`、`failure rate warm failed`、`HaltCancelGate cancel worker died before finish`。**安全装置が発火することそのものをテストしている**プロジェクトであり、これは「テストを書いた」とは質的に違う。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/order_executor/live_fills_test.exs`, `apps/bitflyer/test/bitflyer/startup/`

### 運用設計

- **`mix` タスクと `Release` rpc の二系統で運用導線が確保されている** `+3`
  > `bitflyer.baseline` / `.recover` / `.resume` / `.halt` / `.contract` を用意し、リリース（mix 不在）でも同等の操作ができるよう `Bitflyer.Release` に対応関数を置いている。「開発では動くが本番リリースでは操作できない」という穴を埋めている。緊急停止が UI にも mix にも rpc にもある冗長性は、24/365 の前提に合っている。
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/`, `apps/bitflyer/lib/bitflyer/release.ex`

- **halt 理由から復帰手順までが機械可読で、画面に出る** `+3`
  > `HaltRecovery` が理由ごとの手順を返し、`Exposure` が `halt_steps` として運び、StatusLive が約 30 種のラベルで人間語にする。「何が起きたか」だけでなく「次に何をするか」が画面に出る。運用文書に書いて終わりにしていない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/halt_recovery.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

### ドキュメント / プロセス

- **文書がコードと一致し、未達の残差を自分から書いている** `+3`
  > overview.md は live spot 限定の帰結（同一キーの手動 FX / CFD 建玉は監視外、spot の内部 Position は突合対象外）を明記し、README も同じことを繰り返している。`OperationalStatus` の moduledoc は P1 #9 の完了条件外の残差（`authorize` が Feed を見ない）を自分で書いている。`FailureRate` は warm が理由を区別しないことを、`Exchange.Rest` は `getexecutions` のページ欠けリスクを書いている。
  >
  > 「できていないことを書く」は評価者が最も検証しにくく、かつ最も裏切られやすい部分である。今回、改善計画が「完了」と宣言した 13 項目をすべてコードで検証したが、明確な過大宣言は無かった。この一致度は文書の信頼性そのものであり、加点に値する。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `README.md`

- **improvement-plan → 1 項目 1 PR → レビューという自己改善サイクルが回っている** `+2`
  > 前回評価から 2 日で P0 5 件 + P1 5 件 + P2 5 件を、それぞれ独立した PR（#72〜#86）として処理している。優先度（P0〜P3）と完了条件を先に書き、1 項目ずつ閉じ、対象ファイルを記録する運用が機能している。指摘を受けて直すだけでなく、直したことを検証可能な形で残している。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`

- **Game Day に実施記録が残っている** `+2`
  > game-day.md は手順表だけでなく、2026-09-12 の Stage 0 実施記録（実施者・モード・公開 contract の結果・次アクション）が記入されている。段階解禁表で Stage 3 以降を「P0 完了後」と明示的に封じており、記録テンプレには「秘密・生の注文 ID は書かない」という注意まである。手順書を書いて満足せず、1 回実際に回してその結果を残したことを評価する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/game-day.md`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| apps/bitflyer — market-data | +8 |
| apps/bitflyer — strategy | +9 |
| apps/bitflyer — risk-manager | +35 |
| apps/bitflyer — order-executor | +40 |
| apps/bitflyer — datastore / Ash | +16 |
| apps/bitflyer — 起動・突合・取引所境界 | +23 |
| apps/bitflyer — observe | +19 |
| apps/ui | +10 |
| 実行基盤 / 設定 | +22 |
| 横断（テスト / 運用 / 文書） | +21 |
| **合計** | **+203** |
