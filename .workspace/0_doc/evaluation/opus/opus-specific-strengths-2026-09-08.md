# 第1評価者（Claude Opus 5）— プラス点詳細 2026-09-08

対象コミット: `e2cd429`（初回評価）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**合計: +61 点**

---

## 技術評価層 — apps/bitflyer

### 永続層の置き方

- **Ash を永続状態に限定し、Domain / Resource を最小 1 枚に絞った** `+2`
  > `Bitflyer.System` の `@moduledoc` は「開発・稼働確認用の Domain。取引エンティティは置かない。」と明記され（system.ex L2-L4）、Resource は `Heartbeat` 1 枚のみ（system.ex L8-L10）。tech-stack.md L33-L39 が「Ash は永続層のみ。ホットパスに載せると遅延とロックと学習コストが先に来る」と結論した内容を、そのまま骨格に反映している。「まだ書かないもの」を意図して書かなかった判断は、骨格フェーズでは実装するのと同じくらい重要。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **`Bitflyer.Repo` が `apps/bitflyer` に閉じ、依存方向が Umbrella で強制されている** `+2`
  > `Bitflyer.Repo`（`AshPostgres.Repo`）は `apps/bitflyer` にのみ定義され、`config/config.exs` L4-L6 でも `config :bitflyer, ecto_repos: [Bitflyer.Repo], ash_domains: [Bitflyer.System]` と `:bitflyer` 側に置かれている。`apps/ui/mix.exs` L47 の `{:bitflyer, in_umbrella: true}` は一方向で、逆向きの依存は Mix が拒否する。Phoenix 生成時に付いてくる `Ui.Repo` を残さず AshPostgres へ寄せた点も、overview.md L80 の宣言どおり。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/repo.ex`, `config/config.exs`, `apps/ui/mix.exs`

### 防御的な実装

- **`check_database/0` が例外と exit の両方を潰し、DB 未起動でもプロセスを巻き込まない** `+2`
  > `Ecto.Adapters.SQL.query/4` を `timeout: 2_000` で呼び、`rescue` で例外を、`catch :exit` で「Repo が起動していない」ケースを拾って `{:error, message}` に正規化している（system.ex L15-L26）。Ecto の Repo 未起動は例外ではなく `exit` で飛ぶため、`rescue` だけでは取りこぼす。ここを両方書いてあるのは、DB 断でも UI が落ちないことを意図した設計。実際 `git log` の `7f9459d fix: Status の DB チェック堅牢化` でレビューを経て入っており、安全側フォールバックへの姿勢が読み取れる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **`min_pg_version` と `installed_extensions` を明示し、UUIDv7 を主キーに採用した** `+1`
  > `Repo` で `installed_extensions` に `["ash-functions"]`、`min_pg_version` に `16.0.0` を明示（repo.ex L5-L13）し、`compose.yaml` L4 の `postgres:16-alpine` と一致させている。Resource 側は `uuid_v7_primary_key :id`（heartbeat.ex L20）で、マイグレーションも `default: fragment("uuid_generate_v7()")`（20260904092539 L12）として DB 側に落ちている。時系列で単調増加する主キーは、後から注文・約定テーブルを載せる際にインデックス効率で効いてくる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`

---

## 技術評価層 — apps/ui

### 責務の限定

