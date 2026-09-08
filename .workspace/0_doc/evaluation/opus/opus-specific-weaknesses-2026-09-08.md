# 第1評価者（Claude Opus 5）— マイナス点詳細 2026-09-08

対象コミット: `e2cd429`（初回評価）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -60 点**

---

## 技術評価層 — apps/bitflyer

### 取引ドメインの中核

- **market-data / strategy / risk-manager / order-executor がいずれも存在しない** `-4`
  > `apps/bitflyer/lib/` 配下は `bitflyer.ex`（生成テンプレ）、`application.ex`、`repo.ex`、`system.ex`、`system/heartbeat.ex` の 5 ファイルのみ。Architecture の論理構成（overview.md L34-L42）に挙がった 4 コンポーネントは 1 行も書かれていない。Vision の「利益より資金保全」を担保する主体が risk-manager である以上、これは Safety first を「文書でしか説明できない」状態を意味する。骨格 ToDo（3_archive/01）の完了条件には含まれていないため計画的な未着手ではあるが、プロジェクトの価値命題そのものが未実装であることは減点として記録する。
  > 改善方針: 次の ToDo を「market-data（WebSocket 購読 + 鮮度スタンプ付き ETS）」「risk-manager（純関数の検査器 + サーキット状態の Ash Resource）」「order-executor（内部注文 ID による冪等送信 + モード分岐）」の 3 本に分け、strategy より先に risk / executor の骨と `dry_run` 経路を通す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

- **起動シーケンス（復元 → 突合 → 不整合なら停止 → Ready）が実装されていない** `-3`
  > `Bitflyer.Application.start/2` は `children = [Bitflyer.Repo]`（application.ex L10-L12）のみで、Architecture が「起動シーケンスは次で固定する」と宣言した 6 ステップ（overview.md L122-L129）のうち実装されているのは「1. 設定と秘密情報を読み込む」だけ。Recoverable 原則の中核である「datastore から復元 → 取引所の事実と突合 → 差分があれば Ready にせず停止」というゲートが存在しないため、現時点では「安全に再開できるか」をコードで説明できない。
  > 改善方針: `Bitflyer.Trading.Supervisor`（Repo の兄弟ではなく後続の子）と `Bitflyer.Startup.Reconciler` を先に置き、突合対象が空でも「Ready フラグを立てるのは Reconciler だけ」という構造を最初から作る。Ready 状態は ETS または `:persistent_term` に置き、UI とヘルスチェックの両方から読む。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **永続化対象が Heartbeat 1 枚で、注文・建玉・残高・リスク状態の正本がない** `-3`
  > Architecture は永続化の最低限として 6 種類（内部注文 ID と取引所注文 ID の対応、未約定・部分約定、ポジションと平均単価、残高スナップショット、リスク状態と停止理由、パラメータ適用履歴 / overview.md L114-L120）を挙げているが、実在する Resource は `Bitflyer.System.Heartbeat`（`note` 文字列 1 個）のみ。マイグレーションも `heartbeats` テーブル 1 本だけである。再起動後に復元すべき状態が存在しないため、Recoverable は現状「検証不能」である。
  > 改善方針: 発注コードより先に `Order` / `Position` / `BalanceSnapshot` / `RiskState` の Resource とマイグレーションを置き、価格・数量は `:decimal` 型で定義する（現時点でリポジトリ全体に `Decimal` / `:decimal` の出現が 0 件であることを確認済み）。特に `Order` の内部注文 ID には一意制約を張り、冪等性を DB レベルで担保する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`, `apps/bitflyer/priv/repo/migrations/`

### 取引モードの扱い

- **`TRADE_MODE` の値検証がなく、未知の文字列が素通りする** `-1`
  > `config/runtime.exs` L43-L44 は `trade_mode: System.get_env("TRADE_MODE") || "dry_run"` と生の文字列をそのまま設定に入れ、`Bitflyer.System.trade_mode/0`（system.ex L31-L33）も `Application.get_env(:bitflyer, :trade_mode, "dry_run")` を無加工で返す。`TRADE_MODE=Live` や `TRADE_MODE=papper` のような打ち間違いが起動時に検出されず、UI にもそのまま表示される。既定値が二重に `dry_run` である点は安全側だが、「モードの正本」を定義するモジュールが無いまま executor を足すと、比較箇所ごとに文字列マッチが散らばる。
  > 改善方針: `Bitflyer.TradeMode` を新設し、`parse/1` で `~w(dry_run paper live)` 以外は起動時に `raise`（または `dry_run` へフォールバックして警告ログ）、内部では atom で扱う。`live` は環境変数だけでなく明示フラグの二重確認を要求する。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/system.ex`

