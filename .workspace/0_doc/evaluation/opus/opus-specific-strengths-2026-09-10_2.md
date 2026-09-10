# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-10_2

対象コミット: `2c21cf9`（`Merge pull request #68 from FRICK-ELDY/fix/p3-cleanup-noise`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-10](./archive/2026-09-10/opus-specific-strengths-2026-09-10.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +185 点**

---

## 技術評価層 — apps/bitflyer

### risk-manager

- **日次損失を Fill 正本化し、in-flight 中は「同期済み」にしない世代 + barrier プロトコル** `+5`
  > 前回「設定はあるが常に 0 を見る」と `-4` を付けた箇所が、単に埋まっただけでなく**競合安全まで作り込まれて**戻ってきた。`DailyLoss` は ETS を持つが、そこに入るのは `Fill.realized_pnl` からの再集計結果のみで（daily_loss.ex L380-396）、更新は 3 段のプロトコルになっている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L8-19
  > # 1. `invalidate/2` — `barrier` を増やし synced を外す。世代トークンを返す
  > # 2. DB コミット
  > # 3. `reload(generation:, release_barrier: true)` — 同じ世代でのみ解放・synced 化
  > ```
  >
  > 白眉は `force: true` の扱いである。API 互換のために引数は残しつつ、実装は barrier を無視しない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L299-302
  > defp apply_one(table, mode, day, loss, net, load_gen, true = _force?, release?) do
  >   # force でも in-flight barrier は尊重する（resume 並行 fill の過小評価を防ぐ）
  >   apply_one(table, mode, day, loss, net, load_gen, false, release?)
  > end
  > ```
  >
  > 「約定がコミット途中のときに突合や resume が古いスナップショットで `synced` を立て、損失を過小評価したまま Ready に戻る」という、実際に踏むまで気付きにくい競合を先回りで塞いでいる。世代不一致は `:contended` として自分の barrier だけ返して破棄し（L309-312）、DB 読取失敗時は `mark_unsynced_keep_barrier` で barrier を残す（L263-270）。JST 取引日の切り方も `@jst_offset_seconds` 固定で tzdata 依存を避け、理由をコメントに残している（L31-32）。個人プロジェクトでここまでの一貫性制御を見ることはまずない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **残高キャッシュの hold ライフサイクル（reserve / 比例 consume / filled 整合 / 絶対 put 後の再適用）** `+5`
  > 前回 `-2` だった残高検査が、単なる ETS キャッシュではなく**拘束（hold）会計**として実装されている。`reserve(trade_mode, currency, amount, hold_id:)` が原子的に減額し `{currency, remaining, original}` を記録（balance_cache.ex L326-371）、部分約定は `consume_hold_proportional/5` が `remaining × filled_delta / size_remaining_before` で按分（L396-436）、consume 漏れがあっても `align_hold_to_filled/5` が `original × (size − filled) / size` を上限に切り詰める（L438-483）。
  >
  > 最も評価したいのは、取引所残高の絶対値を書いたあとの扱いである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/balance_cache.ex L581-604
  > # Snapshot / tip の絶対残高の上に、未決済 hold を再度減額する。
  > # 足りなければ fail-closed で unsynced。
  > defp reapply_holds!(table, trade_mode) do
  >   ...
  >              if Decimal.lt?(available, amount) do
  >                {:halt, :unsynced}
  > ```
  >
  > Snapshot から残高を読み直すと未決済注文ぶんの拘束が消える。それを黙って上書きせず hold を再適用し、再適用しきれなければ `unsynced` に倒す。突合成功時だけ `clear_holds: true` で破棄する（reconciler.ex L236-237）という区別も正しい。呼び出し側の `OrderExecutor` も終端時のみ `release_hold`、未終端 cancel 受付では hold を残す（order_executor.ex L375-385）と対応付いており、モジュール間で会計の辻褄が合っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **`AuthorizedOrder` による Risk → Executor 境界の型強制（`:protected` ETS・ワンショット・TTL）** `+4`
  > `OrderExecutor.submit/2` は `%AuthorizedOrder{}` しか受け取らず、raw な command map では呼べない（order_executor.ex L56-78）。トークンは `Risk.authorize/2` 成功時にしか作られず（risk.ex L82-86 の `mint_authorized_order/2` は private）、公開コンストラクタが無い。`consume/2` は `:ets.take/2` でワンショット化し、command と時刻の一致・TTL 超過を検証する（authorized_order.ex L102-126）。
  >
  > ETS を `:protected` にした理由が明示されているのが良い。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/authorized_order.ex L71-74
  > # :protected 必須。:public にすると任意プロセスが :ets.insert でき、
  > # Risk.authorize を通さず有効トークンを偽造できる（P3 #17 の境界破壊）。
  > # consume の GenServer 直列化は意図的。本システムの発注頻度ではボトルネックにならない。
  > ```
  >
  > 「性能のために `:public` にする」という一般的な最適化が、この文脈では境界を壊すことを理解して選択を却下し、そのトレードオフを残している。未消費トークンは 5 秒周期のスイープで掃除し（L138-156）、発注ホットパスで掃除しない設計も筋が良い。型で不変条件を守るという発想自体が、Elixir の動的型付け環境では珍しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **テスト用の値注入を本番設定では無視し、安全側の正本へ強制フォールバックする** `+4`
  > 日次損失と残高はテストのために `opts` で注入できる。しかしその注入は `allow_test_injections: true` のときしか効かない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L544-548
  > else
  >   # 本番経路では注入を無視し ETS 正本を使う（0 注入による迂回を防ぐ）
  >   resolve_daily_loss(Keyword.delete(opts, :daily_loss))
  > end
  > ```
  >
  > `resolve_balances/2` も同型（L577-583）。テスト用の抜け道を作ると、そこが本番の抜け道にもなる——これは実際の取引システムで繰り返し起きている事故で、`daily_loss: 0` を渡せば日次損失サーキットを迂回できてしまう。単に無視するのではなく**キーを削って正本の解決を再帰的にやり直す**ので、フォールバック先も明確である。テスタビリティと安全性が衝突したときに安全を取り、かつテスタビリティを捨てない設計判断として質が高い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **`OrderRate` の DB ウォーム（壁時計 → monotonic 写像・読取成功後のみ置換・失敗は unsynced）** `+3`
  > 前回 `-1` を付けた「再起動で頻度カウンタがゼロに戻る」が解決している。`init/1` で直近 1 分の Order を読み、壁時計の年齢を monotonic に写す（order_rate.ex L200-206）。3 点の細部が良い。(1) DB 読取が成功してから `delete_all_objects` → `insert` する（L163-186 のコメント「DB 成功後にだけ delete → insert」）ので、読取失敗で既存件数を失わない。(2) 起動時の warm 失敗は `synced: false` にして `count/2` を `{:error, :unsynced}` に倒す（L106-114）——件数 0 での素通りを許さない fail-closed。(3) ETS を `:duplicate_bag` にした理由（`:bag` だと同一 ms の複数発注が 1 件に潰れる）をコメントで残している（L208-210）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`

- **`FailureRate` による連続取引所エラーの検知と、`:order_not_found` を除外する判断** `+3`
  > 前回 `-2` の「鍵違いで盲目に rejected を撃ち続ける」が解決した。401/403 は回数不要で即 halt（failure_rate.ex L44）、その他の確定拒否は窓内 N 回で `:consecutive_exchange_errors`（L45-60）。
  >
  > 分類の細かさが良い。`@countable_reasons` に `:order_not_found` を**入れていない**。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk/failure_rate.ex L6-8
  > - `:order_not_found` は取消レース等で起きうるため **連続カウント対象外**（確定拒否のまま、
  >   単発では halt しない）
  > ```
  >
  > 取消と約定が競合すれば `order_not_found` は正常運用でも起きる。それを連続障害として数えると、正常な取消レースがサーキットを開く。同様に timeout 等の提出不明はここで数えず既存の即 halt に任せる（L9）。「何を障害と数えるか」の線引きは経験がないと引けない類のもので、その判断がすべて moduledoc に残っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **時計ずれゲートと `source_timestamp` 欠落の fail-closed** `+3`
  > 前回 `-1` の「clock skew を拒否理由にできない」が解決した。`Normalize` が取引所 `timestamp` を `source_timestamp` として保持し（normalize.ex L11-14, L82-101）、`Risk.check_clock_skew/3` が `max_clock_skew_ms` を超えたら `{:error, :clock_skew, %{skew_ms: ..., max_ms: ...}}` を返す（risk.ex L205-241）。
  >
  > 欠落時の扱いが正しい。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L218-221, L244-247
  > `source_timestamp` 欠落は常に fail-closed（リプレイ耐性）。
  > ...
  > def check_source_timestamp(_value, max_skew_ms, _opts) ... do
  >   {:error, :clock_skew, %{reason: :missing_source_timestamp, max_ms: max_skew_ms}}
  > ```
  >
  > 「時刻が無いから検査できない」を「検査不要」ではなく「拒否」に倒している。同じ関数を live 起動突合からも呼び（reconcile.ex L207-211）、全銘柄の ticker を REST で取って skew を検査する。発注時と起動時の両方に同一ロジックを通す構成も良い。Vision L122 が WSL2 の時刻ずれを名指しでリスクに挙げていることへの正面回答になっている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **`HaltReason` を停止理由の単一正本にし、`String.to_atom/1` を避けた** `+2`
  > 前回 `-1` の「停止理由が再起動をまたぐと `risk_halted` に丸められる」が解決した。`Circuit` と `Reconcile` の双方が `Bitflyer.Risk.HaltReason` に委譲し（reconcile.ex L110, L117 の `defdelegate`）、12 の理由を allowlist で持つ（halt_reason.ex L8-22）。読み戻しは `String.to_existing_atom/1` + `rescue ArgumentError`（L40-50）で、未知の文字列から atom を作らない。「Risk → Startup の依存を避けるため双方がここを正本とする」という依存方向の理由まで moduledoc に書いてある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/halt_reason.ex`

### order-executor

- **エラー種別ごとに「取引所側が資金を拘束している可能性」で hold の解放を分岐する** `+4`
  > `dispatch_releasing/5` の分岐が、単なるエラー処理ではなく資金の所在の推論になっている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor.ex L321-340
  > {:error, :exchange_halted, _} = error -> _ = release_hold(...)   # 未送信
  > {:error, :exchange_error, _} = error  -> _ = release_hold(...)   # 4xx = 未受注
  > {:error, _, _} = error ->
  >   # submission_unknown / persist_failed 等: 取引所側に拘束の可能性 → 予約は残す
  >   error
  > ```
  >
  > 「取引所に注文が存在しないと確定できる理由」を `Live.@definite_rejection_reasons` として明示し（live.ex L7-15）、それ以外は不明として扱う。不明なら hold を残す＝残高を過大評価しない。同じ思想が `maybe_settle_live_hold/1`（L375-385、未終端の cancel 受付では hold を残す）、`settle_cancelled_hold/1`（L389-401、`align_hold_to_filled` してから release）にも貫かれている。「わからないときは自分に不利な側に倒す」が 3 箇所で一貫しているのは偶然ではなく設計である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **paper の不利化価格を、認可時の残高拘束にも同じ式で適用した** `+4`
  > `FillPricing` が成行に slippage + fee、指値には fee のみを掛ける（fill_pricing.ex L27-49）。指値にスリッページを掛けない理由（「指値より悪い約定価格を避ける」L8-9）も正しい。片道 50% 超を設定ミスとして弾く上限もある（`@max_bps 5000`、L17, L136-140）。
  >
  > 特筆すべきは、この不利化が**約定価格だけでなく発注時の残高拘束にも反映されている**ことである。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/risk.ex L466-473
  > # paper 買いの拘束額を不利化後価格に合わせ、reserve < 実効コストを防ぐ
  > defp paper_unit_price(:paper, :buy, :market, unit_price) do
  >   Bitflyer.OrderExecutor.Paper.FillPricing.effective_price(:buy, unit_price)
  > end
  > ```
  >
  > これが無いと、LTP で拘束して LTP×(1+bps) で約定するため、拘束額が実効コストに足りず paper の残高が徐々にマイナス方向へずれる。paper を「本番と同じ経路で検証する場」と位置づける（overview.md L100）以上、価格モデルの整合はこのレベルまで詰める必要があり、実際に詰めてある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper/fill_pricing.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`exchange_order_id` 永続化時の status 揃えで、drain との競合を潰した** `+3`
  > place 成功後に ID を書き込むとき、reload と update の間に `prep_stop` の drain タイムアウトが同じ注文を `submission_unknown` にする窓がある。そこを 2 節の関数で塞いでいる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live.ex L161-170
  > # place 成功で ID を埋めるときは status も pending に揃える。
  > # reload 後〜update 前に drain が unknown 化しても、unknown+ID にならないようにする。
  > defp persist_attrs(%Order{status: status}, exchange_order_id)
  >      when status in [:filled, :partially_filled, :cancelled, :rejected, :expired] do
  >   %{exchange_order_id: exchange_order_id}
  > end
  > ```
  >
  > 終端状態なら ID だけ、それ以外は ID + `pending`。`submission_unknown` から回復したときは warning ログまで出す（L134-148）。テスト出力にも `internal_order_id=drain-race-1 ... live order recovered from submission_unknown after place_order id persist` という該当ケースが出ており、競合そのものを回帰テストで固定している。この粒度の並行性バグを予見して塞いでいるのは、同種プロジェクトの平均を明確に上回る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **`order_not_found` を「消えた」と決めつけず、約定を回収してから終端化する** `+3`
  > `getchildorders` に注文が出てこない状況（未約定取消、照会窓外）で、そのまま `cancelled` にすると約定を取りこぼす。`recover_missing_order/2` は `fetch_executions` で実際の約定量を取り、3 分岐する（live_fills.ex L82-145）。差分があれば建玉に反映してから終端化、既に反映済みなら終端化のみ、約定ゼロなら未約定取消。
  >
  > 照会自体が失敗したときの扱いが正しい。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex L136-144
  > {:error, reason} ->
  >   # 照会不能は fail-closed（黙って open のままにしない）
  >   {:error, :exchange_error,
  >    %{... cause: :order_not_found_recovery_failed}}
  > ```
  >
  > 「注文が見つからない」は取引ボットで最も紛らわしい状態のひとつで、安易に握り潰すと建玉がずれる。3 分岐 + fail-closed の設計は実運用を想定した作りである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

- **`InFlight` による停止時 drain（monitor によるリーク防止・timeout 時 leftovers 返却）** `+3`
  > `track/1` → `try/after` → `untrack/1` の構造で進行中の submit/cancel を数え（order_executor.ex L65-71）、`prep_stop` がゲート閉鎖後に drain する。細部が丁寧である。(1) 追跡プロセスが落ちても `Process.monitor/1` の `DOWN` で自動除去（in_flight.ex L181-190）——`after` が走らないケースでもリークしない。(2) `drain/1` の GenServer call timeout に 5 秒の余裕を持たせる（L77）。(3) timeout 時は leftovers を返し、呼び出し側が `submission_unknown` 化する責務分担（L192-207）。(4) ゲート閉鎖チェックと `track` の間の競合を `{:error, :closed}` で受ける（order_executor.ex L73-76 のコメント「reject_if_order_gate_closed と track の間の競合用」）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`

- **取消の出口を注文自身の `trade_mode` に固定した** `+2`
  > 1 行のガードだが影響が大きい。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor.ex L145-147
  > defp do_cancel(%Order{} = order, opts) do
  >   # opts の :trade_mode は無視。live 注文を dry_run 取消にして取引所に残骸を残さない。
  >   trade_mode = order.trade_mode
  > ```
  >
  > `submit` は `opts` の `:trade_mode` で出口を切り替えられるのに、`cancel` だけは意図的に無視する。設定を切り替えた後の再起動やテスト経路から live 注文を「ローカルだけ cancelled」にしてしまうと、取引所に生きた注文が残ったまま内部から見えなくなる——最悪の状態不整合である。さらに「発注ゲート（halt）中でもエクスポージャ削減のため取消 REST は許可する」（L112-113）という判断もセットで、止めるべきものと止めてはいけないものを区別している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

### market-data

- **サイレントストール watchdog（ref 世代管理で遅延タイマを無害化）** `+3`
  > 前回 `-2` の「つながったまま無言になると永久に何もしない」が解決した。フレーム到着ごとに watchdog を張り直し（feed.ex L132-141）、`stall_timeout_ms`（既定は鮮度窓×3、L395-399）無通信なら `handle_disconnect(state, :stale_watchdog)` で socket を落として既存の再接続に乗せる。
  >
  > タイマ管理が正しい。`make_ref()` で世代を持ち、キャンセル後に遅延到着した旧タイマを捨てる。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/feed.ex L174-177
  > def handle_info({:stall_watchdog, _ref}, state) do
  >   # cancel 後に遅延到着した旧 ref。現行 timer 参照を壊さない
  >   {:noreply, state}
  > end
  > ```
  >
  > さらに「正規化結果に関わらずフレーム到着＝ソケット生存」（L133）として、薄商いや未知フレームで無通信と誤認しない。gap-fill が適用されたときも watchdog を張り直す（L179-187）。`Process.send_after` を使う実装でありがちな二重発火・古い timer の取り違えを、すべて事前に潰してある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **gap-fill を Feed からタスクへ切り離し、開始時刻比較で新しい WS tick を上書きしない** `+3`
  > REST 穴埋めを `Task.Supervisor` に投げて Feed をブロックしない（feed.ex L254-268）。加えて、穴埋め開始時刻を持ち回して適用時に比較する。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/market_data/feed.ex L300-309
  > defp maybe_apply_gap_fill(key, value, product_code, gap_fill_started_at) do
  >   case Cache.get(key) do
  >     {:ok, _current, received_at} when received_at >= gap_fill_started_at ->
  >       :skipped
  > ```
  >
  > 再接続直後は「REST を投げた後に WS の新鮮な tick が届く」順序が普通に起きる。素朴な実装だと古い REST 応答が新しい tick を上書きし、鮮度は満たすのに価格が古いという最悪の状態を作る。「鮮度」と「新しさ」を混同しない実装で、Cache が monotonic 時刻を使っていることとも整合している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **`already_started` / `trap_exit` / mailbox 滞留 `:reconnect` の 3 競合を個別に処理している** `+2`
  > `connect_socket/1` が `{:error, {:already_started, pid}}` を受けたら、その socket は別 Feed PID 向けなので捨てて張り直す（feed.ex L213-217）。`trap_exit` で socket の EXIT を切断として拾う（L44, L147-149）。mailbox に残った `:reconnect` が確立済み接続を落とさないようガードする（L153-161）。GenServer + 外部接続の組み合わせで実際に起きる 3 種類の競合を、それぞれ理由コメント付きで処理している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

### datastore / Ash

- **`Fill` を約定明細の正本にし、建玉更新と同一トランザクション + `FOR UPDATE` で書く** `+4`
  > 前回 `-1` の「約定明細が永続化されない」が解決した。`Positions.apply_fill/2` は既存建玉を `Ash.Query.lock(:for_update)` でロックし（positions.ex L47-51）、建玉の更新／破棄／ドテンと Fill 行の挿入を同じ `with` で束ねる（L77-129）。呼び出し元は `Bitflyer.Repo.transaction` で包む（live_fills.ex L228-241、paper.ex L34-48）。
  >
  > `realized_pnl` の切り分けが正しい。建増しは 0、部分決済は決済分のみ、ドテンは既存建玉の全量分のみ（L95-128）。ロールバックの経路も `{:error, code, meta}` を `Bitflyer.Repo.rollback({code, meta})` で通し、コミット後に `Ash.Notifier.notify/1` する（live_fills.ex L242-243）——トランザクション内で通知を飛ばさないという Ash の正しい使い方である。Lost Update を `FOR UPDATE` で潰し、それを moduledoc に明記している（L12）点も含めて、永続化層の作りとしては商用水準に近い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **paper 残高の append-only 更新を `pg_advisory_xact_lock` で直列化し、通貨昇順でデッドロックを避けた** `+4`
  > `Balances.apply_fill/2` は「最新行を読んでデルタを足した新しい行を create する」append-only 方式で、その競合対策が明快に書かれている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/balances.ex L14-22
  > `(trade_mode, currency)` ごとに `pg_advisory_xact_lock` で直列化し、
  > 同時約定による Lost Update を防ぐ（先端行の `FOR UPDATE` だけでは
  > 新 tip 挿入後も古い額から append され得る／初回行なし時も競合する）。
  > 複数通貨は currency 昇順でロックし、buy/sell 同時でもデッドロックしない。
  > ```
  >
  > 「なぜ `FOR UPDATE` では足りないか」（append-only では既存行のロックが新規挿入を防がない、そもそも初回は行が無い）まで説明したうえで advisory lock を選び、buy が `{JPY, BTC}`、sell が `{BTC, JPY}` の順にロックを取るとデッドロックすることに気付いて `Enum.sort_by` で順序を固定している（L40）。`@balance_lock_namespace 1` と `Baseline` の `2`（baseline.ex L16）で名前空間を分けている点も含め、DB の並行制御を正しく理解している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`

- **戦略パラメータ履歴を Resource 化し、注文から由来を辿れるようにした** `+3`
  > 前回 `-1` の「適用履歴 Resource が無い」が解決した。`StrategyParameterRevision` を `(trade_mode, params_hash)` で一意にし、`Revision.ensure_current/1` が同値なら再利用・無ければ create、一意制約競合時は勝ち行を読み直す（revision.ex L43-73）。`Runner` は `handle_continue` で revision を確定してから tick を受け付け（runner.ex L110-137）、各 command に `strategy_parameter_revision_id` / `strategy_module` / `command_hash` を載せる（L391-397）。
  >
  > ハッシュの安定性に気を配っている。`Jason.OrderedObject` でキー順を固定し（L173-182）、Decimal は `to_string(:normal)`、atom は文字列化して正規化する（L130-134）。「true/false/nil は atom なので is_atom より先に判定する」（L129）という細部まで正しい。「どの設定がこの注文を生んだか」が DB から辿れるようになり、overview.md L114-120 が挙げる永続化 6 項目が揃った。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`

- **Decimal 徹底と `Bitflyer.Repo` の閉じ込め** `+2`
  > 価格・数量・損益はすべて `:decimal` 属性で、float は Decode の入口で `Decimal.from_float/1` に変換して以降は Decimal のまま扱う。Ash Domain は `Bitflyer.Trading` 1 つに整理され（config.exs L6）、`ash_domains` から `Bitflyer.System` が外れている。`ui` から `Bitflyer.Repo` を参照する箇所は無く、UI は `Bitflyer.System` ファサード経由でのみ触る。overview.md L80-84 のアプリ境界がコードで守られている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/*.ex`, `config/config.exs`

### startup / 復帰

- **両建て建玉の net 正規化と、hedged 時に平均単価比較を落とす判断** `+4`
  > 前回の改善計画 P0 #3 が、素朴な net 化を超えた形で実装されている。取引所の `{product_code, side}` 複数行を buy−sell で net し（reconcile.ex L317-377）、内部のネット 1 行と比較する。
  >
  > 判断が細かい。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconcile.ex L420-430
  > defp netted_position(product_code, side, size, average_price, hedged?) do
  >   %{...
  >     # 両建て net 後の勝ちサイド全量 VWAP は、内部の部分決済据え置き／ドテン fill 単価とズレうる。
  >     # エクスポージャ（side+size）は必ず突合し、平均は単一路線のみ厳密比較する。
  >     compare_average_price?: not hedged?
  >   }
  > ```
  >
  > 両建てを net した平均単価は内部の計算過程と一致しないので、そこを厳密比較すると誤 halt になる。かといって全部を緩めると意味が無いので、**エクスポージャ（side + size）は必ず比較し、平均は単一路線のときだけ厳密比較**という線を引いた。さらに不正な side や非 Decimal の平均は黙って捨てず `position_invalid_exchange` で mismatch にする（L390-408）——「読めなかった行を無視する」が最も危険な選択であることを理解している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **Ready 化の条件に「リスクキャッシュが同期済みであること」を含めた** `+4`
  > 突合が成功しても、それだけでは Ready にしない。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/reconciler.ex L150-154
  > :not_ready ->
  >   # paper/live は DailyLoss + BalanceCache が synced のときだけ Ready
  >   # （Ready と発注可否のずれを防ぐ。dry_run は残高検査なし）
  >   if risk_caches_synced?(trade_mode, daily_loss_result, balance_result) do
  > ```
  >
  > これが無いと「Ready なのに発注しようとすると全部 `:unsynced` で拒否される」状態が生まれる。外形上は正常、実際は 1 件も発注できない——監視から見て最も紛らわしい。`Readiness` の意味を「突合が通った」ではなく「実際に発注できる」に揃えたのは、状態機械の設計として質が高い。モードごとに条件を変え（dry_run は残高不要）、`{:ok, :deferred}` は Ready にしない（`daily_loss_synced?/1` は `:ok` のみ true、L224-225）のも一貫している。halted 中は自動で Ready に戻さず手動 `clear_halt` を待つ（L131-133）点も正しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **baseline import の承認プロトコル（dry-run hash → confirm → 再検査 → それでも Ready にしない）** `+4`
  > 前回 `-2` 相当だった「空 DB から live を始められない」が、単なる import コマンドではなく承認手続きとして実装された。(1) dry-run と confirm は排他（baseline.ex L101-103）。(2) confirm には dry-run で表示した `snapshot_hash` の一致が必須（L124-135）——人が見た内容と書き込む内容が同じことを保証する。(3) `pg_advisory_xact_lock` を取った**あとで**必須通貨がまだ欠けているか再検査し、ずれていれば `:baseline_race`（L338-362）。(4) 操作者は必須（L109-120）で `BaselineImport` に記録。
  >
  > 最も重要なのは最後の一点である。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/startup/baseline.ex L7-9
  > dry-run / confirm とも Ready にはしない。
  > Ready は通常の起動・定期突合（または `resume`）成功時のみ。
  > ```
  >
  > 復旧コマンドが Ready を立てられると、それが安全装置の迂回路になる。baseline / recover / halt のすべてで「Ready にはしない」を貫いているのは、運用ツールが安全機構を壊さないための正しい原則である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **`submission_unknown` 回収の承認プロトコルと、切り捨て検知の fail-closed** `+4`
  > 前回 `-2` の「halt から抜ける道が無い」が解決した。`SubmissionRecovery` は `list_child_orders` を時刻窓 + side + size（limit は price）で照合し、候補 1 件なら hash 承認で ID 埋込、複数なら `--exchange-order-id` 明示が必須、0 件は `--absent` 承認で cancelled 化する（submission_recovery.ex L50-108）。
  >
  > 2 つの細部が良い。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex L13-18
  > - 候補 0: `--absent` で cancelled 化。**hold は解放しない**（誤 absent で残高過大評価しない）
  >
  > `child_order_date` 欠落・不正や一覧が要求件数を超えて返る場合（内部で count+1 を要求）は
  > fail-closed（誤って `match=none` にしない）
  > ```
  >
  > 「一覧が切り捨てられたのか、本当に無いのか」を区別するために `count+1` 件を要求するという発想は、ページング API を扱った経験がないと出てこない。切り捨てを `match: :none` と誤認すれば、実在する注文を `--absent` で消してしまう。誤 `--absent` の後でも ID 未埋込なら再 recover で紐付け可能（L18）という回復可能性まで設計されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`

- **`prep_stop` の停止シーケンス（ゲート閉鎖 → drain → timeout 時は不明扱いで halt）** `+4`
  > OTP の `prep_stop/1` を使って、子の shutdown が始まる前に発注を止める（application.ex L51-104）。順序は Discord telemetry 解除 → `mark_not_ready_safe`（halted は維持）→ `InFlight.drain`。
  >
  > timeout 時の処理が徹底している。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/application.ex L106-121
  > defp finalize_drain_timeout(leftovers) when is_list(leftovers) do
  >   ...
  >   # submit mark が無く cancel のみでも、途中打ち切りは不明扱いしてゲートを閉じる
  >   if marked? or leftovers != [] do
  >     _ = Bitflyer.Risk.open_circuit(:submission_unknown)
  >   end
  > ```
  >
  > 進行中だった submit を `submission_unknown` にマークし（L123-142、`pending` かつ ID 未埋込のものだけ）、cancel しか残っていなくてもサーキットを開く。つまり**中断された停止からは絶対に自動で発注再開しない**。時間予算も config.exs L61-63 で「drain ≤10s + 子 5×5s ≪ stop_grace_period 45s」と明示され、compose.yaml L29-30 と対応が取れている。Vision の Recoverable / Idempotent をシャットダウン側から支える実装として完成度が高い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `config/config.exs`, `compose.yaml`

### exchange 連携

- **Decode の strict 化（0 に丸めず `:invalid_number`、識別子欠落は `:skip`）** `+4`
  > 前回の改善計画 P0 #5 が完遂されている。`to_decimal/1` は NaN・Inf・空文字・不正文字列・非数値をすべて `:error` にし（decode.ex L17-73）、float は `float_to_binary` した文字列に `inf` / `nan` が含まれないかまで見る（L31-45）。`require_decimal/1` で `{:error, :invalid_number}` に写し（L279-284）、`Reconcile.fetch_live_snapshot/1` が `:invalid_exchange_payload` として通信障害と区別して halt する（reconcile.ex L261-263）。
  >
  > 「何を許容し何を拒否するか」の線が引けている。`average_price` は未約定で 0 / 欠落がありうるので `nil` を許すが不正値は拒否（L287-300）、識別子（currency / side / product_code）欠落の行は `:skip`、数値の不正は `:error`。日時の扱いも「bitFlyer Private API はオフセット無しの JST 壁時計が契約」という API 固有の罠をコメントで固定し（L319-322）、オフセット付きが来たら誤って −9h しない。テスト出力にも `exchange decode rejected invalid number; failing snapshot` が現れており、経路が実際に効いている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

- **live 起動時の API キー権限検査（出金・送付権限があれば halt）** `+3`
  > `Reconcile.reconcile_mode/4` の live 経路は、突合の**前に**権限と時計を検査する（reconcile.ex L149-158）。`Permissions.assert_safe/1` が `/v1/me/withdraw` / `/v1/me/sendcoin` の有無を見て `:unsafe_api_permissions` で halt する。Vision の Least privilege を「運用ルール」ではなく「起動時に機械が検査する条件」に変換しており、キー発行を間違えた状態で本番が動き出すことがない。テストにも `trade_mode=live reason=unsafe_api_permissions [warning] boot reconcile halted` の回帰がある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/permissions.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **エラー分類を HTTP status 優先に組み替えた** `+2`
  > 前回 `-1` の「本文の部分一致に依存」が改善した。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex L257-263
  > cond do
  >   status in [401, 403] -> :auth_failed
  >   status == 429 -> :rate_limited
  >   String.contains?(lowered, "insufficient") -> :insufficient_funds
  > ```
  >
  > 401/403 が `:auth_failed` として独立したことで `FailureRate` の即 halt に繋がり、429 が `:rate_limited` になったことでレート制限と一般拒否が区別できるようになった。メッセージ一致はフォールバックに降格している。bitFlyer の数値エラーコード（`status` フィールド）を第一キーにするところまでは行っていないが、実害のある部分は塞がった。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`

### observe

- **telemetry 語彙の正本化と metadata allowlist** `+3`
  > `Bitflyer.Telemetry` が 9 イベントとメタデータ allowlist（21 キー）を一元管理し、`execute/3` と `log/3` の両方が同じ `sanitize_metadata/1` を通る（telemetry.ex L96-141）。文字列キーは `String.to_existing_atom/1` + `rescue` で処理し（L145-149）、未知キーは黙って落とす。「秘密キーを allowlist に入れないこと」という運用ルールも moduledoc に書いてある（L8）。`config/config.exs` の Logger metadata（L126-151）と `UiWeb.Telemetry.metrics/0` の宣言がこの語彙と対応しており、3 箇所が同じ語彙を共有している。「改名すると過去ログと LiveDashboard が繋がらなくなるため、追加はあってもリネームは避ける」（L5-6）という運用上の約束まで明文化されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

- **Discord アダプタの独立性と安全策（静的 attach・cast・cooldown・URL 非出力・二重投稿回避）** `+3`
  > 発注経路から完全に切り離されている。Application 起動時に静的 ID で 1 回だけ attach し、GenServer 再起動のたびに attach/detach しない（application.ex L42-43、discord.ex L70-79）。イベントは `cast` なので送信の遅延が telemetry 発行元をブロックしない。送信失敗時も cooldown を刻んで「失敗で連打」を防ぐ（L139-143）。Webhook URL はログにもメッセージにも出さない（L140 のコメント）。2000 字上限で truncate（L196-203）。`readiness.changed` と `reconcile.mismatch` の二重投稿を回避する分岐（L269-271）もある。formatting 中の例外・exit まで `rescue` / `catch` している（L145-162）ので、通知が原因で取引が止まることはない。overview.md L94 の「Bot / 第3アプリは作らない」という方針にも忠実である。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

### OTP / Application

- **起動順序と子ごとの shutdown 予算が、停止時間の設計と整合している** `+3`
  > 子の順序が依存関係どおりである（application.ex L16-34）。Repo → Readiness → Cache → リスク系 ETS（OrderRate / FailureRate / AuthorizedOrder / CircuitSync）→ InFlight → DailyLoss / BalanceCache → TaskSupervisor → Reconciler → Discord → Feed → Runner。突合より前にキャッシュ群が上がり、Feed と Runner は `MarketData.enabled?` / `Strategy.enabled?` で条件付き起動する（L146-164）。
  >
  > shutdown 予算に理由がある。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/application.ex L8-11
  > # Supervisor は子を直列停止する。1 子あたりの上限を短くし、
  > # Compose stop_grace_period（45s）内に Repo 等の後続クリーンアップ余地を残す。
  > # 発注停止と in-flight drain は prep_stop で行う（子 shutdown より前）。
  > @child_shutdown_ms 5_000
  > ```
  >
  > 「子は直列停止する」という OTP の性質から逆算して 1 子あたりの上限を決め、Compose 側の `stop_grace_period: 45s` と突き合わせている。停止時間の予算を実際に計算している OTP アプリは多くない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **Discord と Feed を発注監督木の兄弟に置いた** `+2`
  > `Bitflyer.Observe.Discord` に「発注経路の兄弟。通知失敗・クラッシュで取引木を巻き込まない」というコメントを付けて `:one_for_one` の子に並べている（application.ex L32-33）。同様に UI の `Endpoint` は `Ui.Application` 側で別に起動する。overview.md L83「同じ BEAM でも Endpoint と取引監督は兄弟にし、UI の例外で発注側を再起動しない」が構造で守られている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

---

## 技術評価層 — apps/ui

- **StatusLive の運用操作（kill / resume / reconcile）を `start_async` + 排他で実装した** `+3`
  > 前回の改善計画 P3 #18 が実装されている。3 つの操作はすべて `start_async` でバックグラウンド化し（status_live.ex L32-71）、`ops_busy` で二重押下を弾く。`{:exit, reason}` も `handle_async` で受けてフラッシュに出す（L78-96）。結果ごとにメッセージを出し分け、特に `{:ok, :persist_failed}` を「メモリ上は halt したが RiskState 永続化に失敗。再起動で消えるかもしれない」と正直に伝える（L421-427）のが良い。resume には `data-confirm` を付ける（L202）。操作者は BasicAuth の username を使う（`ops_operator`）ので、誰が止めたかがログに残る。「UI から即 halt・再突合・復帰できる」という運用要件を、LiveView の非同期プリミティブを正しく使って満たしている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **判定ロジックを `OperationalStatus` に集約し、UI を描画専用に保った** `+3`
  > 「今トレードしてよいか」の判定は `OperationalStatus.classify/4` が持つ（operational_status.ex L151-171）。readiness / live 確認 / 市場データ鮮度の合成がここ 1 箇所にあり、`orders_gate/4` として `TradeMode` からも同じ関数が使われる。`StatusLive.assign_status/1` はスナップショットを assign に写すだけで（status_live.ex L372-398）、条件分岐はクラス名の選択（`trade_mode_card_class/1` 等）に限られている。
  >
  > `Feed.status()` の呼び出しを `try/catch :exit` で包む（operational_status.ex L176-182）ため、Feed が落ちていても画面が落ちない。UI は「稼働状況の閲覧に責務が限られているか」という評価観点に対して、境界が明確に引かれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **LiveDashboard を BasicAuth 配下で本番常設し、危険な面を明示的に落とした** `+3`
  > 前回 `-2` の「本番に metrics の集計先が無い」への回答の一つ。`/ops/dashboard` を dev 限定ではなく本番でも有効にし、`on_mount: [{UiWeb.Hooks.BasicAuth, :default}]`、`ecto_repos: []`、`request_logger: false`、`allow_destructive_actions: false` を明示している（router.ex L44-57）。除外できないページ（Processes / ETS / Applications）が残ることまでコメントに書いてある（L42）。「本番でダッシュボードを出す」判断とそのリスク低減策がセットで、しかも文書（overview.md L157）と一致している。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`

- **`ConsoleReporter` を prod 既定にしつつ、高頻度イベントを除外した** `+2`
  > metrics 消費者不在の穴を、まず「ログに数値が出る」段階で埋めた。`@console_metric_prefixes` で 8 イベントに絞り、`market_data.tick` / Phoenix / VM は除外する（ui/telemetry.ex L22-31）。tick を含めると stdout が実質使えなくなるので、この取捨選択は正しい。`UI_METRICS_CONSOLE` で明示 on/off でき、未設定時は prod のみ有効（runtime.exs L248-257）。Prometheus は後続と割り切ったうえで、いまできる観測を確保している。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`, `config/runtime.exs`

- **Phoenix 生成テンプレの残骸を除去した** `+1`
  > 前回 `-1` を付けた `Layouts.app/1` のマーケティングリンク 3 本と Phoenix バージョン表示が消え、アプリ名とテーマ切替だけになった（layouts.ex L36-58）。`PageController` / `page_html` / `Ui.Mailer` / `:swoosh` / `/dev/mailbox` も削除されている。運用画面として文脈の合わない要素が無くなった。
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **live 起動時の安全既定（Strategy 無効・FixedOnce 禁止・Risk 上限の環境変数必須と形式検証）** `+5`
  > `Bitflyer.Config.LiveSafety` は、この評価で最も評価したい設計判断のひとつである。`TRADE_MODE=live` のとき（`:test` を除く）3 つを強制する。(1) Strategy は `BITFLYER_STRATEGY_ENABLED=true` 以外では無効（live_safety.ex L42-47）。(2) 有効化しようとしても開発用 `FixedOnce` なら `ArgumentError` で**起動を止める**（L52-60）。(3) Risk の 5 上限は環境変数必須で、欠落・空・不正形式は起動停止（L72-123）。
  >
  > エラーメッセージが運用者に向けて書かれている。
  >
  > ```elixir
  > # apps/bitflyer/lib/bitflyer/config/live_safety.ex L126-131
  > raise ArgumentError, """
  > #{env_key} is required when TRADE_MODE=live.
  >
  > Development Risk defaults (e.g. 1 BTC order / 5 BTC position / 100000 JPY daily loss)
  > must not be used for live. Set live-specific limits explicitly.
  > """
  > ```
  >
  > 「`TRADE_MODE=live` にしたら開発用の 1 BTC 上限と自動成行戦略がそのまま本番に載る」というのは、この種のシステムで最も現実的な事故シナリオである。それを設定の注意書きではなく**起動不能**で防いでいる。しかも `runtime.exs` から呼ぶために Application 起動前でも使えるモジュールとして切り出し（L8-9）、`getenv` を関数で受けてテスト可能にし（live_safety_test.exs 93 行）、`:test` 環境では適用しない（runtime.exs L157）ことで `.env` の live 設定がテストを壊さない。Vision の「live へ切り替える操作は設定上で目立たせ、キーも混ぜない」に対する回答として、これ以上の実装は思いつかない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

- **`runtime.exs` が test 環境の秘密情報・DB・認証を明示的に切り離している** `+3`
  > `runtime.exs` は `test.exs` の**後**に走るため、`.env` の値がテストに漏れる。それを 3 箇所で個別に潰している。(1) API キーは `:test` で空に固定（L136-144、コメント「`.env` のキーがテストに漏れないよう空にする」）。(2) DB は `TEST_DATABASE_URL` 優先、未設定なら `_dev` → `_test` に寄せ、`MIX_TEST_PARTITION` にも対応（L18-43）。(3) BasicAuth は `:test` で固定オフ（L232-234、「`.env` の資格情報で StatusLive 等が 401 にならないよう」）。
  >
  > 「開発キーと本番キーを混ぜない」（Vision）を超えて「開発キーとテストを混ぜない」まで踏み込んでいる。`config_env()` の評価順序という Elixir 固有の落とし穴を理解し、それぞれの箇所に理由コメントを残しているのが良い。
  > 対象ファイル: `config/runtime.exs`

- **本番 HTTP bind の既定を loopback にし、許可値を allowlist で検証する** `+3`
  > ```elixir
  > # config/runtime.exs L307-333
  > # 公開面の最小化: 既定は loopback。VLAN 等へ意図的に出すときだけ PHX_HTTP_IP を変える。
  > # 許可値: 127.0.0.1（既定）/ 0.0.0.0 / ::1 / ::
  > ```
  >
  > 未設定なら `{127,0,0,1}`、許可値以外は起動時 `raise`。Phoenix の既定は `0.0.0.0` なので、これは意図的な引き締めである。Vision の VLAN1 本番PC 運用（作業用 VLAN3 から必要最小ポートのみ許可）と直接対応しており、ネットワーク設計と設定が繋がっている。BasicAuth も prod で未設定なら起動停止（L226-230）で、公開面の最小化が二重に効く。
  > 対象ファイル: `config/runtime.exs`

- **本番イメージが multi-stage・非 root・tini・digest 固定で作られている** `+3`
  > `Dockerfile.prod` は builder / runner の 2 段で、runner は `debian:bookworm-slim` に release のみを置く（Dockerfile.prod L43-66）。`groupadd --gid 1000` / `useradd --uid 1000 --shell /usr/sbin/nologin` で非 root 化し、`COPY --chown=app:app` で所有者を揃える。`tini` を PID 1 にしてゾンビ回収とシグナル転送を担保する（L78）——SIGTERM を release に正しく届けることは `prep_stop` の drain が働く前提なので、ここが繋がっている。deps 層を先に COPY してキャッシュを効かせ（L26-32）、Elixir / OTP バージョンを開発用と CI に揃える旨をコメントで明示（L2）。`.dockerignore` で `.env` / `_build` / `deps` / `.git` を除外している。
  > 対象ファイル: `Dockerfile.prod`, `.dockerignore`

- **CI が `Dockerfile.prod` のビルドを検証する（push なし）** `+3`
  > 前回 `-1` の「タグを打つまで本番ビルドが壊れていても分からない」が解決した。ci.yml に `docker-prod` ジョブが追加され、`push: false` / `cache-from: type=gha` でビルドだけ検証する。PR でも走らせる判断とそのトレードオフがコメントに書かれている（「PR でも実行＝時間・Actions 分が増える意図的なトレードオフ」）。`assets.deploy`（tailwind / esbuild）や `mix release`、`mix deps.get --only prod` の環境差が、リリース当日ではなく PR の時点で表面化する。
  > 対象ファイル: `.github/workflows/ci.yml`

- **CD が「対象 SHA の最新 CI が workflow 全体で success」を必須にしている** `+4`
  > 前回の改善計画 P2 #14 が、想定より厳密に実装されている。`gh run list --workflow=ci.yml --commit=$sha --limit=1` で**最新 1 件だけ**を見る。
  >
  > ```yaml
  > # .github/workflows/cd.yml
  > # 同一 SHA の「最新」ci.yml のみ見る（過去 success + 最新 failure を通さない）
  > # 自動 wait はしない。未完了・失敗なら CD を落とす。
  > ```
  >
  > 「過去に一度成功していれば通る」という抜け道を明示的に塞いでいる。未完了なら待たずに落として再実行を促す（曖昧な待ちを作らない）。run が 1 件も無い場合も専用のエラーメッセージで落とす。checks API ではなく workflow 全体の conclusion を見るので、`docker-prod` ジョブの失敗も配布を止める。`environment: production` による承認、digest 出力による Compose 固定まで含めて、CD ゲートとして商用水準である。
  > 対象ファイル: `.github/workflows/cd.yml`

- **`deps.audit` を「ゲート外の可視化」として意識的に設計した** `+3`
  > CI では `continue-on-error: true` で実行し、json / stderr / meta を artifact に残す。脆弱性検出とツール失敗を `pass:true` / `pass:false` / それ以外で 3 分類し（ci.yml の `outcome=` 分岐）、advisory 取得を 1 回に限定するという配慮まである。README L116 に「**CI 緑 ≠ 依存に既知脆弱性なし。**」、`heroicons` / `daisyui` の GitHub タグ依存はスキャン対象外と明記している。「何を保証し、何を保証しないか」を書ける成熟度は、セキュリティツールを入れただけのプロジェクトとは明確に違う。今回の実行結果は `No vulnerabilities found.`。
  > 対象ファイル: `.github/workflows/ci.yml`, `README.md`

---

## 横断評価層

### テスト戦略

- **`capital_preservation_test.exs` による資金保全の縦貫通回帰（968 行）** `+4`
  > 単体テストの寄せ集めではなく、「資金保全」という関心で 1 ファイルにまとめた回帰群がある。テスト実行ログから確認できるシナリオは、Fill → DailyLoss → halt、pending + 別 fill、部分約定 cancel、market 取消の LTP 差分、両建て net の順序反転、drain 競合（`drain-race-1`）、cancel 競合（`cancel-race-1`）、連続拒否 3 回（`live-consec-1..3`）、`auth_failed` 即 halt、persist 失敗後の halt、baseline 欠落、clock skew、権限違反、不正数値。
  >
  > 評価観点が求める「発注経路・冪等性・モード分岐の回帰」「突合・サーキット・鮮度ゲートの再現可能なテスト」を、まさにこのファイルが担っている。テストを機能単位ではなく**守りたい性質**の単位で組んでいるのは、テスト戦略として意図的な設計である。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

- **時間・並行性に依存するテストを決定的に書いている（387 テスト 0 failures、約 3 秒）** `+3`
  > `Process.sleep` に頼らず、`:now` / `:now_dt` / `:now_ms` の注入、`loader` 差し替え（order_rate.ex L167）、`Socket.Local` によるフレーム注入、`ExchangeClientStubs` で決定性を確保している。ヘルパも用途別に 8 本（`BalanceCacheHelper` / `DailyLossHelper` / `InFlightHelper` / `OrderRateHelper` / `FailureRateHelper` / `ReadinessHelper` / `MarketDataCacheHelper` / 戦略スタブ 2 本）用意され、ETS プロセスの状態リセットが統一されている。`max_cases: 64` の並行実行で bitflyer 352 + ui 35 テストが 2.5 + 0.3 秒。時刻・タイマ・GenServer 状態が絡むコードでこの決定性は容易ではない。
  > 対象ファイル: `apps/bitflyer/test/support/*.ex`, `apps/bitflyer/test/bitflyer/**`

- **新規セーフティ機構ごとに境界テストが付いている** `+2`
  > `authorized_order_test.exs`（173 行、偽造・再利用・TTL 超過）、`fill_pricing_test.exs`（60 行、不正 bps・上限超過の fail-closed）、`in_flight_test.exs`（67 行）、`submission_recovery_test.exs`（459 行）、`baseline_test.exs`（243 行）、`reconcile_test.exs`（659 行）。機能を足すたびにその境界条件のテストを足す習慣が守られている。テスト実行ログに `invalid paper slippage_bps="nope"; refusing fill pricing` / `paper fee_bps=10000 exceeds max 5000; refusing` が出ており、異常系が実際に踏まれている。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/**`

### エラーハンドリング・安全側フォールバック

- **「わからない」を表す語彙を揃え、すべて安全側に倒している** `+4`
  > このコードベースには「不明」の表現が 4 種類あり、それぞれ意味が違う。`{:error, :unsynced}`（正本が読めない → 発注拒否）、`{:ok, :deferred}`（in-flight 中なので同期済みにしない → Ready にしない）、`{:ok, :skip}`（そのモードには概念が無い → 検査不要）、`submission_unknown`（取引所側の状態が不明 → halt して再送しない）。
  >
  > 混同していないことが重要である。`DailyLoss.reload/1` の `{:ok, :deferred}` は `Reconciler.daily_loss_synced?/1` で false になり Ready を止める（reconciler.ex L224-225）。`Risk.balance_hold/2` の `{:ok, :skip}` は dry_run にだけ返り、`release_hold(_trade_mode, :skip)` が no-op になる（order_executor.ex L369）。`BalanceCache` はプロセス再起動時に全モード unsynced（balance_cache.ex L15）、crash で barrier が残れば過大評価しない（L14）。「不明を 0 で埋めない」「不明を正常と見なさない」が全モジュールで守られており、`Bitflyer.Risk` の moduledoc 冒頭に「fail-closed」と書いてある宣言がコード全体で裏付けられている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/**`

### 可観測性・デバッグ容易性

- **停止・拒否の理由が発生源から画面・通知・DB まで同じ語彙で伝わる** `+3`
  > `Risk.rejection_code`（risk.ex L23-29）→ `Telemetry.execute(:risk_rejected, ...)`（L686-701）→ Logger metadata（config.exs L126-151）→ `HaltReason` で RiskState 文字列化 → 再起動時に atom へ復元 → `OperationalStatus.halt_reason/1` → StatusLive 表示 / Discord 通知、という 1 本の線が通っている。前回は再起動をまたぐと理由が `risk_halted` に潰れていたが、`HaltReason` の 12 理由 allowlist でそこも繋がった。テスト出力の各行（`trade_mode=live reason=clock_skew product_code=FX_BTC_JPY [warning] boot reconcile halted`）を見れば、構造化ログだけで状況が読めることが分かる。Vision の Observable「約定、拒否、切断、再起動の理由を残す」が実際に満たされている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/lib/bitflyer/risk/halt_reason.ex`, `config/config.exs`

### 変更容易性・保守性

- **差し替え点が behaviour で明示され、テストと本番が同じ経路を通る** `+3`
  > `Bitflyer.Exchange.Client`（REST 全体）、`MarketData.Socket.Client`（WS）、`MarketData.Rest.Client`、`Exchange.Rest.HTTP`（`:http_client`）、`Observe.Discord.HTTP` の 5 つが behaviour で切られている。既定は `Bitflyer.Exchange.Unavailable` で（config.exs L7）、live かつキーがあるときだけ `Exchange.Rest` を刺す（runtime.exs L150-153）。fail-closed が設定の既定値として表現されている。テストは `Socket.Local` / `Rest.Stub` / `ExchangeClientStubs` で差し替えるだけで、Feed や Executor の実装コードはテスト専用分岐を持たない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`

- **第3アプリを増やさない方針が守られている** `+2`
  > `apps/` は `bitflyer` と `ui` の 2 つのみ。paper は `OrderExecutor.Paper`、Discord は `Observe.Discord` としてアダプタに留まっている（overview.md L62 の方針どおり）。論理コンポーネント（market-data / strategy / risk / executor / persist）は `lib/bitflyer/` 直下のディレクトリ境界で表現され、依存方向は Strategy → System → Risk → Executor の一方向。`ui` → `bitflyer` も `Bitflyer.System` ファサード経由に統一されている。方針を文書に書くだけでなく 3 サイクル維持しているのは評価に値する。
  > 対象ファイル: `apps/`, `.workspace/0_doc/architecture/overview.md`

### 開発者体験（DX）

- **単一ゲート `mix precommit` がローカル・CI・コンテナで同一** `+3`
  > `mix.exs` の `precommit` エイリアス 1 本がローカルと GitHub Actions の両方で使われる。`preferred_envs: [precommit: :test]`（mix.exs L26-29）で環境を固定し、README L96 と compose.yaml L41-42 の両方に「`MIX_ENV` を Compose / `.env` に書かない（`preferred_envs` が効かなくなる）」という注意が書いてある——実際に踏む落とし穴を予防している。今回 `docker compose run --rm -e MIX_ENV=test app mix precommit` を実行して約 8 秒・bitflyer 1 doctest + 352 tests / ui 35 tests・0 failures で通った。「ホストに Elixir 不要」（README L50）が実際に成立している。
  > 対象ファイル: `mix.exs`, `README.md`, `compose.yaml`

- **README が現状を過不足なく説明し、コンポーネント表に `partial` を導入した** `+2`
  > 前回 `-1` を付けた「risk-manager の過大申告」が直っている。
  >
  > ```
  > README.md L28
  > | risk-manager（limits / circuit / 鮮度） | partial | ... 含み損は未計上 |
  > ```
  >
  > 単に `partial` にするだけでなく、何が実効で何が未実装か（「含み損は未計上」）まで書いた。他の行も実装と照合して正確で、`lightning_board_*` / `lightning_executions_*` を「—」とする API 表（L182-188）も正直である。`.env.example` は追跡し `.env` は除外、環境変数表（L122-136）も現行の runtime.exs と一致している。ドキュメントが実装より新しくも古くもない状態を維持できている。
  > 対象ファイル: `README.md`

### 取引完成度

- **起動 → 突合 → Ready → 発注 → 約定 → 停止 → 復帰の全経路が実装され、モード差は出口だけ** `+4`
  > overview.md L122-130 の起動シーケンス 6 段がすべてコード上に存在する。設定読込（runtime.exs）→ 復元（`Reconcile.restore/1`）→ 突合（`compare_with_exchange/3`）→ 不整合なら halt（`Reconciler.apply_result/2`）→ 購読（`Feed`）→ Ready（`Readiness.mark_ready/0`、ただしキャッシュ同期条件付き）。停止側も `prep_stop` → drain → 不明時 halt。復帰側は `resume` / `reconcile_now` / `baseline` / `recover` の 4 経路があり、いずれも Ready を直接立てない。
  >
  > モード分岐は出口だけである。`OrderExecutor.dispatch/4`（order_executor.ex L318-320）の 3 行が唯一の分岐点で、`Strategy` も `Risk` も `Position` / `Fill` の書き込みもモードを問わず同じコードを通る。overview.md L100「同じ経路を通さないペーパーは、本番で初めて壊れる」が構造として守られている。「人が張り付かなくても資金を守れるか」に対しては、halt に倒れる経路が網羅されている一方で halt からの自動復帰は限定的（意図的な設計）という状態で、Vision の優先順位と合っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/**`

### セキュリティ・秘密情報・権限

- **秘密情報が 5 段階で分離されている** `+4`
  > (1) **注入**: `BITFLYER_API_KEY` / `_SECRET` は環境変数のみ、live 以外は空、live で欠落なら起動停止（runtime.exs L128-134）。(2) **イメージ**: `.dockerignore` で `.env` / `.git` を除外、`Dockerfile.prod` は release だけをコピー。(3) **ログ**: `Telemetry` の allowlist にキー系が 1 つも無く、Discord は URL を出さない（discord.ex L140）。(4) **権限**: live 起動時に `getpermissions` で出金・送付権限を検査して halt。(5) **公開面**: prod は BasicAuth 必須 + `PHX_HTTP_IP` 既定 loopback、`/health*` のみ無認証、LiveView は session `:ui_basic_ok` も要求（router.ex L36-38 の `on_mount`）。
  >
  > Vision の Least privilege / Environment split が、注入・保管・出力・権限・露出のすべての段で実装されている。「API キーを環境変数にした」で止まらず、漏洩経路を列挙して 1 つずつ塞いだ形跡がある。
  > 対象ファイル: `config/runtime.exs`, `.dockerignore`, `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/router.ex`

### プロジェクト全体設計

- **Vision / Architecture と実装の一致度が高く、文書が実装に追随している** `+3`
  > overview.md は「Ready 状態の正本は `Bitflyer.Readiness`」（L132）、health 3 系統の 200 条件（L136-140）、`source_timestamp` 欠落も発注拒否（L167）、`stall_timeout_ms`、`getpermissions` 検査、`/ops/dashboard` の設定内容まで書いており、すべてコードと一致することを確認した。文書が抽象的な設計図ではなく**実装の仕様書**として機能している。取引モード表（L104-108）も `dry_run` は擬似約定もしない・`paper` の突合は内部正・`dry_run` は突合で建玉を書き換えない、という実装（reconcile.ex L140-146）と対応している。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/vision.md`

- **二者独立評価 + improvement-plan による自己改善サイクルが実際に回っている** `+3`
  > 前回の改善計画に挙げた P0 5 件 / P1 5 件 / P2 5 件 / P3 4 件のうち、コード再読で解決を確認できたのが 15 件、部分解決 1 件。git log を見ると 1 項目 1 PR（`fix: P3 #17 AuthorizedOrder で Risk→Executor 境界を強制する` 等）で、レビュー反映コミットも入っている。計画表の「完了の見方」列が検証可能な条件で書かれているため、こちらも同じ基準で照合できた。
  >
  > 評価ルール自体も改善されている（第1/第2評価者が相手の当日文書を読まない、過去文書だけで判断しないという明文化）。単発の「レビューしてもらう」ではなく、評価→計画→実装→再評価のループが 3 サイクル回り、そのたびに減点が -37 → -33 → -21 と下がっている。個人プロジェクトでこの規律を維持しているのは稀である。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.cursor/rules/evaluation.mdc`

---

## 小計

| 大分類 | 小分類 | 加点 |
|:---|:---|---:|
| 技術評価層 — apps/bitflyer | risk-manager | +29 |
| | order-executor | +19 |
| | market-data | +8 |
| | datastore / Ash | +13 |
| | startup / 復帰 | +20 |
| | exchange 連携 | +9 |
| | observe | +6 |
| | OTP / Application | +5 |
| 技術評価層 — apps/ui | | +12 |
| 技術評価層 — 実行基盤 / 設定 | | +24 |
| 横断評価層 | テスト戦略 | +9 |
| | エラーハンドリング | +4 |
| | 可観測性 | +3 |
| | 変更容易性・保守性 | +5 |
| | 開発者体験（DX） | +5 |
| | 取引完成度 | +4 |
| | セキュリティ | +4 |
| | プロジェクト全体設計 | +6 |
| **合計** | | **+185** |