- **運用 UI に責務を限定し、Vision の非目標へ踏み込んでいない** `+2`
  > `UiWeb.StatusLive` の `@moduledoc` は「稼働確認ページ。アプリ名・取引モード・DB 接続可否を表示する。」（status_live.ex L2-L4）で、画面本文にも `gettext("Operational health check. This is not a trading UI.")`（L34）と明示している。ルータの公開面は `live "/"` と `get "/locale/:locale"` の 2 本のみ（router.ex L18-L26）。「裁量トレード用の高機能 UI は作らない」（vision.md L26）を、コメントではなく画面の文言とルート数で表現しているのは良い。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/router.ex`

- **UI が `bitflyer` の公開関数経由でのみデータに触り、取引所 API を直接叩いていない** `+2`
  > `assign_status/1` は `Bitflyer.System.check_database()` と `Bitflyer.System.trade_mode()` の 2 関数だけを呼び（status_live.ex L101-L113）、`Bitflyer.Repo` や `Ecto` を直接参照していない。`apps/ui` 全体でも bitFlyer のエンドポイントに触れるコードは無い。overview.md L81-L82 の「`ui` は Ash の公開インターフェース経由でのみデータに触る / `ui` から bitFlyer API を直接叩かない」が、骨格の段階から守られている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

### 公開面の抑制

- **LiveDashboard と Swoosh mailbox を `dev_routes` に閉じ込めている** `+2`
  > `router.ex` L34 の `if Application.compile_env(:ui, :dev_routes) do` でガードし、`config/dev.exs` L47 のみが `dev_routes: true` を設定している。`prod.exs` / `test.exs` には無いため、本番ビルドではルート自体がコンパイルされない。無認証の LiveDashboard を本番に晒す事故は Phoenix プロジェクトで頻出するので、`compile_env` によるコンパイル時排除は正しい。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `config/dev.exs`

### テスト可能性と国際化

- **主要要素に DOM ID を付与し、i18n を含めてテストで固定している** `+2`
  > `#status-page` `#app-name` `#trade-mode` `#db-status` `#db-status-label` `#db-error` `#locale-switcher` と、状態を持つ要素すべてに ID が振られている（status_live.ex L26-L94）。`StatusLiveTest` はこれを `has_element?/2` で参照し（status_live_test.exs L11-L16）、生 HTML への文字列マッチを避けている。さらに en/ja のロケール切替を session 経由で行い、Plug（`UiWeb.Plugs.Locale`）と LiveView フック（`UiWeb.Hooks.Locale`）の両方で `validate_locale/1` を通す実装は、HTTP と WebSocket でロケール判定がずれる典型的バグを構造的に防いでいる。日本語ロケールでの表示までテストしている点（status_live_test.exs L19-L28）も良い。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui_web/plugs/locale.ex`, `apps/ui/lib/ui_web/hooks/locale.ex`, `apps/ui/test/ui_web/live/status_live_test.exs`

- **DB 状態を定期更新し、失敗理由を画面に残している** `+1`
  > `connected?(socket)` のときだけ `Process.send_after(self(), :refresh, 5_000)` を回し（status_live.ex L10-L11, L115-L117）、静的レンダリング時に無駄なタイマーを張らない。エラー時は `<p :if={@db_error} id="db-error" ...>` で理由本文まで出す（L93）。「盲目運転は禁止する」（overview.md L43）の最初の一歩として妥当。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

---

## 技術評価層 — 実行基盤 / 設定

### 開発 Compose の作り込み

- **`db` の healthcheck と `depends_on: service_healthy`、ビルド成果物のボリューム分離** `+3`
  > `db` に `pg_isready -U postgres -d docker_bitflyer_dev` の healthcheck を置き（compose.yaml L13-L17）、`app` は `depends_on: db: condition: service_healthy`（L46-L48）で待つ。さらに `.:/app` の bind mount に対して `mix_deps:/app/deps` と `mix_build:/app/_build` を名前付きボリュームで被せている（L29-L32）。これは Windows / macOS のバインドマウント上で Mix のコンパイルが極端に遅くなる問題への正しい対処で、tech-stack.md L64 が挙げた懸念に先回りしている。公開ポートも `127.0.0.1:5432` / `127.0.0.1:4000` とループバック限定（L6, L24）で、dev.md L19-L20 の記述と一致する。個人プロジェクトの `compose.yaml` としては明確に平均を上回る。
  > 対象ファイル: `compose.yaml`

- **エントリポイントが常駐起動のときだけセットアップを走らせる** `+2`
  > `bin/docker-entrypoint.sh` は `case "${1:-}" in mix)` で第 2 引数が `phx.server` のときだけ `run_setup`（`wait_for_db` → `mix deps.get` → `mix ash.setup`）を実行し、それ以外は素通しで `exec "$@"` する（L34-L42）。この分岐があるおかげで `docker compose run --rm app mix precommit` のような単発コマンドがマイグレーションを走らせない。`wait_for_db` も 60 回 1 秒のループで、タイムアウト時に非ゼロで落ちる（L13-L26）。「起動時に何をして、何をしないか」を意識的に切り分けている。
  > 対象ファイル: `bin/docker-entrypoint.sh`

- **`.gitattributes` で `bin/*` を LF 固定し、Windows ホスト固有の起動失敗を潰している** `+2`
  > `*.sh text eol=lf` と `bin/* text eol=lf` を、失敗時のエラーメッセージ（`set: Illegal option -`）付きのコメントとともに置いている（.gitattributes L1-L3）。`git log` の `0a36ae3 fix: Windows でも entrypoint が動くようシェルを LF 固定にする` から、実際に踏んだ問題を再発防止としてリポジトリに固定したことが分かる。Vision が本番PC・作業用PC ともに Windows + WSL2 を前提にしている（vision.md L119, L132, L143）以上、この 3 行の価値は大きい。
  > 対象ファイル: `.gitattributes`