### グレースフルシャットダウン

- **停止時に「新規発注を止めてから書き込みを終える」経路がない** `-1`
  > Architecture は「グレースフルシャットダウンでは、新規発注を止め、進行中の書き込みを終えてから終了する」（overview.md L147）としているが、`Bitflyer.Application` には `stop/1` も `Supervisor` の `shutdown` 指定もなく、compose の `app` も `stop_grace_period` を持たない。現時点では書き込むものが Heartbeat しかないため実害はないが、executor を足す前にこの経路を作らないと、デプロイ（ToDo 03）のたびに未確定注文を残す構造になる。
  > 改善方針: 取引監督ツリーを追加する時点で、最上位に「発注ゲートを閉じる」プロセスを置き、`shutdown: 30_000` と compose の `stop_grace_period` を揃える。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`

---

## 技術評価層 — apps/ui

### 運用可視性

- **「今トレードしてよいか」が画面から判断できない** `-2`
  > `UiWeb.StatusLive` が表示するのはアプリ名・取引モード文字列・PostgreSQL 到達可否の 3 点のみ（status_live.ex L101-L113）。Vision / prod.md が求める「停止理由」「サーキット状態」「市場データ鮮度」「未約定の滞留」は 1 つも無い。さらに取引モードのカード（L70-L74）は `class="mt-1 font-mono text-lg font-medium"` の固定スタイルで、`dry_run` と `live` が視覚的に区別されない。運用画面としての最重要要件が「文字列を出す」で止まっている。
  > 改善方針: 画面最上部に「発注可否」を単一のバッジ（`OK` / `STOPPED: 理由`）として置き、`live` のときだけ赤系のトークンを当てる。値の供給元は risk-manager の状態プロセスとし、UI 側でロジックを持たない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **Phoenix 生成物の残骸が運用 UI に残っている** `-1`
  > `Layouts.app/1` のヘッダは Phoenix のマーケティング用リンク（`Website` L49、`GitHub` L53、`Get Started` L61-L63）と `v{Application.spec(:phoenix, :vsn)}` のままで、稼働状況を見る画面の最上部を占有している。加えて `UiWeb.PageController.home/2`（page_controller.ex L4-L6）と `page_html/home.html.heex` はルータのどこからも参照されておらず（router.ex L18-L26 は locale とルート LiveView のみ）、`Ui.Mailer` と `:swoosh` 依存も自動売買システムでは用途が無い。
  > 改善方針: ヘッダを「アプリ名 / 環境 / モードバッジ / 言語切替」に置き換え、`PageController` / `page_html` / `Mailer` / `:swoosh` / `/dev/mailbox` ルートを削除する。生成物を残すこと自体より、運用画面の一等地が誤解を招く点が問題。
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`, `apps/ui/lib/ui_web/controllers/page_controller.ex`, `apps/ui/lib/ui/mailer.ex`

### 公開面と認証

