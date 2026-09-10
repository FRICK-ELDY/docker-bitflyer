# 第1評価者（Claude Opus 5）— 提案 2026-09-10_2

対象コミット: `2c21cf9`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 提案。現状の実装が誤りとは言えないが、こうすればさらに良くなるという改善案 |

本ファイルの項目はすべて `0` 点であり、総合スコアには影響しない。
「今は間違っていないが、次に効く」ものだけを挙げる。優先度は各項目の末尾に付す。

---

## 資金保全・リスク

### FX 証拠金モデル

- **`FX_BTC_JPY` 向けに `getcollateral` 正本と必要証拠金拘束へ切り替える** `0`
  > マイナス点で `-3` とした「スポット残高モデルを FX 既定銘柄に当てている」件の前向き案。実装イメージは次のとおり。(1) `Exchange.Client` に `fetch_collateral/0` を足し、live 突合で `collateral` / `require_collateral` / `keep_rate` を読む。(2) FX 銘柄の `BalanceCache` はスポット通貨マップではなく「利用可能証拠金」を 1 値（または口座別）で持つ。(3) `Risk.balance_hold/2` は売りでも BTC を要求せず、サイズ×価格×証拠金率の見積もりを拘束する（買いは同型）。(4) 維持率が閾値を下回ったら `open_circuit(:margin_call)`。スポット `BTC_JPY` は現行の getbalance 経路を残し、`Product.market_type/1` で分岐する。**優先度: 高**（既定銘柄が FX である以上、live 解禁の前提）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/trading/product.ex`

### 含み損を日次損失に組み込む

- **未実現損益を含めた日次ドローダウン判定** `0`
  > 現状の `DailyLoss` は `Fill.realized_pnl` の合計、つまり**確定損益のみ**を見る（daily_loss.ex L380-396）。README L28 も「含み損は未計上」と正直に書いている。これは正しい第一歩だが、建玉を持ち越す戦略が入ると穴になる。100 万円の含み損を抱えていても、決済しない限り日次損失は 0 のままで、サーキットは開かない。
  >
  > 提案は、`MarketData.Cache` の最新価格と `Position.average_price` から未実現損益を計算し、`realized + unrealized` を第 2 の閾値（例 `BITFLYER_MAX_DAILY_DRAWDOWN_JPY`）で判定することである。実装上の注意が 2 点ある。(1) 価格が stale なときは未実現損益を計算できないので、既存の鮮度ゲートと同じく fail-closed か「実現のみで判定 + 警告」のどちらかを明示的に選ぶ。(2) 未実現分は tick ごとに動くので、ETS 正本に書き込むのではなく判定時に計算する（`DailyLoss` の世代/barrier プロトコルを未実現で汚さない）。
  >
  > Vision の「1日の最大損失を超えたら止まる」という記述は、素直に読めば含み損も含む。**優先度: 高**（戦略が建玉を持ち越すようになる前に入れたい）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### 価格の異常検知

- **板・約定履歴を購読して spread / 板厚を発注条件に加える** `0`
  > 現在購読しているのは `lightning_ticker_*` のみで、`lightning_board_*` / `lightning_executions_*` は README L182-188 で「—」と明示されている。ticker には `best_bid` / `best_ask` が含まれるので、まず**追加購読なしでできること**から提案する。
  >
  > (1) `Normalize` が `best_bid` / `best_ask` を保持し、`(ask − bid) / mid` が閾値を超えたら発注拒否する。異常なスプレッドは板が薄い・障害中・値幅制限のいずれかで、いずれも成行を出してはいけない場面である。(2) `FillPricing` の slippage を固定 bps ではなく実スプレッドから推定する。
  >
  > 板購読（`lightning_board_snapshot_*` + 差分適用）は状態管理が重く、`market_data.tick` の頻度も跳ね上がるので、ticker の bid/ask を使い切ってから検討すればよい。**優先度: 中**
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **建玉に対する損切り・利確の自動発注** `0`
  > 現状、建玉を閉じる仕組みは戦略の tick 経由しかない。戦略が停止していても（`Strategy.enabled?` が false、あるいは Runner がクラッシュ中でも）建玉は残る。Vision の「資金保全最優先」を突き詰めると、**戦略とは独立に**建玉を守る層が要る。
  >
  > 提案は、`Position` ごとに `stop_loss_price` を持ち、`Risk` 側（戦略ではなく）が価格を監視して閾値超過で決済 command を生成する仕組みである。ただしこれは「自動発注」なので、halt 中に動かすか否か、鮮度ゲートとの関係、二重発注防止（`AuthorizedOrder` のワンショット性は使える）を先に決める必要がある。戦略仕様が固まっていない現段階では設計だけ用意しておけばよい。**優先度: 中**（ただし live 常時稼働の前には必須）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/trading/position.ex`

