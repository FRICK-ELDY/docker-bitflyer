# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-09

対象コミット: `e029bd6`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)
前回（自系統）: [opus/archive/2026-09-08](./archive/2026-09-08/opus-specific-weaknesses-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -37 点**

---

## 技術評価層 — apps/bitflyer

### 発注経路の縦貫通

- **strategy が 1 行も存在せず、`submit_order/2` を呼ぶ本番コードが 0 件** `-3`
  > `apps/bitflyer/lib/bitflyer/` 配下に strategy に相当するモジュールは無い（`Strategy` の grep 一致は `Supervisor.init(strategy: :one_for_one)` のみ）。`Bitflyer.System.submit_order/2`（system.ex L105-107）と `OrderExecutor.submit/2` の呼び出し元は、テストコード（`order_executor_test.exs`, `capital_preservation_test.exs`）だけである。`MarketData.Feed` は tick を Cache に書き telemetry を出すが、その先に判断を行うプロセスが繋がっていない。結果として、`docker compose up` した状態で放置しても **注文意図が 1 件も生まれない**。Vision は「戦略の中身は後続のバックログで定義する」（vision.md L27）としており戦略アルゴリズムの不在は計画どおりだが、判定ループそのもの（tick を購読して意図を出し `Risk` → `OrderExecutor` へ渡す骨）が無いため、Architecture の発注経路（overview.md L136-142）は 5 ステップ中 1 が欠けたままである。risk / executor / 突合の品質が高いだけに、それらを一度も本番経路で駆動していないのは損失。
  > 改善方針: アルゴリズムを作らず「常に何もしない」`Bitflyer.Strategy` ビヘイビアと 1 本の固定ルール実装（例: tick を受けて閾値超過で 1 回だけ意図を出す）を先に置き、`Feed` → `Strategy` → `Risk` → `OrderExecutor` を `dry_run` で端から端まで通す。戦略の質はその後でよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/bitflyer/lib/bitflyer/system.ex`

### order-executor

- **`live` に約定確認と注文取消が無く、片道の経路になっている** `-3`
  > `Bitflyer.Exchange.Client` の callback は `fetch_reconcile_snapshot/0` と `place_order/1` の 2 つだけ（client.ex L49-50）。`cancel_order` も注文状態の照会も定義されていない。`OrderExecutor` にも `cancel/1` は無い。したがって `live` で発注した注文は `status: :pending` のまま残り、約定しても `Position` は更新されず、`filled_size` も動かない。overview.md L40 は order-executor の責務を「注文の送信・取消・約定確認」と定義し、prod.md L47 は「サーキットが開いたら、新規注文を止め、必要なら全取消方針を設定で選べるようにする」と書いているが、どちらも実装手段が無い。現状は `Exchange.Unavailable` により live へ到達できないため実害は出ていないが、live 解禁の前に必ず埋める必要がある欠落であり、「発注はできるが取り消せない」状態で解禁されると資金保全上もっとも危険。
  > 改善方針: `Client` に `cancel_order/1` と `fetch_order/1`（または `fetch_executions/1`）を追加し、`OrderExecutor.cancel/2` を `live` / `paper` / `dry_run` の 3 出口で実装する。約定反映は定期突合（`Reconciler`）の中で `Positions.apply_fill/2` を再利用する形が素直。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

### risk-manager

- **リスク検査が 5 種類中 2 種類しか無く、日次損失・発注頻度・価格逸脱が未実装** `-3`
  > `Risk.Limits.t()` は `max_order_size` / `max_position_size` / `market_data_max_age_ms` の 3 キーのみ（limits.ex L9-13）。`authorize/2` の検査は「コマンド妥当性 → 同期 → 鮮度 → 注文サイズ → 想定建玉」で、**損失・頻度・価格逸脱・残高**を見る経路が存在しない。prod.md L45-46 は「注文サイズ、建玉、日次損失、発注回数にハードリミットを置く」「価格が直近相場から乖離した注文は出さない」と明示し、dev.md L61-63 も「損失・連続エラー回数が閾値を超えたら戦略を止める」を開発でも必須としている。Vision の Safety first は「利益より、想定外の損失を止めること」であり、その中核は損失リミットである。サイズ上限だけでは、小口を高頻度で出し続ける事故や、板が飛んだ瞬間の異常価格約定を止められない。
  > 改善方針: `Limits` に `max_daily_loss` / `max_orders_per_minute` / `max_price_deviation_pct` を足し、日次損益は `BalanceSnapshot`（後述）または約定履歴から算出する。頻度は ETS のスライディングウィンドウで十分。価格逸脱は既に Cache にある LTP と指値の比で判定できる（新規の外部依存が要らない）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/limits.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### datastore / 突合

- **`BalanceSnapshot` が本番コードから一度も書かれず、残高突合が実質ノーオペ** `-2`
  > `BalanceSnapshot` を `Ash.create` している箇所は、`lib/` 配下に 1 件も無い（生成はテストのみ）。`Startup.Reconcile.read_latest_balances/1`（reconcile.ex L308-321）は内部スナップショットを読むが常に空リストが返り、`compare_balances/2`（L198-219）は「内部にある通貨だけ突合する」設計のため **必ず `:ok` を返す**。つまり live の残高突合は現状まったく機能していない。加えて overview.md L105 は `paper` の仕様として「仮想残高・建玉を datastore に書く」と定めているが、`OrderExecutor.Paper` は建玉のみ更新し残高を書かない。Resource とマイグレーションは存在するのに書き込み側が無いため、「あるように見えて無い」もっとも見つけにくい欠落になっている。
  > 改善方針: `paper` の擬似約定時に同一トランザクション内で仮想残高スナップショットを 1 行足す。`live` は突合時に取引所残高をそのままスナップショットとして保存し、次回突合の内部基準にする。少なくとも「内部が空なら突合をスキップせず `:unsynced` 相当で halt する」に倒す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **戦略パラメータの適用履歴 Resource が無い** `-1`
  > overview.md L114-120 が挙げる永続化の最低限 6 項目のうち、「戦略パラメータの適用履歴」だけ Resource が存在しない（`Trading` ドメインは `Order` / `Position` / `BalanceSnapshot` / `RiskState` の 4 つ）。現在の上限値は `config/config.exs` L26-29 のコンパイル時設定で、いつ誰が変えたかは git 履歴にしか残らない。evaluation.mdc の strategy 観点「パラメータ適用履歴と戦略切替の安全性」も未達。strategy 未実装と表裏なので軽めに扱う。
  > 改善方針: strategy を入れる際に `StrategyParameter`（適用日時・値・適用者・理由）を同時に置き、risk の上限もそこから読む。設定ファイル直読のままだと、本番でパラメータを変えた事実が観測できない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `config/config.exs`

### 復帰と停止

- **halted からの復帰手段が UI にも mix タスクにも無い** `-2`
  > `Readiness.clear_halt/1` と `Risk.clear_circuit/1` は関数として存在するが、`lib/` 配下に呼び出し元が無い（テストのみ）。`Reconciler.apply_result/2` は halted 中に自動で Ready へ戻さない設計（reconciler.ex L105-108）で、これ自体は正しい。しかし復帰の入口が用意されていないため、**halt すると remote console で `Bitflyer.Readiness.clear_halt()` を叩く以外に再開できない**。本番 PC は VLAN1 で無人稼働し、作業用 PC から監視する構成（vision.md L88-108）であり、prod.md L31 は「停止・再開の手順が文書化されている」を稼働要件に挙げているが、その手順は現時点で書かれていない。Vision の「安全側（取引停止または再同期）に倒れる」のうち、再同期側の経路が人間に開かれていない。
  > 改善方針: まず `mix bitflyer.resume`（突合を再実行し、成功したときだけ halt を解除する）を用意する。UI からの操作は認証（後述）が入ってから。自動解除にはしないという現在の判断は維持してよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **グレースフルシャットダウンの経路が無い** `-2`
  > `Bitflyer.Application` には `stop/1` も `prepare_stop/1` も無く、子プロセスに `shutdown:` 指定も無い（application.ex L10-22）。`compose.yaml` の `app` にも `stop_grace_period` が無いため、既定 10 秒で SIGKILL される。前回評価時は「書き込むものが Heartbeat しかない」ため軽微としたが、現在は注文・建玉・RiskState を書いている。特に `OrderExecutor.Live.place/1` は「`place_order` の REST 応答を待つ → `exchange_order_id` を保存する」の 2 段構えなので、この間に SIGTERM/SIGKILL が入ると **取引所には注文があるのに内部に ID が無い**状態を作れる。この状態は次回起動時の `compare_open_orders/2` で halt されるため資金は守られるが、「デプロイのたびに手動復帰が必要になる」設計であり、overview.md L147 の要求（新規発注を止め、進行中の書き込みを終えてから終了する）を満たしていない。
  > 改善方針: 監督ツリーの先頭に「発注ゲートを閉じる」処理を置く（`Readiness.mark_not_ready/0` を `prepare_stop` で呼ぶ）。`Reconciler` / `Feed` に `shutdown: 30_000` を与え、`compose.yaml` に `stop_grace_period: 30s` を揃える。ToDo 03 手順 5 の「デプロイ前に新規発注を止める」を、手順ではなくコードで担保する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`

### market-data

- **時計ずれ（clock skew）を拒否理由にできない** `-1`
  > `Cache` が monotonic 時刻を使うため鮮度判定は壁時計の変動に強い（これは加点した）が、**取引所時刻との差を測る仕組みが無い**。overview.md L146 は「時計ずれは注文や署名に影響するため、ホストの時刻同期を前提にする」とし、evaluation.mdc の risk 観点も「市場データ鮮度・時計ずれを拒否理由にできること」を挙げている。本番 PC は Windows 11 + WSL2 で、Vision 自身が「WSL2 の時刻ずれ」をリスクとして明記している（vision.md L122）。前提に置くだけで検知しないと、署名エラーが連発してから気付くことになる。
  > 改善方針: REST 応答の `Date` ヘッダまたは ticker の `timestamp` とホスト時刻の差を定期記録し、閾値超過で `Risk` の拒否理由（`:clock_skew`）とサーキット条件に加える。`Bitflyer.Telemetry` にイベントを 1 つ足すだけで観測は始められる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **market-data が ticker のみで、板・約定を扱わない** `-1`
  > `Normalize` は ticker 専用（normalize.ex L9-22）で、`ltp` 1 フィールドしか取り出さない。購読チャネルも `lightning_ticker_*` のみ（market_data.ex L29-32）。overview.md L36 は market-data の責務を「板・約定・Ticker を購読し、正規化して内部へ渡す」としている。実務上の影響は `paper` の擬似約定に出ていて、`OrderExecutor.Paper.fill_price/3` は成行を **LTP でそのまま即時全量約定** させる（paper.ex L59-78）。板もスプレッドも手数料も無いため、paper の損益は本番より必ず楽観的になる。overview.md L98 が「同じ経路を通さないペーパーは、本番で初めて壊れる」と書いている趣旨からは、約定モデルの乖離もその一種である。
  > 改善方針: 先に `lightning_executions_*` を購読して約定履歴を Cache に持ち、paper の約定価格を「直近約定 + 固定スリッページ + 手数料率」にする。板（`lightning_board_snapshot_*`）は差分適用が必要なので後回しでよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

### 可観測性

- **telemetry の allowlist に `:kind` / `:currency` が無く、突合不整合の診断情報が捨てられている** `-1`
  > `Reconciler.apply_result/2` は失敗時に `Map.take(details, [:product_code, :currency, :kind])` を metadata に混ぜる（reconciler.ex L153）が、`Bitflyer.Telemetry` の allowlist（telemetry.ex L36-52）には `:kind` も `:currency` も含まれていないため、`sanitize_metadata/1` が両方を落とす。`Reconcile` が返す `%{kind: :position_mismatch}` / `%{kind: :open_order_missing_exchange_id}` / `%{currency: "JPY"}` といった、**不整合の種類を特定するための情報がイベントに一切乗らない**。残るのは `reason: :reconcile_mismatch` だけで、「建玉がずれたのか、未確定注文が残ったのか、残高がずれたのか」がログから区別できない。Vision の Observable（約定・拒否・切断・再起動の理由を残す）に対して、いちばん理由を知りたい場面で理由が消えている。同様に `Risk` の `%{limit: :max_order_size}` も落ちている。
  > 改善方針: allowlist に `:kind` / `:currency` / `:limit` / `:market_key` を追加し、`config/config.exs` の Logger メタデータにも同じキーを足す。allowlist は「秘密を通さない」ためのものなので、診断キーを足すこと自体は方針に反しない。追加の際は allowlist と Logger メタデータの二重管理をテストで固定する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `config/config.exs`

### 残骸

- **`Bitflyer.System.Heartbeat` が用途を失ったまま残っている** `-1`
  > `Heartbeat` は `note` 文字列 1 個の Resource で、`lib/` 配下から書き込む箇所も読む箇所も無い。`heartbeats` テーブルのマイグレーション 2 本と resource snapshot も残る。骨格検証用に作られたものが、`Trading` ドメインと `Health` / `Readiness` の整備後も棚卸しされていない。`Bitflyer.System` は今や `check_database/0` / `health/1` / `readiness/0` / `submit_order/2` を並べたファサードであり、Ash Domain である必然性も薄れている（`resources do resource Heartbeat end` を保つためだけに Domain になっている）。
  > 改善方針: `Heartbeat` を削除してマイグレーションで `heartbeats` を落とし、`Bitflyer.System` を通常モジュール（ファサード）にする。`config/config.exs` の `ash_domains` と `ash.setup --domains` の引数、CI・entrypoint の 2 箇所も同時に更新する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

---

## 技術評価層 — apps/ui

### 運用可視性

- **「今トレードしてよいか」が 1 画面で分からない** `-2`
  > `StatusLive` が出すのは取引モード / Ready 状態 / PostgreSQL 到達可否の 3 カードのみ（status_live.ex L69-103）。`Bitflyer.System` には既に `exchange_order_gate/0`（発注可否と停止理由）、`market_data_fresh?/2`（鮮度）、`market_data_status/0`（接続状態・再購読回数）が公開されている（system.ex L56-93）のに、UI がどれも呼んでいない。未約定注文の滞留・建玉・サーキット理由も表示されない。加えて取引モードのカードは `class="mt-1 font-mono text-lg font-medium"` の固定スタイル（L73）で、`dry_run` と `live` が視覚的にまったく区別されない。prod.md L52-62 が監視で必ず見るとした 6 項目（WebSocket 切断時間、未約定滞留、内部と取引所の不一致、日次損益、ディスク/メモリ/時刻同期）のうち、画面に出ているのは 0 項目である。Ready 表示が入ったことで前回より改善はしたが、運用 UI としての最重要要件は未達のまま。
  > 改善方針: 画面最上部に `exchange_order_gate/0` の結果を単一バッジ（`発注可` / `停止: 理由`）として置き、`live` のときだけ配色を変える。次に market_data の最終 tick 経過と Feed 接続状態、未約定注文件数を足す。UI 側にロジックを持たず `Bitflyer.System` の返り値をそのまま描くこと。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

### 公開面と認証

- **UI に認証が無く、本番は全インターフェースにバインドする** `-2`
  > `:browser` パイプライン（router.ex L4-11）に認証プラグは無く、`live "/"` は誰でも開ける。`config/runtime.exs` L160-167 の本番設定は `ip: {0, 0, 0, 0, 0, 0, 0, 0}` で、全インターフェースを受ける。開発は `compose.yaml` の `127.0.0.1:4000` バインドで守られているが、本番 Compose はまだ存在しないため、この既定がそのまま出ていく可能性が残る。ToDo 03 の手順 3 は「ホストへの公開は最小」と書くだけで、認証はチェック項目に無い。VLAN3 の作業用 PC から VLAN1 の本番 UI を見る構成である以上、UI は必ずネットワーク越しに叩かれる。前回指摘から変化なし。
  > 改善方針: 最小でも `Plug.BasicAuth` を `:browser` に挟み、資格情報は環境変数から読む（`/health` は `:api` にあるので影響しない）。ToDo 03 手順 3 に「UI の到達元制限と認証」をチェック項目として追加する。halt 解除の操作を UI に足す前に必須。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `config/runtime.exs`, `.workspace/2_todo/03-cd-prod-host.md`

### 生成物の残骸

- **Phoenix 生成テンプレの残骸が運用画面の一等地を占有している** `-1`
  > `Layouts.app/1` のヘッダは Phoenix のマーケティング用リンク（`Website` L49、`GitHub` L53、`Get Started` L61-63）と `v{Application.spec(:phoenix, :vsn)}`（L42）のままで、稼働状況ページの最上部に出る。`UiWeb.PageController` と `page_html/home.html.heex` はルータのどこからも参照されていない（router.ex L18-33 は `/health` / `/locale/:locale` / `live "/"` のみ）。`Ui.Mailer` と `:swoosh` 依存、`/dev/mailbox` フォワード（router.ex L48）も自動売買システムでは用途が無い。前回指摘から変化なし。残っていること自体より、運用画面のヘッダが「Get Started →」であることが、監視者に対する誤った文脈を与える点が問題。
  > 改善方針: ヘッダを「アプリ名 / 環境 / モードバッジ / 言語切替」に置き換え、`PageController` / `page_html` / `Ui.Mailer` / `:swoosh` / `/dev/mailbox` を削除する。
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`, `apps/ui/lib/ui_web/controllers/page_controller.ex`, `apps/ui/lib/ui/mailer.ex`, `apps/ui/mix.exs`

---

## 技術評価層 — 実行基盤 / 設定

### 本番構成

- **本番用の Dockerfile / Compose / release が無く、本番は起動できない** `-3`
  > `Dockerfile` は先頭に「開発用。ソースは Compose で bind mount する」と明記され（L1）、`CMD ["mix", "phx.server"]`（L20）で終わる。`compose.prod.yaml` も `mix release` の定義も無く、ルート `mix.exs` に `releases:` は無い。Vision の「24時間365日」「本番PC 上で常時稼働」は、engine が揃った現在でもなお **実行手段を持たない**。ToDo 03 に詳細な手順（7 節・完了条件つき）があるのは評価できるが、未着手のため prod.md が定義する運用（バックアップ、公開面最小化、段階的解禁、ロールバック）を一度も試せていない。前回指摘から変化なし。engine が動くようになった今、これが Vision 達成の最大のボトルネックになっている。
  > 改善方針: ToDo 03 の手順 2-3 を先に消化する。Umbrella ルートで `releases: [docker_bitflyer: [applications: [bitflyer: :permanent, ui: :permanent]]]` を定義すれば 1 リリースで足りる。`compose.prod.yaml` は開発版から `build` を外し `image` タグ参照に変えるだけで骨は組める。
  > 対象ファイル: `Dockerfile`, `compose.yaml`, `mix.exs`, `.workspace/2_todo/03-cd-prod-host.md`

- **bitFlyer API キーの環境変数名と注入方法が未定義** `-2`
  > `BITFLYER_API_KEY` 相当の文字列はリポジトリ全体で 0 件（`.env.example` / `dev.md` L43-50 の環境変数表 / `prod.md` / `runtime.exs` のいずれにも無い）。`BITFLYER_LIVE_CONFIRM` は定義されているのに、その確認が守るべき本体のキーが未定義という非対称な状態になっている。`Bitflyer.Exchange` の実クライアントが `Unavailable` しか無いことと表裏で、live 経路は突合も発注も一度も実行できない。前回も同じ指摘をしたが未着手。名前だけでも先に固定しておかないと、実装時に `BF_API_KEY` 等が乱立し、`.env` / CI / 本番ホストで食い違う典型的な事故につながる。
  > 改善方針: `.env.example` に `BITFLYER_API_KEY=` / `BITFLYER_API_SECRET=`（値は空）を追加し、`dev.md` / `prod.md` の表にも載せる。`runtime.exs` では `trade_mode == :live` のときだけ必須にし、欠けていれば起動を止める（`BITFLYER_LIVE_CONFIRM` と同じ扱い）。値は `Bitflyer.Telemetry` の allowlist に絶対に入れない。
  > 対象ファイル: `.env.example`, `.workspace/0_doc/architecture/env/dev.md`, `config/runtime.exs`

- **開発コンテナが root で実行される** `-1`
  > `Dockerfile` に `USER` 指定が無いため、bind mount した `/app` 配下に root 所有のファイルが作られる。開発用途としては許容範囲だが、同じベースから本番イメージを派生させる際に非 root 化を忘れやすい。前回指摘から変化なし。
  > 改善方針: 本番イメージを作るタイミングで、開発イメージも非 root ユーザーへ切り替え、`mix_deps` / `mix_build` ボリュームの所有者を合わせる。
  > 対象ファイル: `Dockerfile`

---

## 横断評価層

### 可観測性・アラート

- **人に届くアラート経路が無い** `-2`
  > 通知コードはリポジトリに存在しない。halt・切断・突合不整合・サーキット開はすべて telemetry とコンテナ標準出力に留まり、`UiWeb.Telemetry` の reporter もコメントアウトされたまま（telemetry.ex L16-17）で、LiveDashboard を人が開いたときにしか見えない。prod.md L11 は「異常時は人に届く。届かない監視は監視ではない」と明記し、L52-62 で監視項目まで列挙している。前回は「監視対象となる取引イベントがまだ無い」ため -1 としたが、**現在はシステムが自分で halt して発注を止められるようになった**。止まったことを誰も知らない時間が長引くほど機会損失と復旧遅延が積む。無人稼働（vision.md L46-48）を前提とする以上、優先度は上がっている。
  > 改善方針: `.workspace/1_backlog/discord-notify-adapter.md` の方針どおり `apps/bitflyer` 内のアダプタとして実装する。まず `readiness_changed`（Ready → halted）と `reconcile_mismatch`、`market_data_disconnected` の 3 イベントに telemetry handler を張るだけでよい。Webhook 未設定でも起動が落ちないこと、通知失敗が取引を止めないことをテストで固定する。
  > 対象ファイル: `.workspace/1_backlog/discord-notify-adapter.md`, `apps/ui/lib/ui_web/telemetry.ex`

### テスト戦略

- **`test_helper.exs` に Sandbox のモード指定が無い** `-1`
  > `apps/bitflyer/test/test_helper.exs` も `apps/ui/test/test_helper.exs` も `ExUnit.start()` の 1 行のみで、`Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` が呼ばれていない。現在は DB を触るテストがすべて `Bitflyer.DataCase` / `UiWeb.ConnCase` を経由し、`start_owner!/2` で所有権を取るため実害は出ていない（シードを変えた 2 回の実行で確認済み）。ただし明示が無い分、`use` を書き忘れたテストが 1 本入った時点でテスト DB に実データが残り、しかも他テストの `read_one` が壊れて初めて気付く形になる。前回指摘から変化なし。
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加する。1 行で「checkout していないプロセスは DB に触れない」が保証される。
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/test_helper.exs`

### セキュリティ・依存管理

- **依存の脆弱性管理が無い** `-1`
  > `mix_audit` / `sobelow` / `dialyxir` / `credo` のいずれも `mix.lock` に無い。`heroicons` と `daisyui` は GitHub からタグ指定で取得している（apps/ui/mix.exs L51-64）。実資金を扱うプロセスとして、依存の既知脆弱性を機械的に見る手段が無い。ci-cd.md L30 が「Credo / Dialyzer / deps audit（後続で足してよい）」と非保証範囲に明記しているため、意図的な後回しである点を踏まえて軽く扱う。前回指摘から変化なし。
  > 改善方針: CI に `mix_audit` を 1 ステップ足す（最初は `continue-on-error: true` でよい）。`Dialyzer` は `Bitflyer.Exchange.Client` の behaviour と `@spec` が揃っている今なら投資対効果が高い。
  > 対象ファイル: `.github/workflows/ci.yml`, `apps/bitflyer/mix.exs`, `apps/ui/mix.exs`

### 保守性

- **`Reconcile.read_latest_balances/1` だけが生 Ecto クエリで、例外を広く握っている** `-1`
  > `startup/reconcile.ex` L308-321 は関数内で `import Ecto.Query` して `distinct: b.currency` の生クエリを書き、`rescue error -> {:error, error}` で締める。他の読み出し（`read_risk_state/0` / `read_positions/1` / `read_open_orders/1`）はすべて `Ash.Query` 経由で `{:ok, _} | {:error, _}` を返しており、この 1 関数だけ抽象レベルと失敗の扱いが違う。`DISTINCT ON` が Ash で書きにくいという事情は理解できるが、理由がコード上に書かれていないため、次に読む人は「Ash でも書けるのに手を抜いた」のか「書けないから逃げた」のか判断できない。`rescue` が全例外を捕まえる点も、`Ash.read/1` の `{:error, _}` と粒度が揃っていない。
  > 改善方針: 最低でも「なぜ Ash ではなく Ecto なのか」を 1 行コメントで残す。可能なら `Ash.Query.sort/2` + `Ash.Query.limit/2` を通貨ごとに回すか、`BalanceSnapshot` に「最新フラグ」を持たせて Ash で完結させる。`rescue` は `Postgrex.Error` 等に絞る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

### 開発者体験（DX）

- **README の「現状」が実装より古く、実装済みの engine を未実装と書いている** `-1`
  > README L18 は「市場データ・戦略・リスク・発注の engine は未実装（`TRADE_MODE` の既定は `dry_run`）」、L105 は「これから作るもの: 市場データ、戦略、リスク、発注、永続化の各コンポーネント」と書く。実際には strategy 以外の 4 つは実装され、テストも通っている。前回「README がアーカイブと矛盾する」と指摘した箇所は直っているが、今度は **実装が README を追い越した**。新規参加者が README を信じると、既にある `Risk.authorize/2` や `OrderExecutor.submit/2` を二重に作りかねない。品質ゲート・環境変数・ドキュメント目次の記述は実測どおりで正確なだけに、この 2 箇所が浮いている。
  > 改善方針: 「現状」に market-data / risk / order-executor / 突合 / 永続化が動いていることと、strategy と live クライアントが未接続であることを書く。「これから作るもの」を strategy・live 取引所クライアント・本番 release・通知アダプタに差し替える。ToDo をアーカイブへ移すときと同様、機能を足したときも README を同じ PR で直す運用にする。
  > 対象ファイル: `README.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| 技術評価層 — apps/bitflyer | -20 |
| 技術評価層 — apps/ui | -5 |
| 技術評価層 — 実行基盤 / 設定 | -6 |
| 横断評価層 | -6 |
| **合計** | **-37** |