- **UI に認証がなく、本番での公開面方針がコードにも ToDo にも落ちていない** `-2`
  > ルータの `:browser` パイプラインには認証プラグが無く（router.ex L4-L11）、`live "/"` は誰でも開ける。開発は `compose.yaml` L24 の `127.0.0.1:4000` バインドで守られているが、本番側は `config/runtime.exs` L96-L103 で `ip: {0, 0, 0, 0}`（全インターフェース）になる。prod.md は「管理 UI や DB を不用意に公開しない」（L23）と書くのみで、ToDo 03（CD）にも認証に関する項目が 1 つも無い。VLAN1 の本番PC で稼働させ VLAN3 から監視する構成（vision.md L88-L108）である以上、UI は必ず別セグメントから叩かれる。
  > 改善方針: 最小でも `Plug.BasicAuth` を `:browser` に挟み、資格情報は環境変数から読む。ToDo 03 の手順 3 に「UI の到達元制限と認証」をチェック項目として追加する。停止・再開の操作を UI に足す前に必須。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `config/runtime.exs`, `.workspace/2_todo/03-cd-prod-host.md`

---

## 技術評価層 — 実行基盤 / 設定

### 本番構成

- **本番用の Dockerfile / Compose / release が存在せず、本番は起動できない** `-3`
  > `Dockerfile` は先頭に「開発用。ソースは Compose で bind mount する」と明記され（L1）、`CMD ["mix", "phx.server"]`（L20）で終わる。`compose.prod.yaml` も `mix release` の設定も無い。Vision の「24時間365日」「本番PC 上で常時稼働」は、現時点では実行手段が無い。ToDo 03 に詳細な手順があるのは良いが、`prod.md` が定義する運用（バックアップ、公開面最小化、段階的解禁）を試す土台がゼロである。
  > 改善方針: ToDo 03 手順 2-3 を CI（ToDo 02）より先に着手してもよい。`mix release` は Umbrella ルートで `releases: [docker_bitflyer: [applications: [bitflyer: :permanent, ui: :permanent]]]` を定義すれば 1 リリースで足りる。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **テスト環境が開発用データベースを共有している** `-2`
  > `config/runtime.exs` は全環境で `DATABASE_URL` を必須にし（L10-L15）、`:test` では `pool: Ecto.Adapters.SQL.Sandbox` を足すだけでデータベース名を変えない（L26-L39）。実測で確認したところ、`MIX_ENV=test` 実行時の `Bitflyer.Repo.config()[:database]` は `docker_bitflyer_dev` を返し、`db` コンテナ内にも `docker_bitflyer_dev` しか存在しなかった。Sandbox がロールバックするため現状の 7 テストでは実害が出ていないが、Sandbox を経由しないテスト（`mix ash.setup` / `ecto.reset` / 別プロセスからの書き込み）が 1 つ入った瞬間に開発データを壊す。CI で PostgreSQL サービスを立てる（ToDo 02 手順 3）際も、この設計のままだと接続文字列の分離を CI 側で場当たり的に行うことになる。
  > 改善方針: `runtime.exs` の `:test` 分岐で `TEST_DATABASE_URL` を優先し、未設定なら `DATABASE_URL` のデータベース名に `_test#{System.get_env("MIX_TEST_PARTITION")}` を付与する。`.env.example` にも名前を追記する。
  > 対象ファイル: `config/runtime.exs`, `.env.example`

- **`app` のヘルスチェックがトップページの 200 だけを見ており、DB 断でも healthy になる** `-2`
  > `compose.yaml` L49-L54 の `test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/ >/dev/null"]` が叩く `/` は `StatusLive` で、DB 到達に失敗しても `check_database/0` が `{:error, message}` を返して赤いバッジ付きの HTML を 200 で返す（status_live.ex L102-L106）。つまり PostgreSQL が落ちてもコンテナは healthy のままで、`restart: unless-stopped`（L28）による自動回復も、依存サービスの障害検知も働かない。Architecture が求める「プロセス生存だけでなくデータ鮮度と取引所との同期を見る」（overview.md L144）とは逆方向で、現状は DB 生存すら見ていない。
  > 改善方針: 認証不要の `GET /health` を専用コントローラで足し、`Bitflyer.System.check_database/0` と（将来の）鮮度・突合ステータスを見て 200/503 を出し分ける。`compose.yaml` のヘルスチェックと `prod.exs` の `force_ssl` 除外パスを同じ `/health` に揃える。
  > 対象ファイル: `compose.yaml`, `apps/ui/lib/ui_web/live/status_live.ex`