---

## 観測・運用

### metrics の外部化

- **Prometheus エクスポータの追加（`ConsoleReporter` の次の段）** `0`
  > `ConsoleReporter` を prod 既定にしたことで「数値がどこにも出ない」状態は解消したが、これは**時系列として蓄積されない**。「1 時間前より拒否率が上がった」「WS 再接続が増えている」といった傾向は読めない。
  >
  > `telemetry_metrics_prometheus_core` を足し、`/metrics` を BasicAuth 配下（`PHX_HTTP_IP` が loopback 既定なので外部露出はしない）に生やすのが最小構成である。`UiWeb.Telemetry.metrics/0` の宣言はそのまま使える。収集側は Vision の 512 GB ストレージなら Prometheus + Grafana を同一ホストに置ける。`market_data.tick` は counter のみにしてカーディナリティを抑える（`product_code` 以外のラベルを付けない）こと。**優先度: 中**
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`, `apps/ui/lib/ui_web/router.ex`

### 運用画面の情報密度

- **StatusLive に建玉・未約定注文・当日損益を表示する** `0`
  > 現在の StatusLive は trade_mode / readiness / 市場データ鮮度 / 操作ボタンで、**ポジションと未約定注文が見えない**。「今トレードしてよいか」は分かるが「今いくら持っているか」が分からない。異常時に最初に見たいのは後者である。
  >
  > 追加したいのは 4 つ。(1) 建玉一覧（product / side / size / average_price / 現在価格からの含み損益）。(2) 未約定注文一覧（`status in [:pending, :partially_filled]` + 経過時間）。(3) 当日実現損益と日次上限までの残り。(4) halt 中は `HaltReason` の詳細と、それを解消するために何をすべきか（`resume` で足りるのか `recover` が要るのか）。
  >
  > 実装上は既存の `OperationalStatus` にスナップショット関数を足し、LiveView 側は描画に徹する現在の分離を保つこと。件数が増えうる注文一覧は `stream/3` を使う。**優先度: 高**（実装コストが小さく、live 運用時の価値が大きい）
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/operational_status.ex`

- **Discord 通知に約定サマリと日次クローズを追加する** `0`
  > 現在の通知は readiness 変化・突合 mismatch・halt が中心で、「正常に動いている」ことは通知されない。無音が「順調」なのか「Bot 自体が死んでいる」のかを区別できない。
  >
  > (1) JST 日次クローズ時刻に、当日の約定件数・実現損益・拒否内訳・再接続回数のサマリを 1 通投げる。これは「生存確認」も兼ねる。(2) 一定額を超える約定は個別通知。いずれも既存の `Observe.Discord` に telemetry ハンドラを足すだけで、発注経路には触れない。cooldown の仕組みも既にある。**優先度: 中**
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

---

## データ・永続化

### データ量の管理