- **ベースイメージと依存のバージョンをピンしている** `+1`
  > `FROM elixir:1.18.3-otp-27-slim`（Dockerfile L2）、`postgres:16-alpine`（compose.yaml L4）、`esbuild 0.25.4` / `tailwind 4.3.0`（config.exs L42, L52）、`mix.lock` は追跡対象。`latest` に依存していないため、再起動やイメージ再取得でランタイムが変わらない。24/365 稼働を狙う構成としては前提条件。
  > 対象ファイル: `Dockerfile`, `compose.yaml`, `config/config.exs`

### 秘密情報の分離

- **`.gitignore` が秘密情報を面で押さえ、`.env.example` だけを例外にしている** `+2`
  > `.env` / `.env.*` を無視して `!.env.example` で 1 枚だけ戻し（.gitignore L30-L33）、さらに `*.pem` / `*.key`（`!*.public.key`）/ `secrets/` / `credentials.json`（L36-L40）、DB の永続ディレクトリ（L43-L46）まで除外している。`.env.example` 自身も冒頭 3 行で「値はローカルの `.env` に置く / Git に実キーや本番接続先を書かない / `cp .env.example .env`」と用途を明記。Dockerfile が `COPY` を一切せずソースを bind mount に寄せている（Dockerfile L1 のコメント）ため、イメージにも秘密が焼かれない。Vision の「API キーなどの秘密情報はリポジトリに置かず、環境ごとに分離する」（L19）を、方針ではなく仕組みで担保している。
  > 対象ファイル: `.gitignore`, `.env.example`, `Dockerfile`

### 安全な既定値

- **`TRADE_MODE` の既定が 2 段構えで `dry_run` になっている** `+2`
  > `config/runtime.exs` L43-L44 の `System.get_env("TRADE_MODE") || "dry_run"` に加え、読み出し側の `Bitflyer.System.trade_mode/0` も `Application.get_env(:bitflyer, :trade_mode, "dry_run")`（system.ex L31-L33）と既定を持つ。`compose.yaml` L37 の `TRADE_MODE: ${TRADE_MODE:-dry_run}` と `.env.example` L9 も同じ既定で、どの層が抜けても `live` に倒れない。「設定を忘れたときに危険側へ倒れない」ことは、資金を扱うシステムの基本設計であり、4 箇所すべてで揃えているのは意図的。`.env.example` L8 に 3 モードの意味をコメントで書いている点も良い。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/system.ex`, `compose.yaml`, `.env.example`

---

## 技術評価層 — CI / CD

### 計画の質

- **CI / CD の ToDo が「載せるもの・載せないもの・完了の見方」まで具体化されている** `+2`
  > `02-ci-github-actions.md` は手順 1-6 に分割され、各手順に完了条件が付き、「保証しない範囲を明示する: 本番イメージの配布、本番PC へのデプロイ、実発注の検証」（L23）、「Credo / Dialyzer は後続で足してよい。最初の完了条件には入れない」（L86）とスコープを絞っている。`03-cd-prod-host.md` はさらに踏み込み、「`main` へのマージだけでは実弾を動かさない。明示タグまたは手動承認を必須にする」（L26）、「デプロイ前: 新規発注を止める」（L72）、「watchtower 等の自動最新追従は、発注停止ゲートなしでは採用しない」（L106）と、CD で最も事故が起きる箇所を先に禁止として書いている。実装はまだ無いが、ここまで書かれた CD 方針を持つ個人プロジェクトは多くない。
  > 対象ファイル: `.workspace/2_todo/02-ci-github-actions.md`, `.workspace/2_todo/03-cd-prod-host.md`

---

## 横断評価層

### テスト戦略

- **LiveView テストが実装詳細ではなく振る舞いに向いている** `+2`
  > `StatusLiveTest` は生 HTML の比較を避け、`has_element?(view, "#app-name", "docker_bitflyer")` のように ID とテキストの組で確認している（status_live_test.exs L11-L16）。ロケール切替のテストは `get(conn, ~p"/locale/ja")` → `redirected_to/1` の検証 → `live(recycle(conn), ~p"/")` と、HTTP と LiveView をまたぐ状態遷移を正しく再現している（L19-L28）。`async: true` で走らせる前提も含め、テストの書き方の作法自体は良い。
  > 対象ファイル: `apps/ui/test/ui_web/live/status_live_test.exs`

### 可観測性・デバッグ容易性

- **Phoenix / VM の telemetry と LiveDashboard が最初から入っている** `+1`
  > `UiWeb.Telemetry` に Phoenix のエンドポイント・ルータ・ソケット・チャネルと VM メモリ / run queue のメトリクスが定義され（telemetry.ex L22-L61）、`telemetry_poller` が 10 秒周期で回る（L14）。`/dev/dashboard` から即座に見られる。取引固有のイベントはまだ無いが、計測の受け皿は用意されている。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`