- **`.dockerignore` が無い** `-1`
  > リポジトリルートに `.dockerignore` が存在しないため、`docker compose build` のコンテキストに `_build/`、`deps/`、`.git/`、そしてローカルの `.env` がそのまま送られる。現在の Dockerfile は `COPY` をしないのでイメージには焼かれないが、ビルドのたびに数百 MB を転送することになり、将来 `Dockerfile.prod` で `COPY . .` を書いた瞬間に秘密情報混入の事故になる。
  > 改善方針: 本番 Dockerfile を書く前に `.dockerignore`（`_build`, `deps`, `.git`, `.env*`, `.workspace`, `apps/*/priv/static/assets`）を置く。
  > 対象ファイル: リポジトリルート（`.dockerignore` 不在）

- **開発コンテナが root で実行される** `-1`
  > `Dockerfile` に `USER` 指定が無いため、bind mount した `/app` 配下に root 所有のファイル（`_build` や生成物）が作られる。開発用途としては許容範囲だが、同じベースから本番イメージを派生させる際に非 root 化を忘れやすい。
  > 改善方針: 開発イメージでも `useradd` した非 root ユーザーへ切り替え、`mix_deps` / `mix_build` ボリュームの所有者を合わせる。
  > 対象ファイル: `Dockerfile`

---

## 技術評価層 — CI / CD

### 自動化の不在

- **`.github/workflows/` が存在せず、自動品質ゲートがゼロ** `-3`
  > リポジトリに `.github` ディレクトリ自体が無い（`git ls-files` で確認）。`main` へのマージ経路は既に PR ベース（`git log` に Merge pull request #1〜#7）で運用されているのに、その PR に対して format / compile / test を自動実行する仕組みが無い。ToDo 02 に詳細な計画があることは評価するが、「壊れたコードをマージしない」保証は現時点で人の目だけに依存している。
  > 改善方針: ToDo 02 手順 3-4 をそのまま実行する。Elixir 1.18 / OTP 27 を `setup-beam` でピンし、`services: postgres:16-alpine` を立て、後述のルート `precommit` 1 本を呼ぶ形にすれば実装量は小さい。
  > 対象ファイル: リポジトリルート（`.github/workflows/` 不在）

### ローカルゲートの実効性

- **ルート `mix.exs` に `precommit` が無く、`mix precommit` が `apps/bitflyer` を素通りする** `-3`
  > ルートの `aliases/0` は `setup` のみ（mix.exs L24-L29）で、`precommit` は `apps/ui/mix.exs` L98 にしか存在しない。Umbrella のタスク再帰により実行自体は通るが、alias を持たない `apps/bitflyer` では何も走らない。実測では `docker compose run --rm -e MIX_ENV=test app mix precommit` が **6 tests**（ui のみ）で緑になるのに対し、`mix test` は **1 doctest, 1 test + 6 tests = 7 tests**（両アプリ）を実行した。つまり AGENTS.md と ToDo 02 が「ローカルと CI の同じ品質ゲート」と位置付けている `mix precommit` は、取引ロジックの正本である `apps/bitflyer` を検査しない。今は差が 1 テストだが、engine の実装が始まった瞬間に「緑なのに壊れている」を生む。
  > 改善方針: ルート `mix.exs` に `precommit: ["deps.unlock --check-unused", "format --check-formatted", "compile --warnings-as-errors", "test"]` を定義し、`def cli, do: [preferred_envs: [precommit: :test]]` を併記する。`apps/ui` 側の重複 alias は削除する。
  > 対象ファイル: `mix.exs`, `apps/ui/mix.exs`