- **`BalanceSnapshot` / `Order` / `Fill` の保持方針を決める** `0`
  > マイナス点として「保持方針が無い」を計上したが、実装方針としてはいくつか選択肢があるので提案側にも書く。
  >
  > (1) `BalanceSnapshot` は append-only の性質上、行数が単調増加する。日次でロールアップして古い行を削る、または `(trade_mode, currency, captured_at)` の複合インデックスを張って読取だけ守る。(2) `Order` / `Fill` は監査証跡なので消したくない——ならば `captured_at` / `filled_at` の月次パーティションにして、古いパーティションを分離可能にしておく。(3) 最低限、`pg_total_relation_size` を定期ログに出して増加率を可視化する（これだけなら数行）。
  >
  > 512 GB あるので当面は破綻しないが、「いつ判断するか」の材料が無い状態は避けたい。**優先度: 中**
  > 対象ファイル: `apps/bitflyer/priv/repo/migrations/`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

- **`Fill` に `belongs_to :order` と `exchange_execution_id` の一意制約を入れる** `0`
  > 現在 `Fill` は `internal_order_id` を `:string` で持つだけで（fill.ex L44-47）、`belongs_to` 関連も外部キー制約も無い。`exchange_execution_id` も `allow_nil?: true` で一意制約が無い。
  >
  > 提案は、(1) `belongs_to :order, Bitflyer.Trading.Order` にして参照整合性を DB に持たせる、(2) live の Fill には取引所の execution id を必ず入れ、`(trade_mode, exchange_execution_id)` に部分一意インデックス（`WHERE exchange_execution_id IS NOT NULL`）を張る。(2) は `getexecutions` の結果を明細単位で保存する形に変える必要があり、これは「部分約定の VWAP 誤り」（マイナス点）の修正と同じ作業になるので、まとめて実施するのが効率的である。冪等性が DB で保証されれば、突合と再取得を安心して繰り返せる。**優先度: 高**（マイナス点の修正と一体）
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/priv/repo/migrations/`

---

## 品質ゲート・テスト

- **`precommit` に `ash.codegen --check` を追加する** `0`
  > マイナス点として計上したが、対応は 1 行である。
  >
  > ```elixir
  > # mix.exs の precommit エイリアス
  > "ash.codegen --check",
  > ```
  >
  > Resource の属性を変えてマイグレーション生成を忘れると、現在は開発 DB（既に列がある）でテストが通り、本番の新規 DB で初めて落ちる。CI がクリーンな DB を作るなら理論上は落ちるが、`--check` なら**そもそも差分があること自体**を差分として検出できるので、原因が即座に分かる。**優先度: 高**（コスト最小・効果明確）
  > 対象ファイル: `mix.exs`

- **`test_helper.exs` に `Mox`/契約テストの土台を用意する** `0`
  > 現在 5 つの behaviour をすべて手書きスタブで差し替えている。手書きスタブは読みやすい反面、**behaviour にコールバックを追加してもスタブが古いまま warning すら出ない**（`@behaviour` 属性を付けていないスタブがある）。
  >
  > 最小の改善は、各スタブモジュールに `@behaviour Bitflyer.Exchange.Client` を明記することである（これだけで未実装コールバックが compile warning になり、`--warnings-as-errors` で落ちる）。さらに進めるなら `Mox.defmock` に置き換え、`verify_on_exit!` で「呼ばれるはずの REST が呼ばれていない」も検出できる。ただし現在のスタブは決定的で読みやすいので、`@behaviour` 明記だけでも大半の価値が取れる。**優先度: 中**
  > 対象ファイル: `apps/bitflyer/test/support/exchange_client_stubs.ex`, `apps/bitflyer/test/test_helper.exs`

- **paper モードでの長時間連続稼働テスト（soak test）** `0`
  > 現在のテストは単発シナリオの回帰で、`mix test` は 2.5 秒で終わる。これは素晴らしいが、**時間経過でしか出ない問題**は検出できない。ETS の肥大（`OrderRate` の duplicate_bag、`AuthorizedOrder` の未消費トークン）、WS の長時間接続後の挙動、日跨ぎ（JST 0 時）の `DailyLoss` リセット、`BalanceSnapshot` の行数増加、メモリリーク。
  >
  > 提案は、`paper` モードで 24〜72 時間動かし、`:erlang.memory/0`・ETS サイズ・DB 行数・再接続回数を定期記録する運用手順を README に足すことである。CI で回す必要はない。live 解禁の前提条件として位置づけるのが良い。**優先度: 高**（live 解禁の判断材料として）
  > 対象ファイル: `README.md`, 運用手順

---

## 実行基盤

- **`websockex` の代替検討、または薄いラッパへの隔離** `0`
  > マイナス点に挙げたとおり `{:websockex, "~> 0.4"}` は更新が停滞している。ただし現在の設計では既に `MarketData.Socket.Client` behaviour で抽象化されており、実装は `Socket.Client`（websockex 版）と `Socket.Local`（テスト版）の 2 つがある。つまり**差し替えの下準備は既にできている**。
  >
  > 選択肢は 2 つ。(1) `Mint.WebSocket` + `Fresh` などに移行する。(2) 現状維持し、`mix hex.outdated` の結果を CI の artifact に残して停滞を可視化しておく。急ぐ必要はないが、`Erlang/OTP 28` へ上げるタイミングで動かなくなる可能性があるので、そのときに慌てないよう behaviour の境界を今のまま保つこと（`websockex` 固有の型が `Feed` に漏れていないかを定期確認する）。**優先度: 低**
  > 対象ファイル: `apps/bitflyer/mix.exs`, `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`

- **開発用 `Dockerfile` に `USER` を入れ、ホストの uid/gid と揃える** `0`
  > マイナス点に挙げた開発コンテナの root 実行について、Windows + WSL2 環境では bind mount のファイル所有者問題があるため単純に `USER app` を足すと `_build` が書けなくなる可能性がある。
  >
  > 提案は build arg で uid/gid を受ける形である。
  >
  > ```dockerfile
  > ARG UID=1000
  > ARG GID=1000
  > RUN groupadd --gid ${GID} app && useradd --uid ${UID} --gid ${GID} -m app
  > USER app
  > ```
  >
  > compose.yaml 側で `args: {UID: "${UID:-1000}", GID: "${GID:-1000}"}` を渡す。WSL2 で不都合が出るなら見送ってよいが、**その判断理由を Dockerfile のコメントに残す**ことが重要である（現在は「なぜ root なのか」が書かれていないので、意図なのか漏れなのか区別できない）。**優先度: 低**
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **`apps/bitflyer/README.md` の TODO を埋める** `0`
  > `**TODO: Add description**` がリポジトリで唯一残る TODO である。ルート README が充実しているので、ここは「このアプリの責務は取引所連携・ドメイン・エンジン。UI は含まない。詳細はルート README と `.workspace/0_doc/architecture/overview.md` を参照」という 3 行で十分。あるいは umbrella の慣習として `apps/*/README.md` を置かない選択もある。**優先度: 低**
  > 対象ファイル: `apps/bitflyer/README.md`

---

## 優先度まとめ

| 優先度 | 提案 |
|:---|:---|
| 高 | FX 証拠金モデル（`getcollateral` + 必要証拠金拘束） |
| 高 | 含み損を日次損失に組み込む |
| 高 | StatusLive に建玉・未約定注文・当日損益を表示 |
| 高 | `Fill` の `belongs_to` + `exchange_execution_id` 一意制約（VWAP 修正と一体） |
| 高 | `precommit` に `ash.codegen --check` |
| 高 | paper での soak test（live 解禁の前提） |
| 中 | ticker の bid/ask でスプレッド異常を検知 |
| 中 | 戦略非依存の損切り層 |
| 中 | Prometheus エクスポータ |
| 中 | Discord の日次サマリ通知 |
| 中 | データ保持方針 |
| 中 | スタブへの `@behaviour` 明記 |
| 低 | `websockex` 代替検討 |
| 低 | 開発 Dockerfile の `USER` |
| 低 | `apps/bitflyer/README.md` |