### エラーハンドリング・安全側フォールバック

- **`{:ok, _}` / `{:error, _}` の境界が一貫している** `+2`
  > `Bitflyer.System.check_database/0` は成功で `:ok`、失敗で `{:error, message}`（文字列に正規化済み）を返し、呼び出し側の `assign_status/1` はそれを `case` で受けて `{db_ok?, db_error}` に落とす（status_live.ex L102-L106）。例外を境界の外へ漏らさず、UI 側に「例外処理」を書かせていない。エラー境界の置き方として素直で、後から `Readiness` のような状態を足すときも同じ形が使える。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

- **UI の Endpoint と取引側が別 Application・別 Supervisor になっている** `+2`
  > `UiWeb.Endpoint` は `Ui.Supervisor` の下（ui/application.ex L10-L23）、`Bitflyer.Repo` は `Bitflyer.Supervisor` の下（bitflyer/application.ex L10-L17）と、監督ツリーが完全に分かれている。Umbrella の 2 アプリ構成により、`Ui` 側の再起動が `Bitflyer` 側を巻き込まない。overview.md L83 と tech-stack.md L43-L45 が繰り返し要求した「Endpoint と取引監督は兄弟」を、骨格の時点で満たしている。将来 `Bitflyer.Trading.Supervisor` を足す位置も自明。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/ui/lib/ui/application.ex`

### 変更容易性・保守性

- **`ui` → `bitflyer` の一方向依存を Umbrella で機械的に強制している** `+3`
  > 単一 Phoenix アプリ + context でも同じ機能は書けるが、その場合「UI から取引所クライアントを直接呼ばない」は規律でしか守れない。ここでは `apps/ui/mix.exs` L47 の `{:bitflyer, in_umbrella: true}` により、逆向きの参照はコンパイルエラーになる。tech-stack.md L52 が「Umbrella を選ぶなら、恩恵は『ui が API を直接叩けない』ことを依存関係で強制できる点に置く」と述べた根拠を、そのまま構造で実現している。境界を「守る」ではなく「破れなくする」選択。
  > 対象ファイル: `apps/ui/mix.exs`, `mix.exs`

- **第3アプリを作らない方針を、実装前に backlog で確定させている** `+3`
  > `paper-trade-adapter.md` は「`apps/paper` は作らない。ペーパーは取引所ではなく、order-executor の出口である」（L11）とし、`discord-notify-adapter.md` は「`apps/discord` は作らない。Discord は取引の正本ではなく、通知の出力先である」（L10）とする。さらに前者は「strategy と risk-manager はどのモードでも同じ経路を通り、切り替えるのは order-executor の出口だけ。同じ経路を通さないペーパーは、本番で初めて壊れる」（overview.md L98）と理由まで書いている。ペーパー取引を別サービスに切り出して本番と経路が乖離するのは実務でよくある失敗で、それをコードを書く前に禁止事項として固定したのは、設計判断として質が高い。
  > 対象ファイル: `.workspace/1_backlog/paper-trade-adapter.md`, `.workspace/1_backlog/discord-notify-adapter.md`, `.workspace/0_doc/architecture/overview.md`

### 開発者体験（DX）

- **クローンから起動までが 3 コマンドで、コンテナ内で完結する** `+2`
  > README L18-L20 の `cp .env.example .env` → `docker compose up -d db` → `docker compose run --rm app mix --version` で始まり、実際には `docker compose up -d` だけで DB 待ち・`deps.get`・`ash.setup`・`phx.server` までエントリポイントが面倒を見る。ホストに Elixir を入れる必要が無い（3_archive/01 の前提 L14）。実測でも `db` コンテナが healthy な状態から `docker compose run --rm -e MIX_ENV=test app mix test` が 5 秒未満で 7 テスト緑になった。
  > 対象ファイル: `README.md`, `compose.yaml`, `bin/docker-entrypoint.sh`

### セキュリティ・秘密情報・権限

- **秘密情報を Git・イメージから外す方針が仕組みとして成立している** `+3`
  > `.gitignore` の面での除外、`.env.example` のみ追跡、Dockerfile が `COPY` を持たない構成、`env_file: [{path: .env, required: false}]`（compose.yaml L43-L45）による「無くても起動する」設計が噛み合っている。`config/dev.exs` L17 と `config/test.exs` L7 の `secret_key_base` はリテラルだが、これは開発 / テスト専用で `prod` は `runtime.exs` L85-L89 が環境変数を必須にして無ければ `raise` する。開発の利便と本番の厳格さが分離されている。
  > 対象ファイル: `.gitignore`, `Dockerfile`, `compose.yaml`, `config/runtime.exs`

- **本番キーの権限方針を文書で先に固定している** `+2`
  > `vision.md` L38 の Least privilege、`overview.md` L152「本番キーは出金権限を付けない」、`overview.md` L153「開発用キーと本番キーを混在させない」、`README.md` L71「本番キーに出金権限を付けない」、`prod.md` L47「API キーは取引に必要な権限のみ。出金は付けない」と、4 つの文書で同じ制約を繰り返している。キーを発行する前にこの制約を書いておくことが、実際に権限を絞る唯一の担保になる。
  > 対象ファイル: `.workspace/0_doc/vision.md`, `.workspace/0_doc/architecture/overview.md`, `.workspace/0_doc/architecture/env/prod.md`

- **開発の公開面がループバックに限定され、管理系が本番に出ない** `+2`
  > `compose.yaml` の `127.0.0.1:5432` / `127.0.0.1:4000` バインド（L6, L24）、LiveDashboard の `dev_routes` ガード（router.ex L34）、`config/test.exs` L6 の `ip: {127, 0, 0, 1}` と `server: false`。開発マシンが VLAN3 の AP 配下にある構成（vision.md L65-L74）を踏まえると、`0.0.0.0` バインドを避けている判断は実効的。
  > 対象ファイル: `compose.yaml`, `apps/ui/lib/ui_web/router.ex`, `config/test.exs`

### プロジェクト全体設計

- **Vision → Architecture → 環境別 → backlog → todo → archive の文書体系が一貫している** `+4`
  > `vision.md`（目的・非目標・設計原則 6 つ・本番ネットワーク構成まで）、`architecture/overview.md`（論理構成・コンポーネント表・取引モード表・起動シーケンス・発注経路・信頼性・セキュリティ）、`env/dev.md` と `env/prod.md`（同じ項目立てで差分だけを書く）、`1_backlog` / `2_todo` / `3_archive` のステージ分けが揃っている。特に優れているのは、どの文書も「やらないこと」を明示している点（vision.md L21-L26、dev.md L83「開発環境で通っていない操作を、本番で初めて試さない」、prod.md L80-L84、各 backlog の「この要望でやらないこと」）。スコープの膨張を防ぐ最も効く仕掛けであり、個人プロジェクトでここまで整った文書体系は稀。Mermaid によるネットワーク図・役割分担図（vision.md L53-L107）や、本番PC / 作業用PC の実スペック記載まで含め、運用を実際に回す前提で書かれている。
  > 対象ファイル: `.workspace/0_doc/`

- **技術選定の評価が具体的で、実装がその結論に従っている** `+3`
  > `tech-stack.md` は層ごとの採用可否だけでなく、代替案（Ecto 単体 / 単一 Phoenix アプリ / Python + ccxt / Go / Rust）とそれぞれが向く条件を明示し（L71-L79）、「今は足さないもの: Redis、Oban、AshAdmin、エンジンの別コンテナ、機械学習基盤」（L66）まで書いている。そして実際のコードが結論どおりになっている——Ash は `System` Domain 1 枚、Umbrella は 2 アプリ、UI と engine は別 Application、Redis は不在。「評価文書を書いたが実装は別物」という乖離が無い。自己改善サイクルが形式で終わっていない証拠。
  > 対象ファイル: `.workspace/0_doc/evaluation/tech-stack.md`

- **ToDo が「完了の見方」と「次に残すもの」まで含む形式で統一されている** `+2`
  > `3_archive/01-bootstrap-umbrella-and-docker.md` は手順 1-7 の各項目にチェックボックスが付き、すべて `[x]` で埋まっている。加えて「実装時の決めごと」（L96-L100）と「次の ToDo に残すもの」（L102-L107）があり、完了時に次の作業の入り口が自動的に用意される。実際にこの「次に残すもの」が `02-ci-github-actions.md` / `03-cd-prod-host.md` へ繋がっている。作業単位の設計として再現性がある。
  > 対象ファイル: `.workspace/3_archive/01-bootstrap-umbrella-and-docker.md`, `.workspace/2_todo/`

---

## 小計

| 大分類 | 加点 |
|:---|---:|
| 技術評価層 — apps/bitflyer | +7 |
| 技術評価層 — apps/ui | +9 |
| 技術評価層 — 実行基盤 / 設定 | +12 |
| 技術評価層 — CI / CD | +2 |
| 横断評価層 | +31 |
| **合計** | **+61** |