- **`precommit` が `format`（書き換え）を使っており、ゲートとして機能しない** `-2`
  > `apps/ui/mix.exs` L98 は `precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]`。`format` はファイルを書き換えるだけで、未整形でも失敗しない。`deps.unlock --unused` も `mix.lock` を書き換える副作用があり、`--check-unused` ではない。CI に載せた場合、整形漏れと不要ロックを検出できず、しかもワークスペースを汚す。加えて実行順が「compile が先、format が後」なので、整形前のコードでコンパイル警告を判定している。
  > 改善方針: `format --check-formatted` と `deps.unlock --check-unused` に置き換え、順序を「deps 検査 → format 検査 → compile → test」にする。整形は開発者が `mix format` を明示的に叩く。
  > 対象ファイル: `apps/ui/mix.exs`

- **Compose の既定 `MIX_ENV=dev` により、文書どおりのコンテナ実行で `precommit` が失敗する** `-2`
  > `compose.yaml` L38 が `MIX_ENV: ${MIX_ENV:-dev}` を注入するため、`apps/ui/mix.exs` L32-L36 の `preferred_envs: [precommit: :test]` が上書きされる。実測で `docker compose run --rm app mix precommit` を実行すると、`elixirc_paths(:test)` が効かず `UiWeb.ConnCase` が見つからず `** (CompileError) test/ui_web/controllers/error_html_test.exs: cannot compile module UiWeb.ErrorHTMLTest` で終了した（exit 1）。`-e MIX_ENV=test` を明示すると成功する。評価ルールが「Docker 経由が正なら `docker compose run --rm app mix precommit` で確認する」としている前提が、そのままでは成立しない。
  > 改善方針: `compose.yaml` から `MIX_ENV` の固定注入を外す（`mix phx.server` は既定で dev）か、テスト用の `app-test` サービス／`profiles` を分ける。あわせて README に「コンテナでゲートを回すコマンド」を実際に通る形で書く。
  > 対象ファイル: `compose.yaml`, `apps/ui/mix.exs`

---

## 横断評価層

### テスト戦略

- **発注経路・冪等性・モード分岐の回帰テストが 1 件も無い** `-3`
  > 全 7 テストの内訳は `BitflyerTest`（`hello/0` と doctest）、`UiWeb.ErrorHTMLTest`、`UiWeb.ErrorJSONTest`、`UiWeb.StatusLiveTest`（2 件）。paper-trade-adapter.md が「paper 中に発注 REST が呼ばれないことをテストで固定できる」（L52）を完了条件に挙げているが、その土台となるテストヘルパ（外部 HTTP のスタブ、`TRADE_MODE` を切り替えるケース、内部注文 ID の重複送信ケース）は一切用意されていない。テストピラミッドの設計意図がまだコードに現れていない。
  > 改善方針: executor を書く前に「`Bitflyer.Exchange.Client` ビヘイビア + テスト用実装」を先に決め、`Mox` 等で `paper` / `live` の出口を差し替えられる形にする。冪等キーは `StreamData` によるプロパティテストの対象にする。
  > 対象ファイル: `apps/bitflyer/test/`, `apps/ui/test/`

