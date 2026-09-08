# 第1評価者（Claude Opus 5）— 提案（0点）詳細 2026-09-08

対象コミット: `e2cd429`（初回評価）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

ここに挙げた項目は**減点ではない**。マイナス点一覧に挙げた「欠如」とは別に、「あると次の段階が楽になる」ものを前向きな次の一手として記録する。

**合計: 18 件 / 0 点**

---

## 技術評価層 — apps/bitflyer

### 取引モードと安全ゲート

- **`Bitflyer.TradeMode` モジュールでモードを型として扱う** `0`
  > 現在 `TRADE_MODE` は文字列のまま `runtime.exs` → `Application` env → `StatusLive` へ流れている。`parse!/1` で `~w(dry_run paper live)` を atom へ正規化し、`live?/0` `paper?/0` `orders_reach_exchange?/0` のような述語を 1 箇所に集めると、executor を書くときに文字列比較が散らばらない。あわせて `live` の有効化に `TRADE_MODE=live` と `BITFLYER_LIVE_CONFIRM=<日付>` のような二重確認を要求すれば、overview.md L101「live へ切り替える操作は設定上で目立たせ」を仕組みとして満たせる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **エンジン実装より先に telemetry イベント語彙を確定させる** `0`
  > `Bitflyer.Telemetry` に `[:bitflyer, :market_data, :tick]` / `[:bitflyer, :risk, :rejected]` / `[:bitflyer, :order, :submitted]` / `[:bitflyer, :order, :filled]` / `[:bitflyer, :reconcile, :mismatch]` / `[:bitflyer, :circuit, :opened]` を先に定数として並べ、`measurements` と `metadata` のキーを決めておく。イベント名を後付けすると、必ず途中で改名が発生して過去ログとダッシュボードが繋がらなくなる。実装は `UiWeb.Telemetry.metrics/0` に足すだけで LiveDashboard に出る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/ui/lib/ui_web/telemetry.ex`

- **鮮度付き ETS キャッシュの型を先に決める** `0`
  > overview.md L91 の cache は ETS（Redis 不要）と決まっている。値を `{value, received_at_monotonic}` の組で持ち、`fresh?/2` が単一の閾値関数として存在する形を先に置くと、「古いデータでは発注しない」ゲート（overview.md L36, L138）を risk-manager から 1 行で呼べる。鮮度判定を各所に書いてから統一するのは難しい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

- **定期突合タイマーを起動時突合と同じコードパスで回す** `0`
  > tech-stack.md L60 が「起動時だけでなく、稼働中も取引所の事実と合わせる」を『発注の前』に足すものとして挙げている。`Reconciler` を GenServer にして `handle_continue(:initial, _)` と `handle_info(:periodic, _)` が同じ `reconcile/1` を呼ぶ構造にすれば、起動突合と定期突合でロジックが分岐しない。分岐すると「起動時は直るのに稼働中は直らない」不整合が生まれる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

---

## 技術評価層 — apps/ui

### 運用可視性

- **`GET /health` を専用エンドポイントとして切り出す** `0`
  > 現在 compose の healthcheck は `/`（LiveView）を叩いている。認証不要・レンダリング不要の `UiWeb.HealthController` を用意し、`{"status": "ready" | "degraded" | "halted", "db": true, "trade_mode": "dry_run", "reason": null}` を返して 200/503 を出し分ける。compose の healthcheck、`prod.exs` の `force_ssl` 除外パス（prod.exs L16-L17 のコメントに `paths: ["/health"]` が既に用意されている）、将来の外部監視の 3 者が同じ 1 本を見られる。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `compose.yaml`, `config/prod.exs`

- **モードバッジの色分けと「発注可否」の単一表示** `0`
  > `dry_run` は中立色、`paper` は青系、`live` は赤系のバッジにし、画面最上部に「発注: 可 / 停止（理由）」を 1 行で置く。運用者が画面を 1 秒見て判断すべきなのは「今トレードしてよいか」だけで、それ以外は詳細である。dev.md L62「実発注モードへ切り替える操作は、設定ファイル上で目立つようにする」の画面版。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **ポーリングを PubSub のプッシュへ置き換える** `0`
  > 現在は 5 秒周期で `check_database/0` を叩いている（status_live.ex L7, L115-L117）。engine 側が状態変化時に `Phoenix.PubSub.broadcast(Ui.PubSub, "system:status", ...)` を投げ、LiveView は購読するだけにすると、DB への定期クエリが消え、状態変化が即座に画面に出る。`Ui.PubSub` は既に起動済み（ui/application.ex L13）で追加依存は不要。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/ui/lib/ui/application.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **`.dockerignore` を本番 Dockerfile より先に置く** `0`
  > `_build`, `deps`, `.git`, `.env*`, `.workspace`, `apps/*/priv/static/assets`, `apps/ui/assets/node_modules` を除外する。今は `COPY` が無いので実害は小さいが、`Dockerfile.prod` を書く日には必ず必要になる。順番を逆にすると、最初のビルドで `.env` がイメージに入る。
  > 対象ファイル: リポジトリルート

- **テスト専用データベースを分離する** `0`
  > `runtime.exs` の `:test` 分岐で `TEST_DATABASE_URL` を優先し、無ければ `DATABASE_URL` のパス末尾を `_test` に差し替える。`.env.example` にも名前を載せる。CI で PostgreSQL サービスを立てる際も同じ変数で通せるので、ToDo 02 手順 3 の作業が減る。
  > 対象ファイル: `config/runtime.exs`, `.env.example`

- **`mix release` と本番 Compose を「実弾なし」で先に通す** `0`
  > ToDo 03 手順 6 が既に「本番相当の Compose を、キーなしまたは検証用・発注停止で一度上げる」を掲げている。ルート `mix.exs` に `releases: [docker_bitflyer: [applications: [bitflyer: :permanent, ui: :permanent]]]` を定義すれば Umbrella 全体が 1 リリースになる。engine が空の今こそ、配布と入れ替えとロールバックだけを検証する好機で、後から engine を載せてもデプロイ経路は変わらない。
  > 対象ファイル: `mix.exs`, `.workspace/2_todo/03-cd-prod-host.md`

- **コンテナの停止猶予とアプリの shutdown を揃える** `0`
  > compose の `app` に `stop_grace_period: 30s` を置き、監督ツリー側にも同じ値の `shutdown` を設定する。今は書き込むものが無いので設定するだけだが、executor を足したあとに「デプロイのたびに未確定注文が残る」ことに気づくより、先に枠を作っておく方が安い。
  > 対象ファイル: `compose.yaml`, `apps/bitflyer/lib/bitflyer/application.ex`

---

## 技術評価層 — CI / CD

- **ルート `mix.exs` の `precommit` を単一の品質ゲートにする** `0`
  > `precommit: ["deps.unlock --check-unused", "format --check-formatted", "compile --warnings-as-errors", "test"]` と `def cli, do: [preferred_envs: [precommit: :test]]` をルートに置き、`apps/ui` 側の同名 alias を削除する。ホスト・コンテナ・CI の 3 箇所が同じ 1 コマンドを呼ぶ形になり、ToDo 02 手順 2 の完了条件をそのまま満たす。実測では現状の `mix precommit` が `apps/bitflyer` を検査しないため、この 1 行の変更で検査範囲が倍になる。
  > 対象ファイル: `mix.exs`, `apps/ui/mix.exs`

- **`.github/workflows/ci.yml` を 1 本置く** `0`
  > `erlef/setup-beam` で Elixir 1.18 / OTP 27 を `Dockerfile` と揃え、`services: postgres:16-alpine` を立て、`deps` / `_build` をキャッシュし、`mix precommit` を呼ぶ。必要な secret はテスト用 DB 接続情報のみで、bitFlyer / Discord のキーは載せない（ToDo 02 L46）。トリガーは `pull_request` と `push: main`。
  > 対象ファイル: リポジトリルート

- **静的解析と脆弱性チェックを段階的に足す** `0`
  > `mix_audit`（依存の既知脆弱性）を最初に、次に `credo --strict`、最後に `dialyxir` の順で足す。ToDo 02 L86 が「Credo / Dialyzer は後続で足してよい」としているのは妥当だが、`mix_audit` だけは実行が速く偽陽性も少ないので先に入れる価値がある。Phoenix を公開するなら `sobelow` も候補。
  > 対象ファイル: `mix.exs`, `.github/workflows/`

---

## 横断評価層

### テスト戦略

- **取引所クライアントをビヘイビアで抽象化し、モード分岐をテストで固定する** `0`
  > `Bitflyer.Exchange` ビヘイビア（`send_order/1`, `cancel_order/1`, `list_open_orders/0`, `balance/0`）を定義し、`Mox` で `TRADE_MODE=paper` のときに `send_order/1` が **呼ばれないこと** を `expect(..., 0, ...)` で固定する。paper-trade-adapter.md L52 の完了条件「paper 中に発注 REST が呼ばれないことをテストで固定できる」を、そのまま 1 テストに落とせる。実装より先にこの契約を決めるのが安い。
  > 対象ファイル: `apps/bitflyer/test/`, `.workspace/1_backlog/paper-trade-adapter.md`

- **金額・数量・冪等キーにプロパティベーステストを当てる** `0`
  > `stream_data` を入れ、(1) 内部注文 ID を重複させても永続化される注文が 1 件であること、(2) `Decimal` の丸めが常に「保守的な側（買いは切り下げ、売りは切り上げ）」へ倒れること、(3) 建玉の増減が任意の約定順序に対して可換であること、を性質として書く。例示ベースのテストでは、実際に損失を生む境界値（最小ロット、桁あふれ、部分約定の積み上げ）を踏み抜きやすい。
  > 対象ファイル: `apps/bitflyer/test/`

### 開発者体験 / 運用

- **Discord 通知アダプタを「起動 / 停止」だけ先行実装する** `0`
  > `discord-notify-adapter.md` は方針が確定済み（アダプタとして `bitflyer` 内、発注経路から独立、Webhook 未設定でも落ちない）。engine の完成を待たず、`Application.start/2` と `stop/1` の 2 イベントだけ先に流すと、「本番PC が再起動した」ことに人が気づける状態を今すぐ作れる。Vision の「届かない監視は監視ではない」に対する最小の実装で、後からイベント種別を足すだけで済む。
  > 対象ファイル: `.workspace/1_backlog/discord-notify-adapter.md`, `apps/bitflyer/lib/bitflyer/`

- **文書リンクの機械チェックを CI に載せる** `0`
  > `.workspace` と `README.md` は相互リンクが多く、ToDo をアーカイブへ移すたびに切れる。`lychee --offline` 等でリポジトリ内リンクだけを検証するジョブを 1 つ足すと、文書体系の信頼性が維持コストなしで保てる。文書がプロジェクトの主要な資産である以上、その整合性も CI の対象にしてよい。
  > 対象ファイル: `.github/workflows/`, `README.md`, `.workspace/`

---

## 小計

| 大分類 | 件数 |
|:---|---:|
| 技術評価層 — apps/bitflyer | 4 |
| 技術評価層 — apps/ui | 3 |
| 技術評価層 — 実行基盤 / 設定 | 4 |
| 技術評価層 — CI / CD | 3 |
| 横断評価層 | 4 |
| **合計** | **18 件 / 0 点** |
