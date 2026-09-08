# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-09

対象コミット: `e029bd6`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)
前回（自系統）: [opus/archive/2026-09-08](./archive/2026-09-08/opus-specific-strengths-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +124 点**

---

## 技術評価層 — apps/bitflyer

### 取引モードと発注ゲート

- **`live` の三重ゲート（モード + 当日 UTC 確認 + Ready）を型と関数で表現している** `+5`
  > `Bitflyer.TradeMode.exchange_order_gate/0`（trade_mode.ex L119-137）は `live?` → `live_confirmed?` → `Readiness.gate()` の順に `cond` で降り、いずれかが欠ければ `{:halted, reason}` を返す。`live_confirmed` は `config/runtime.exs` L100-108 で `BITFLYER_LIVE_CONFIRM` が **UTC 当日の `YYYY-MM-DD` と一致するときだけ** true になる。つまり `.env` に `TRADE_MODE=live` を書き残しても、翌日には確認日付が古くなって発注経路が自動的に閉じる。「解禁は明示的な人間の操作であり、かつ時限式である」という性質をコードで担保している実装は、この規模の個人プロジェクトではまず見ない。`OrderExecutor.Live.execute/3`（live.ex L10-19）がこのゲートを唯一の入口にしており、迂回路が無い点も良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trade_mode.ex`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **不正な `TRADE_MODE` を Application 起動前に落とす** `+3`
  > `config/runtime.exs` L75-98 は許可値以外を `raise ArgumentError` で止める。さらに「ここは stdlib のみでパースする（Application 未起動のため自アプリモジュールに依存しない）」とコメントで理由を残し、`Bitflyer.TradeMode`（同じ許可値の正本）と二重管理になっていることを明記している。前回指摘した「未知の文字列が素通りする」は、`parse/1` / `parse!/1` / `current/0` の三点セット（trade_mode.ex L20-64）で完全に解消された。`current/0` が atom も文字列も受けて正規化する設計のため、テストからの `Application.put_env` 差し替えとも噛み合っている。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/trade_mode.ex`

### Ready 状態とサーキット

- **Readiness が「単一書き込み・多読・fail-closed」の状態機械になっている** `+4`
  > `Bitflyer.Readiness` は書き込みを GenServer に集約し、読み取りは `:ets.lookup_element/3`（readiness.ex L215-219）で直読する。ETS テーブルが消えていれば `rescue ArgumentError -> :not_ready` で **安全側に倒れる**。状態遷移も `:halted` から `mark_ready` を拒否し（L141-143）、`clear_halt` は `:not_ready` にしか戻さない（L173-183）ため、「halted から一足飛びに Ready」が構造的に起きない。発注ホットパスのゲート判定がプロセス間通信に依存しないという設計意図が moduledoc に書かれており、実装と一致している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`

- **サーキットの開閉順序が「安全側が先」で統一されている** `+4`
  > `Risk.Circuit.open/2`（circuit.ex L34-63）は **先に `readiness.halt(reason)` でメモリ上の発注経路を閉じ、その後 RiskState を永続化する**。永続化に失敗しても発注は止まったままになる。逆に `close/1`（L69-88）は **RiskState の解除を先に確定させてから** `clear_halt` する。DB 解除に失敗したまま Ready に戻る経路が存在しない。さらに `persisted_halted?/0`（L91-99）は `{:error, _} -> true`、つまり RiskState を読めないときも「開いている」と判断する。3 箇所すべてで「迷ったら止める」に倒しており、順序の理由まで moduledoc に書かれている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

### 発注の冪等性

- **内部注文 ID の冪等性を DB 一意制約と競合時フォールバックの二段で担保している** `+4`
  > `OrderExecutor.submit/2` は `idempotent_lookup/1`（order_executor.ex L98-106）で既存行を先に引き、無ければ `create_pending/2` を実行する。ここで重要なのは L127-132 で、`Ash.create` が失敗した場合に **もう一度 `fetch_order/1` を引いて既存行があれば `{:idempotent, order}` を返す**点。並行した 2 本の submit が同時に「無い」と判断しても、ユニーク制約（`Order` の `identity :unique_internal_order_id`）で片方が落ち、落ちた側は REST を叩かずに既存注文を返す。`with` の else 節（L45-46）が `{:ok, order, :idempotent}` に畳んでいるため、呼び出し側から見て「二重送信は起こらない」が型で読める。Vision の Idempotent actions がコードで説明できる状態にある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **`paper` の擬似約定と建玉反映を単一トランザクション + 行ロックで守っている** `+4`
  > `OrderExecutor.Paper.execute/3`（paper.ex L14-51）は `Bitflyer.Repo.transaction/1` の内側で「注文を filled にする」「建玉に反映する」を実行し、どちらかが失敗すれば `Repo.rollback` する。加えて Ash の通知を `return_notifications?: true` で受け取り、**コミット後にまとめて `Ash.Notifier.notify/1` する**（L29）。トランザクション内で通知を飛ばしてロールバック済みの事実を外へ漏らす、という典型的な事故を避けている。`Positions.apply_fill/2` 側も `Ash.Query.lock(:for_update)`（positions.ex L38）で既存建玉をロックし、同時 create の unique 衝突時はロック付きで読み直してマージする（L56-62）。Lost Update を意識した実装で、この粒度まで書けている個人プロジェクトは少ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

### risk-manager

- **`authorize/2` が全経路で fail-closed になっている** `+3`
  > `Bitflyer.Risk.authorize/2`（risk.ex L36-58）は `with` で「コマンド検証 → 同期状態 → 鮮度 → 注文サイズ → 想定建玉」を直列に通し、どこかで落ちれば `emit_rejected/3` を経て `{:error, code, meta}` を返す。特筆すべきは `check_position_size/3` の L178-181 で、**建玉の読み取りに失敗したときに「建玉なし」とみなさず `:unsynced` で拒否する**点。DB 障害時に上限チェックが素通りする、という最も危険な失敗モードを潰している。`check_sync/1`（L108-127）も `:not_ready` を `:unsynced`、`{:halted, reason}` を `:circuit_open` に写像しており、拒否理由が呼び出し側で区別できる。ホットパスで RiskState の DB 往復を避ける判断（既定 `check_persisted_circuit: false`）と、その理由のコメントも妥当。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **上限値の正規化が Decimal に閉じている** `+3`
  > `Risk.Limits.normalize/1`（limits.ex L28-45）は文字列・整数・浮動小数をすべて `Decimal` に寄せ、部分指定のマップでも欠けたキーを既定値で埋める。`config/config.exs` L26-29 の上限も文字列（`"1"` / `"5"`）で書かれており、設定ファイルから float が混入する経路が無い。金額・数量に float を使わないという Architecture の要求（overview.md L96）が、設定層まで一貫している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/limits.ex`, `config/config.exs`

### 起動シーケンスと突合

- **突合の「正本」をモードごとに切り替えている** `+3`
  > `Startup.Reconcile.reconcile_mode/2`（reconcile.ex L116-134）は `dry_run` / `paper` では取引所と突合せず内部状態を正とし、`live` でだけ `exchange.fetch_reconcile_snapshot/0` を叩く。Architecture の取引モード表（overview.md L102-108）の「`paper` の起動突合は取引所の建玉ではなく、内部の仮想状態を正とする」がそのまま関数節になっている。文書の一文が実装の分岐と 1 対 1 で対応している例で、後から読む人が仕様と実装を照合しやすい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **`exchange_order_id` を持たない未確定注文を無条件に mismatch として halt する** `+3`
  > `compare_open_orders/2`（reconcile.ex L238-241）は、内部の未約定注文に取引所 ID が付いていないものが 1 件でもあれば、突合ループに入る前に `:reconcile_mismatch` を返す。これは「REST 送信中に BEAM が落ちた」ケースを確実に捕まえる設計で、再起動後に「取引所には出ているかもしれないが内部に ID が無い」注文を抱えたまま Ready にすることを防ぐ。`Bitflyer.Regression.CapitalPreservationTest` の `boot reconcile halt` 群（capital_preservation_test.exs L199-248）で、halted 後に `submit` が `{:error, :circuit_open, _}` になり REST 呼び出し回数が 0 のままであることまで固定されている。prod.md L36-38 の「差分があれば Ready にせず発注を禁止したまま」が実際に動く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

- **突合失敗時に「メモリを先に止め、その後に永続化」を守っている** `+2`
  > `Startup.Reconciler.apply_result/2` の失敗側（reconciler.ex L144-178）は、telemetry と警告ログを出したうえで `readiness.halt(reason)` を先に呼び、その後 `persist_risk_halt/1` する。コメント（L162）に「persist 失敗でも発注は閉じる」と意図が書かれている。成功側（L103-142）も、既に halted なら **自動では Ready に戻さない**（L105-108）。「自動復帰させない」判断を明示的に残している点が良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

### 取引所アダプタ

- **既定の取引所クライアントが常に失敗する実装になっている** `+3`
  > `config/config.exs` L7 が `exchange_client: Bitflyer.Exchange.Unavailable` を既定にし、`Unavailable` は `fetch_reconcile_snapshot/0` / `place_order/1` の双方で `{:error, :exchange_unavailable}` を返す（unavailable.ex L8-16）。結果として、実クライアントを差し込まない限り `live` は突合段階で必ず halt し、発注は物理的に不可能になる。「未実装だから危険」ではなく「未実装は安全側」に倒す既定値の置き方は、取引システムの初期段階として正しい。`Bitflyer.Exchange.Client` が Decimal 前提の型仕様つき behaviour（client.ex L11-51）として先に定義されている点も、実装差し替えの契約として機能している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/unavailable.ex`, `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `config/config.exs`

### market-data

- **REST 穴埋めが WebSocket の新しいデータを踏み潰さない** `+4`
  > `Feed.do_gap_fill/1`（feed.ex L212-226）は REST 取得を `Task.Supervisor` に逃がして Feed をブロックせず、**穴埋め開始時刻 `gap_fill_started_at` をタスクに持たせる**。結果を適用する `maybe_apply_gap_fill/4`（L258-266）は、キャッシュ内の `received_at` が穴埋め開始時刻以降なら書き込みをスキップする。つまり「REST 応答が返ってくる間に WS の新しい tick が届いた」場合に、古い REST 値で上書きしない。切断復帰まわりで最も踏みやすい競合を、時刻比較 1 本で潰している。この手当てを最初から入れているのは経験のある設計判断。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **socket プロセスのライフサイクル管理が丁寧** `+3`
  > Feed は `trap_exit` を立て（feed.ex L41）、socket の EXIT を切断として扱い（L126-128）、再接続前に必ず旧 socket を `Process.exit(pid, :shutdown)` で片付ける（L185-188）。`{:error, {:already_started, pid}}` を受けたときは「既存 socket は別 Feed PID 向けのままなので捨てて張り直す」（L171-176）と、原因まで含めて処理している。さらに `handle_info(:reconnect, ...)`（L132-141）はメールボックスに残った再接続要求が確立済み接続を落とさないようガードしている。再接続まわりの典型的なバグが一通り潰されている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **鮮度判定に monotonic 時刻を使っている** `+3`
  > `MarketData.Cache` はエントリを `{value, received_at}` として持ち、`received_at` は `System.monotonic_time(:millisecond)`（cache.ex L125-126）。NTP 補正やサマータイムで壁時計が飛んでも鮮度判定が壊れない。`fresh?/3` は miss・期限切れ・テーブル消失をすべて false に畳み（L59-69, L162-169）、純関数の `entry_fresh?/3` を切り出してテストと risk から再利用できるようにしている。ホットパスは ETS 直読で GenServer を経由しない。単一ノード前提で Redis を持ち込まないという Architecture の方針（overview.md L92）とも整合している。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

### 可観測性

- **telemetry 語彙を 1 モジュールに集約し、メタデータを allowlist で濾している** `+3`
  > `Bitflyer.Telemetry` はイベントキー → イベント名のマップ（telemetry.ex L24-34）を正本とし、`metric_names/0`（L69-75）で LiveDashboard 側の名前まで導出できる。`sanitize_metadata/1`（L113-131）は allowlist 外のキーを落とし、文字列キーは `String.to_existing_atom/1` を `rescue` 付きで扱う（L136-140）。ユーザ入力由来の atom 生成を避けつつ、`api_key` / `api_secret` のような秘密らしきキーが Logger や telemetry に載らないことを `telemetry_test.exs` L44-70 が固定している。「秘密を出さない」を規約ではなくコードで強制している点が良い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/bitflyer/test/bitflyer/telemetry_test.exs`

- **`live` で「取引所は受注済みなのに ID を保存できない」を critical として区別している** `+2`
  > `OrderExecutor.Live.place/1`（live.ex L36-59）は `place_order` 成功後の `Ash.update` 失敗を `:critical` レベルでログし、内部注文 ID と取引所注文 ID の両方をメタデータに載せる。これは「取引所に注文が存在するのに内部から追跡できない」という、資金保全上もっとも危険な状態である。同じ `{:error, ...}` でも重大度が違うことを、実装者が理解して書き分けている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

### 永続状態

- **価格・数量が Decimal で、Resource 側に制約と検証が入っている** `+3`
  > `Order` は `size` に `greater_than: 0`、`filled_size` に `min: 0` と `compare(:filled_size, less_than_or_equal_to: :size)`（order.ex L91-121）、`order_type: :limit` のときの `price` 必須と `market` かつ `pending` のときの `price` 不在を検証する。`RiskState` は `halted: true` のとき `reason` / `halted_at` を必須、false のとき不在にする（risk_state.ex L56-61）ため、「停止中なのに理由が無い」行が作れない。`BalanceSnapshot` も `available <= amount` を検証する。不変条件をアプリ層の if ではなく Resource 定義に置いており、どの経路から書いても守られる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

- **建玉を「銘柄 × 取引モード」で一意にし、モード間の汚染を防いでいる** `+3`
  > `Position` の `identity :unique_product_code_and_trade_mode`（position.ex L64-66）と、それを支えるマイグレーション `20260908104842_alter_positions_unique_product_code_and_trade_mode.exs` により、`paper` と `live` の建玉が同じ行を奪い合わない。`Risk.load_positions/2`（risk.ex L191-197）も現モードのみを読む。`CapitalPreservationTest` の `trade_mode isolation`（capital_preservation_test.exs L125-197）が「paper の約定が live 建玉を動かさない」「live 建玉が paper のリスク判定に混ざらない」を両方向から固定しており、設計とテストが噛み合っている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/position.ex`, `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

### OTP / Application

- **起動ツリーが Architecture の起動シーケンスとほぼ 1 対 1 で読める** `+2`
  > `Bitflyer.Application.start/2`（application.ex L10-22）の子は `Repo` → `Readiness`（`:not_ready` で開始）→ `Cache` → `Task.Supervisor` → `Reconciler` → 条件付き `Feed` の順で、overview.md L122-129 の 6 ステップと対応が付く。Feed は `MarketData.enabled?/0` で切れる（L25-30）ため、テスト環境（config/test.exs L36-40）で実ネット接続を持たない構成にできる。`ui` と `bitflyer` が別 OTP アプリのため、Endpoint の例外が取引監督ツリーを巻き込まないという要件（overview.md L83）も構造上満たされている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `config/test.exs`

---

## 技術評価層 — apps/ui

### 運用エンドポイント

- **`/health` を api パイプラインに分離し、DB エラー本文を公開 JSON から除外している** `+3`
  > `router.ex` L18-23 は `/health` を `:api`（セッション・CSRF なし）に置き、監視と Compose healthcheck の共通入口にしている。`Bitflyer.Health.to_json_map/1`（health.ex L68-77）は `db_error` を意図的に含めず、詳細はサーバログ本文にだけ出す（health_controller.ex L24-32）。ヘルスエンドポイントから接続文字列やホスト名が漏れる、という地味だが実在する漏洩経路を塞いでいる。`config/prod.exs` L13-20 の `force_ssl` 除外パスも `/health` に揃っており、3 箇所（ルータ / prod 設定 / compose healthcheck）で同じパスを指している。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`

- **健全性の分類が「DB 断と halted は 503、起動中の not_ready は 200」と明文化されている** `+2`
  > `Health.classify/2`（health.ex L79-90）は 4 状態（`:ready` / `:not_ready` / `:halted` / `:unavailable`）に畳み、`healthy?/1` で HTTP コードに写像する。起動途中の `:not_ready` を 200 にする理由（Ready 化は boot reconcile の責務）が moduledoc に書かれており、`start_period: 60s` の healthcheck 設定（compose.yaml L56）と整合する。`health_controller_test.exs` L18-50 が 3 状態すべてを固定し、`db_error` がレスポンスに含まれないこともアサートしている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/test/ui_web/controllers/health_controller_test.exs`

### 依存方向と可視化

- **UI が `bitflyer` のファサード経由でしか触らず、取引所 API を直接叩かない** `+3`
  > `StatusLive.assign_status/1`（status_live.ex L109-125）と `HealthController.show/2` はいずれも `Bitflyer.System` / `Bitflyer.Health` / `Bitflyer.Readiness` だけを呼ぶ。`apps/ui` 側に bitFlyer への HTTP 呼び出しは 1 件も無く、`Bitflyer.System`（system.ex L36-107）が `health/1` / `readiness/0` / `exchange_order_gate/0` / `authorize_order/2` / `submit_order/2` を並べた公開境界として機能している。Architecture の「`ui` は `bitflyer` に依存し、公開インターフェース経由でのみデータに触る」（overview.md L81-82）が守られている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **Ready 状態と halt 理由を画面に出し、テストで固定している** `+2`
  > 前回「稼働状況が 3 点しか出ない」と指摘した箇所に readiness カードが追加され、`Bitflyer.Readiness.format/1` により `halted:reconcile_mismatch` の形で停止理由まで表示される（status_live.ex L78-82）。`status_live_test.exs` L46-51 が `Readiness.halt(:reconcile_mismatch)` 後に該当文字列が出ることを DOM ID 指定でアサートしている。「画面に出る」ではなく「停止理由が出る」ところまでテストで固定している点を評価する。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/test/ui_web/live/status_live_test.exs`

- **LiveDashboard に取引ドメインのカウンタを載せ、タグ値を正規化している** `+2`
  > `UiWeb.Telemetry.metrics/0` L55-71 は `Bitflyer.Telemetry` の 9 イベントすべてに対応するカウンタを定義し、`readiness.changed` と `health.unhealthy` にはタグを付けている。`bitflyer_tag_values/1`（L80-88）が nil・atom・binary・その他を文字列に畳むため、`Telemetry.Metrics` 側でタグ値の型ゆれによる例外が起きない。運用デバッグ手段が「ログを grep する」だけで終わっていない。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`

- **i18n と DOM ID の整備** `+1`
  > 画面文言が `gettext` 経由で en / ja 両方用意され（`priv/gettext/`）、`#status-page` / `#trade-mode` / `#readiness` / `#db-status-label` など主要要素に ID が振られている。テストが生 HTML ではなく `has_element?/3` で書けているのはこの整備の結果。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/priv/gettext/`

---

## 技術評価層 — 実行基盤 / 設定

### 品質ゲート

- **ルート `mix precommit` が副作用ゼロで、テストまで warnings-as-errors** `+3`
  > `mix.exs` L30-43 の alias は `deps.unlock --check-unused` → `format --check-formatted` → `compile --warnings-as-errors` → `test --warnings-as-errors` の順。前回指摘した「`format` がファイルを書き換えるだけでゲートにならない」「順序が compile 先行」「`apps/ui` にしか alias が無く bitflyer を素通りする」の 3 点がすべて解消されている。`test --warnings-as-errors` まで付けているのは、`test/` が `compile` の対象外であることを理解したうえでの手当てで、コメント（L39）にもその理由が書かれている。`def cli` の `preferred_envs`（L15-19）もルートに移った。
  > 対象ファイル: `mix.exs`

- **Compose が `MIX_ENV` を注入せず、その理由をファイルに残している** `+3`
  > `compose.yaml` L39-40 に「MIX_ENV は注入しない。未設定時は Mix 既定の dev。固定すると preferred_envs（例: mix precommit → test）が効かなくなる」と明記されている。同じ注意が `.env.example` L18 と README L54 にも書かれており、3 箇所で同じ落とし穴を塞いでいる。実測でも `docker compose run --rm app mix precommit`（`MIX_ENV` 明示なし）が exit 0 で 96 テスト緑になり、前回「文書どおりのコマンドが失敗する」という状態は解消された。
  > 対象ファイル: `compose.yaml`, `.env.example`, `README.md`

- **healthcheck が `/health`（DB + readiness）を見る** `+3`
  > `compose.yaml` L51-56 は `curl -fsS http://127.0.0.1:4000/health` を叩く。前回は `/`（StatusLive）を叩いていたため DB 断でも healthy だったが、現在は `Health.classify/2` が `:unavailable` を返して 503 になる。Architecture の「プロセス生存だけでなくデータ鮮度と取引所との同期を見据える」（overview.md L144）に向けた土台が揃った。
  > 対象ファイル: `compose.yaml`

### CI

- **CI が「ローカルと同じ 1 コマンド」を、シークレットなしで回している** `+3`
  > `.github/workflows/ci.yml` は `postgres:16-alpine` サービスを立て、`mix ash.setup --domains ...` の後に `mix precommit` を呼ぶだけ（L65-69）。`TRADE_MODE: dry_run` を env に固定し（L38）、bitFlyer / Discord の秘密は一切置いていない。`erlef/setup-beam` で Elixir 1.18.3 / OTP 27 をピンし、開発用 `Dockerfile`（elixir:1.18.3-otp-27-slim）と揃えている。ci-cd.md が「CI が保証すること / しないこと」を表で切り分けており、文書とワークフローが一致している。
  > 対象ファイル: `.github/workflows/ci.yml`, `.workspace/0_doc/architecture/ci-cd.md`

- **テスト DB の分離を「命名規約 + 環境変数上書き」の二段で解いている** `+3`
  > `config/runtime.exs` L17-47 は `TEST_DATABASE_URL` を最優先し、未設定なら `DATABASE_URL` の DB 名を `_dev` → `_test` に置換（無サフィックスなら `_test` 付与）し、さらに `MIX_TEST_PARTITION` を末尾に連結する。CI 側は `TEST_DATABASE_URL` を明示（ci.yml L37）し、ローカルは規約に任せる。前回「`MIX_ENV=test` が開発 DB を触る」と指摘した設計欠陥が、どちらの環境でも成り立つ形で解消された。並列パーティションまで見ているのは先回りが利いている。
  > 対象ファイル: `config/runtime.exs`, `.github/workflows/ci.yml`

### コンテナと秘密情報

- **`.dockerignore` が秘密・ビルド成果物・作業文書を除外している** `+3`
  > `.env` / `.env.*` / `*.pem` / `*.key` / `secrets/` / `credentials.json` に加え、`_build` / `deps` / `.git` / `.workspace` / `.cursor` まで除外している。ファイル先頭に「本番 Dockerfile の COPY 混入防止のため先に置く」と目的が書かれており、まだ書いていない `Dockerfile.prod` に対する予防として置かれたことが分かる。事故の順序（先に防具、後で刃物）を理解している。
  > 対象ファイル: `.dockerignore`

- **entrypoint が常駐起動のときだけ DB 待ちと `ash.setup` を行う** `+3`
  > `bin/docker-entrypoint.sh` L34-40 は `$1 = mix` かつ `$2 = phx.server` のときだけ `run_setup` を呼ぶ。`docker compose run --rm app mix precommit` のような単発コマンドで開発 DB のマイグレーションが走らない。`wait_for_db`（L13-26）は 60 秒のリトライ上限を持ち、失敗時は非ゼロで抜ける。Umbrella ルートに `:app` が無いため `--domains` を明示する必要がある、という制約もコメントで残っている。
  > 対象ファイル: `bin/docker-entrypoint.sh`

- **開発 Compose がホスト公開を localhost に絞っている** `+3`
  > `db` は `127.0.0.1:5432`、`app` は `127.0.0.1:4000` にバインドする（compose.yaml L5-6, L23-24）。`restart: unless-stopped` と `depends_on: db: condition: service_healthy` も設定済みで、dev.md の「ホストへは localhost のみ公開」（L19-20）と一致する。開発環境で LAN に晒さない既定は、VLAN3 の作業用 PC を前提とする本プロジェクトでは実質的な安全装置になる。
  > 対象ファイル: `compose.yaml`

- **`force_ssl` の除外パスがヘルスチェックと一致している** `+1`
  > `config/prod.exs` L13-20 で `/health` を HSTS リダイレクトから除外している。本番でヘルスチェックが 301 を受けて失敗する、という定番の踏み外しを事前に避けている。
  > 対象ファイル: `config/prod.exs`

---

## 横断評価層

### テスト戦略

- **「資金保全の横断回帰」を独立したテストとして立て、REST 呼び出し回数まで検証している** `+5`
  > `Bitflyer.Regression.CapitalPreservationTest`（340 行）は、部品テストとは別に「重複 intent / trade_mode 分離 / boot reconcile halt / risk 拒否」の 4 系統だけを縦に貫いて固定する。`SpyExchange`（L29-45）が `place_order` の呼び出し回数を Agent で数え、**全ケースで `place_count() == 0`**（例外は live 正常系のみ）をアサートする。さらに拒否時は `Order` が 1 行も作られないことまで確認する（L215-219, L243-247, L262-266, L288-292）。「発注していないこと」を積極的に証明するテストは書かれないことが多く、これがあるかどうかで paper / dry_run の信頼度は決定的に変わる。テストの moduledoc に「部品テストは各モジュールに任せ、ここでは縦貫通の安全ネットだけを固定する」と役割分担まで書かれている。この 1 ファイルは同規模の個人プロジェクトで見たことのない水準。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/capital_preservation_test.exs`

- **テスト環境で実ネットワーク接続を設定レベルで禁止している** `+4`
  > `config/test.exs` L35-40 が `Bitflyer.MarketData` を `enabled: false` にし、`rest_client` を `Rest.Stub`、`socket_client` を `Socket.Local` に差し替える。加えて L30-33 で `Startup.Reconciler` を `boot?: false, interval_ms: :infinity` にし、SQL Sandbox の所有権と衝突しないようにしている（理由もコメント済み）。テストごとに mock を仕込むのではなく、**環境として外部接続を持たない**設計にしているため、「うっかり本物を叩くテスト」が書けない。`Feed` 側も `socket_client` / `rest_client` / `ws_url` を opts で受ける（feed.ex L44-71）ため、テストからの注入が自然に書ける。
  > 対象ファイル: `config/test.exs`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **再接続・穴埋め・切断といった時間依存の挙動をテスト可能にしている** `+3`
  > `Feed.status/1` と `Feed.gap_fill/1`（feed.ex L23-37）がテスト用の観測・駆動 API として用意され、`feed_test.exs`（247 行）が接続・購読・切断・再接続・穴埋めの順序を検証できる。`Cache.fresh?/3` は `now:` で monotonic 時刻を注入でき（cache.ex L59-69）、`Reconciler.run_now/1` で突合を明示駆動できる。時間・ネットワーク・DB という「テストしにくい 3 点」に、それぞれ注入口を先に用意してから実装している。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/market_data/feed_test.exs`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **テスト補助の切り出しが適切** `+2`
  > `Bitflyer.DataCase`（Sandbox 所有権）、`MarketDataCacheHelper`、`ReadinessHelper` の 3 つに共通処理を集約し、各テストの `setup` が「状態リセット → env 退避 → on_exit で復元」の同じ形になっている。グローバル状態（Application env / ETS / DB）を触るテストが多いにもかかわらず、実行順に依存する壊れ方をしていない（シード違いの 2 回実行で確認済み）。
  > 対象ファイル: `apps/bitflyer/test/support/`

### 変更容易性・保守性

- **文書とコードの一致度が高い** `+3`
  > overview.md L131「Ready 状態の正本は `Bitflyer.Readiness`（`:not_ready` / `:ready` / `{:halted, reason}`）」、L133「`GET /health`。DB 断または readiness halted のとき 503」、L145-148 の telemetry イベント例、L100-108 の取引モード表 — いずれも実装の型・関数・分岐と 1 対 1 で対応している。Architecture が「後追いの説明文」ではなく「実装の仕様書」として機能している。ci-cd.md の保証範囲表と `ci.yml` のステップも一致する。この一致度は、評価文書を書く側から見て検証コストが劇的に下がる。
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/ci-cd.md`

- **第 3 アプリを切らず、一方向依存を保っている** `+2`
  > Umbrella は `apps/bitflyer` と `apps/ui` の 2 つのまま。`apps/bitflyer/mix.exs` の deps は `ash` / `ash_postgres` / `telemetry` / `req` / `jason` / `websockex` の 6 つで `ui` を参照しない。ペーパー取引は `apps/paper` ではなく `OrderExecutor.Paper` として、取引所接続は `Bitflyer.Exchange` アダプタとして `bitflyer` 内に置かれている。overview.md L61 の「第 3 の Umbrella アプリは切らない」が、実装が進んだ後も守られている。
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/ui/mix.exs`

### プロジェクト全体設計

- **改善計画を宣言で終わらせず、1 サイクルで P0〜P2 を消化している** `+3`
  > `improvement-plan.md` の P0（#1-5: precommit / MIX_ENV / CI / README / テスト DB）、P1（#6-10: TradeMode / Readiness / health / telemetry / dockerignore）、P2（#11-17: 永続 Resource / boot reconcile / ETS 鮮度 / risk / executor / market-data / 回帰テスト）は、対象ファイルを読み直した限り **17 項目すべてが実装として存在する**。評価 → 計画 → 実装 → 再評価というサイクルが、文書上の建前ではなく実際に回っている。`.workspace` のステージ分け（backlog / todo / archive）も、02（CI）が archive へ移り 03（CD）が todo に残るという形で更新されている。
  > 対象ファイル: `.workspace/0_doc/evaluation/improvement-plan.md`, `.workspace/2_todo/`, `.workspace/3_archive/`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| 技術評価層 — apps/bitflyer | +64 |
| 技術評価層 — apps/ui | +13 |
| 技術評価層 — 実行基盤 / 設定 | +25 |
| 横断評価層 | +22 |
| **合計** | **+124** |