- **Sandbox のモード設定が無く、DB 検証が実質ノーオペになっている** `-2`
  > `apps/ui/test/test_helper.exs` も `apps/bitflyer/test/test_helper.exs` も中身は `ExUnit.start()` の 1 行だけで、Phoenix 生成物にある `Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)` が呼ばれていない。`UiWeb.ConnCase` は `start_owner!(Bitflyer.Repo, shared: not tags[:async])`（conn_case.ex L35）を実行するが、`StatusLiveTest` は `async: true` で走るため LiveView プロセスからの接続所有権が保証されない。実際 `StatusLiveTest` は `has_element?(view, "#db-status-label")`（status_live_test.exs L12）としか書いておらず、DB が繋がっていても切れていても緑になる。「DB 接続可否を出す画面」のテストが接続可否を検証していない。
  > 改善方針: 両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Bitflyer.Repo, :manual)` を追加し、`StatusLiveTest` は `#db-status-label` のテキストが `connected` であることまでアサートする。あわせて DB 断のケースを別テストで固定する。
  > 対象ファイル: `apps/ui/test/test_helper.exs`, `apps/bitflyer/test/test_helper.exs`, `apps/ui/test/ui_web/live/status_live_test.exs`

- **`apps/bitflyer` のテストが生成テンプレのまま** `-1`
  > `apps/bitflyer/test/bitflyer_test.exs` は `assert Bitflyer.hello() == :world`（L5-L7）のみ。ドメインの正本アプリに対する検証が実質ゼロで、`Bitflyer.System.check_database/0` や `trade_mode/0` のような既に書かれている関数にもテストが無い。
  > 改善方針: `Bitflyer.SystemTest` を追加し、`trade_mode/0` の既定値が `dry_run` であること、`check_database/0` が Repo 停止時に `{:error, _}` を返すことを固定する。既定が `dry_run` であることは回帰テストで守るべき性質。
  > 対象ファイル: `apps/bitflyer/test/bitflyer_test.exs`

### 可観測性・デバッグ容易性

- **`apps/bitflyer` に telemetry イベントも構造化ログも無い** `-2`
  > `:telemetry` の `execute` 呼び出しはリポジトリ全体で 0 件、`Logger` の使用も `apps/bitflyer` 内で 0 件。`UiWeb.Telemetry`（telemetry.ex L22-L61）は Phoenix と VM の標準メトリクスのみで、取引に関わるイベント（切断、拒否、サーキット、突合結果）の語彙が定義されていない。`config/config.exs` L63-L65 の Logger メタデータも `[:request_id]` だけで、`trade_mode` や内部注文 ID をクラッシュ時に残す設計になっていない。tech-stack.md 自身が「Telemetry + 構造化ログ」を『今』足すものに分類している（L59）のに、着手されていない。
  > 改善方針: エンジン実装より先に `Bitflyer.Telemetry` にイベント名の一覧（`[:bitflyer, :order, :submitted]` 等）を定数として定義し、`Logger.metadata(trade_mode: ..., internal_order_id: ...)` を発注経路の入口で必ず設定する規約を置く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/ui/lib/ui_web/telemetry.ex`, `config/config.exs`

- **人に届くアラート経路が無い** `-1`
  > Vision は「異常時は人に届く。届かない監視は監視ではない」（prod.md L12）とし、discord-notify-adapter.md で方針まで確定しているが、通知コードは存在しない。現状の唯一の観測手段はコンテナ標準出力で、本番PC が VLAN1 で無人稼働する想定（vision.md L46-L48）と噛み合わない。監視対象となる取引イベントがまだ無いため減点は軽くするが、「コンテナ起動 / 停止」だけでも先に送れる。
  > 改善方針: backlog どおり `apps/bitflyer` 内のアダプタとして実装し、`Application.start/2` と `stop/1` の通知から始める。Webhook 未設定でも落ちないこと（backlog L36）をテストで固定する。
  > 対象ファイル: `.workspace/1_backlog/discord-notify-adapter.md`

### エラーハンドリング・安全側フォールバック

- **「不整合なら Ready にしない」というゲートがコード上に存在しない** `-2`
  > prod.md L37-L38 の「差分があれば Ready にせず、発注を禁止したままアラートする」は、実装上どこにも表現されていない。現在「Ready」に相当する概念は Docker のヘルスチェック（前述のとおり `/` の 200）しか無く、これはアプリの内部状態を一切見ていない。安全側フォールバックの設計は文書だけに存在する。
  > 改善方針: `Bitflyer.System.Readiness`（`:not_ready` / `:ready` / `{:halted, reason}`）を最初に置き、UI・ヘルスチェック・（将来の）executor の 3 箇所が同じ 1 つの状態を読む形にする。executor は `:ready` 以外では必ず拒否する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

### 変更容易性・保守性

- **生成テンプレの記述が正本モジュール・README に残っている** `-1`
  > `Bitflyer` モジュールは `@moduledoc "Documentation for \`Bitflyer\`."` と `def hello, do: :world`（bitflyer.ex L15-L17）のまま。`apps/bitflyer/README.md` は `**TODO: Add description**` と Hex 公開手順、`apps/ui/README.md` は Phoenix のデフォルト案内で、Umbrella の境界（誰が Repo を持つか）を説明していない。ルート文書の質が高いだけに、アプリ直下の README が案内として機能していないのは惜しい。
  > 改善方針: `Bitflyer` を `@moduledoc` のみのエントリポイント（または削除）にし、各 `README.md` に「このアプリの責務と、触ってよい境界」を数行で書く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer.ex`, `apps/bitflyer/README.md`, `apps/ui/README.md`

### 開発者体験（DX）

- **README の「現状」が実装と乖離し、リンクが切れている** `-2`
  > README L11 は「開発用 Docker（`app` / `db`）まで置いた段階。Umbrella 本体は [ToDo 手順 4 以降](.workspace/2_todo/01-bootstrap-umbrella-and-docker.md)」と書くが、そのファイルは既に `.workspace/3_archive/` へ移動済みでリンクが 404 になる。実際には Umbrella も Phoenix も Ash も動いており、L13「Phoenix の常時起動手順は、骨格（手順 6）が通ってからここに移す」、L42「Umbrella 生成後の `mix` は手順 4 以降で追記する」、L57 の目次も同じファイルを指している。新規参加者が README を信じると「まだ何も動かない」と誤解する。同じリンク切れが `.workspace/1_backlog/discord-notify-adapter.md` L3 にもある。
  > 改善方針: README の「現状」「開発起動」「よく使う mix」を実測どおりに書き直し（`docker compose up -d` で UI が `127.0.0.1:4000` に出る、ゲートは `docker compose run --rm -e MIX_ENV=test app mix precommit`）、目次のリンクを `3_archive/` と `2_todo/02` へ差し替える。
  > 対象ファイル: `README.md`, `.workspace/1_backlog/discord-notify-adapter.md`

### 取引完成度（運用として回るか）

- **起動 → 購読 → 判定 → リスク → 発注 → 突合 → 停止/再開 の全経路が 0%** `-4`
  > 現在通っている経路は「起動 → Repo 接続 → UI が DB に `SELECT 1` を投げる」だけである。bitFlyer API へのクライアント（REST / WebSocket）が存在せず、`:req` 依存も `apps/ui` 側にしか入っていない（apps/ui/mix.exs L72、`apps/bitflyer/mix.exs` の deps は `:ash` と `:ash_postgres` の 2 つのみ）。Vision の「人が張り付かなくても資金を守れる」度合いは、現時点では測定対象が存在しない。ドメイン未実装（-4）と重複する側面はあるが、こちらは「運用として回るか」という横断視点での評価として別途計上する。
  > 改善方針: 最初のマイルストーンを「`TRADE_MODE=dry_run` で、Ticker を購読し、固定シグナルを risk で弾き、意図をログと DB に残す」に置き、経路を細くても端から端まで通す。幅（戦略の質）より先に縦の貫通を作る。
  > 対象ファイル: `apps/bitflyer/`

- **モード切替が表示専用で、`paper` / `live` の出口が存在しない** `-2`
  > `TRADE_MODE` は `runtime.exs` L43-L44 で読まれ、`StatusLive` L110 で表示されるだけ。Architecture の取引モード表（overview.md L102-L107）が定める「約定 / 建玉・残高 / 市場データ」の差分を実装している箇所は無い。したがって「`live` 解禁が明示的か」「ペーパーで本番と同経路を検証できているか」は現状 No である。
  > 改善方針: paper-trade-adapter.md の方針どおり、executor の出口だけを差し替えるアダプタを 3 つ（`DryRun` / `Paper` / `Live`）用意し、`Live` の生成には設定の二重確認を要求する。
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/live/status_live.ex`

### セキュリティ・秘密情報・権限

- **bitFlyer API キーの環境変数名と注入方法が未定義** `-1`
  > `.env.example` に定義されているのは `DATABASE_URL` / `SECRET_KEY_BASE` / `PHX_HOST` / `TRADE_MODE` / `POSTGRES_*` のみで、取引所キーの名前が無い。`dev.md` L43-L48 の環境変数表にも無い。「名前は固定して値は Git に入れない」という方針を採っている以上、名前の側は先に決めておく方が事故が減る（後から各所で `BITFLYER_KEY` / `BF_API_KEY` 等が乱立する）。
  > 改善方針: `.env.example` に `BITFLYER_API_KEY=` / `BITFLYER_API_SECRET=`（値は空）を追加し、`dev.md` / `prod.md` の表にも載せる。`runtime.exs` では `live` モードのときだけ必須にする。
  > 対象ファイル: `.env.example`, `.workspace/0_doc/architecture/env/dev.md`

- **依存の脆弱性管理が無い** `-1`
  > `mix_audit` / `sobelow` / `deps.audit` 相当が導入されておらず、`heroicons` と `daisyui` は GitHub からタグ指定で取得している（apps/ui/mix.exs L57-L70）。実資金を扱うプロセスとして、依存の既知脆弱性を機械的に見る手段が無い。
  > 改善方針: CI（ToDo 02）に `mix_audit` を 1 ステップ足す。落とすかどうかは後で決めてよいが、まず可視化する。
  > 対象ファイル: `apps/ui/mix.exs`, `mix.exs`

### プロジェクト全体設計

- **文書間のリンク切れ** `-1`
  > 前述の README と discord backlog に加え、`.workspace/1_backlog/elixir-umbrella-phoenix-ash.md` L3 は `../3_archive/01-...` を正しく指しており、参照先の管理が統一されていない。ToDo をアーカイブへ移す運用は良いが、被参照側の更新が漏れている。
  > 改善方針: ToDo をアーカイブへ移す手順（各 ToDo の最終節）に「このファイルを参照している文書のリンクを直す」を明記する。
  > 対象ファイル: `README.md`, `.workspace/1_backlog/discord-notify-adapter.md`

- **完了済みの要望が `1_backlog/` に残っている** `-1`
  > `.workspace/1_backlog/elixir-umbrella-phoenix-ash.md` は L3 で「ステータス: 完了」と宣言しながら backlog ディレクトリに置かれたままで、`3_backlog / 2_todo / 3_archive` というステージ分けの意味が薄れている。ディレクトリ構造自体が進捗の一次情報になっている運用なので、ここがずれると自己改善サイクルの信頼性が下がる。
  > 改善方針: 完了した要望は `3_archive/` へ移すか、`1_backlog/` の定義を「要望の常設カタログ（ステータス付き）」に改め、その旨を `.workspace` のルールとして 1 箇所に書く。
  > 対象ファイル: `.workspace/1_backlog/elixir-umbrella-phoenix-ash.md`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| 技術評価層 — apps/bitflyer | -12 |
| 技術評価層 — apps/ui | -5 |
| 技術評価層 — 実行基盤 / 設定 | -9 |
| 技術評価層 — CI / CD | -10 |
| 横断評価層 | -24 |
| **合計** | **-60** |
