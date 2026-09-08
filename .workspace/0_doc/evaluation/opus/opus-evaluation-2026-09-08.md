# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-08

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-08 |
| 評価者 | 第1評価者（Claude Opus 5） |
| 対象コミット | `e2cd429`（Merge pull request #7） |
| 前回評価 | なし（**初回評価**） |
| 基準の正本 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md) |
| 詳細 | [プラス点](./opus-specific-strengths-2026-09-08.md) / [マイナス点](./opus-specific-weaknesses-2026-09-08.md) / [提案](./opus-specific-proposals-2026-09-08.md) |

本レポートは第2評価者（GPT）の当日文書を一切参照せず、Vision / Architecture / 現行コードの直接検証のみに基づいて作成した。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
| 加点合計 | **+61** |
| 減点合計 | **-60** |
| **純点** | **+1** |
| 提案（0点） | 18 件 |

### 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| 技術評価層 — apps/bitflyer | +7 | -12 | **-5** |
| 技術評価層 — apps/ui | +9 | -5 | **+4** |
| 技術評価層 — 実行基盤 / 設定 | +12 | -9 | **+3** |
| 技術評価層 — CI / CD | +2 | -10 | **-8** |
| 横断評価層 | +31 | -24 | **+7** |
| **合計** | **+61** | **-60** | **+1** |

### 横断評価層の内訳

| 小分類 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| テスト戦略 | +2 | -6 | -4 |
| 可観測性・デバッグ容易性 | +1 | -3 | -2 |
| エラーハンドリング・安全側フォールバック | +4 | -2 | +2 |
| 変更容易性・保守性 | +6 | -1 | +5 |
| 開発者体験（DX） | +2 | -2 | 0 |
| 取引完成度 | 0 | -6 | -6 |
| セキュリティ・秘密情報・権限 | +7 | -2 | +5 |
| プロジェクト全体設計 | +9 | -2 | +7 |

---

## 総評

**設計と文書は同種の個人プロジェクトを明確に上回る。一方、自動売買システムとしての機能はまだ 0% である。** 純点が +1 という「ほぼ拮抗」の数字は、この 2 つが正面から打ち消し合った結果であり、偶然ではなく現状を正確に表している。

### 何が優れているか

第一に、**境界を「守る」ではなく「破れなくする」選択をしている**こと。`apps/ui` は `{:bitflyer, in_umbrella: true}` によって `bitflyer` に一方向依存し、逆向きの参照はコンパイルが通らない。`Bitflyer.Repo` は `apps/bitflyer` に閉じ、`UiWeb.StatusLive` は `Bitflyer.System` の公開関数 2 つしか呼んでいない。`tech-stack.md` が「Umbrella を選ぶなら、恩恵は『ui が API を直接叩けない』ことを依存関係で強制できる点に置く」（L52）と述べた根拠が、そのまま構造として実現されている。

第二に、**危険側の既定値がどこにも無い**こと。`TRADE_MODE` の既定は `compose.yaml`・`.env.example`・`runtime.exs`・`Bitflyer.System.trade_mode/0` の 4 箇所すべてで `dry_run`。設定が抜けても `live` に倒れない。秘密情報は `.gitignore` が面で除外し、Dockerfile は `COPY` を持たず、`prod` の `SECRET_KEY_BASE` は未設定なら `raise` する。「資金を守る」を思想としてではなく既定値として書いている。

第三に、**実装前に禁止事項を確定させている**こと。`paper-trade-adapter.md` の「`apps/paper` は作らない。ペーパーは取引所ではなく、order-executor の出口である」と、`overview.md` L98 の「同じ経路を通さないペーパーは、本番で初めて壊れる」は、実務でよくある失敗を先回りして塞いでいる。`.workspace/0_doc/` の文書体系は、Vision の非目標、各環境の差分、各 backlog の「やらないこと」まで揃っており、コードを書く前に何を書かないかを決める規律がある。

第四に、**実際に踏んだ問題を仕組みに固定している**こと。`.gitattributes` の `bin/* text eol=lf` は Windows での起動失敗（`set: Illegal option -`）への対処であり、コミット `0a36ae3` に対応する。`compose.yaml` で `deps` / `_build` を名前付きボリュームに逃がしているのも、bind mount 上の Mix コンパイル劣化への正しい対処である。骨格フェーズの `compose.yaml` としては水準が高い。

### 何が足りないか

**取引システムとして、まだ何も取引しない。** `apps/bitflyer/lib/` は 5 ファイル、依存は `:ash` と `:ash_postgres` の 2 つのみで、bitFlyer への HTTP / WebSocket クライアントは存在しない。Architecture が定めた market-data / strategy / risk-manager / order-executor は 1 行も書かれておらず、起動シーケンスの 6 ステップのうち実装されているのは「設定を読み込む」だけ。永続化対象は `heartbeats` テーブル 1 本で、注文・建玉・残高・リスク状態の正本が無い。したがって Vision の 3 原則のうち **Safety first・Recoverable・Idempotent は現時点でコードから検証できない**。骨格 ToDo の完了条件には含まれない計画的な未着手だが、評価としては「価値命題が未実装」と記録するほかない。

**品質ゲートが実効性を欠いている。** これは今すぐ直せる、かつ直さないと後で高くつく問題である。実測した結果は次のとおり。

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm app mix precommit` | **失敗**（exit 1）。compose が `MIX_ENV=dev` を注入し `preferred_envs` を上書きするため、`UiWeb.ConnCase` が見つからずコンパイルエラー |
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | 成功。ただし **6 tests**（`apps/ui` のみ） |
| `docker compose run --rm -e MIX_ENV=test app mix test` | 成功。**1 doctest, 1 test + 6 tests = 7 tests**（両アプリ） |
| `mix format --check-formatted` | 成功 |
| `mix compile --force --warnings-as-errors` | 成功（警告ゼロ） |

`precommit` alias が `apps/ui/mix.exs` にしか無いため、Umbrella のタスク再帰で `apps/bitflyer` は素通りする。しかも alias の中身が `format`（書き換え）であって `format --check-formatted` ではないため、整形漏れを検出できない。AGENTS.md と ToDo 02 が「ローカルと CI の同じ品質ゲート」と位置付けているコマンドが、取引ロジックの正本アプリを検査していない。今は差が 1 テストだが、engine の実装が始まった瞬間に「緑なのに壊れている」を生む。`.github/workflows/` が未作成なことと合わせ、CI / CD 観点は -8 と最も低い小計になった。

**テストが「動くこと」を確認していない。** `StatusLiveTest` は `#db-status-label` の存在しか見ておらず、DB が繋がっていても切れていても緑になる。両 `test_helper.exs` に `Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)` が無く、テストが開発用データベース `docker_bitflyer_dev` を直接使っていることも実測で確認した（`Bitflyer.Repo.config()[:database]` が `MIX_ENV=test` でも `docker_bitflyer_dev` を返す）。現状は Sandbox のロールバックに救われているが、`ash.setup` 相当を test で走らせた日に開発データを壊す。

**観測手段が無い。** `apps/bitflyer` に `Logger` の使用も `:telemetry.execute/3` も 0 件。`tech-stack.md` 自身が「Telemetry + 構造化ログ」を『今』足すものに分類している（L59）が着手されていない。Discord 通知も未着手で、VLAN1 の本番PC が無人稼働する想定に対して、人に届く経路が存在しない。

### 総合判断

この段階のプロジェクトとして、**土台の質は高く、方向は正しい**。特に「何を作らないか」を先に決める規律と、境界を依存関係で強制する構造は、engine を書き始めたあとに効いてくる資産である。同時に、`docker compose up` して見えるのは「PostgreSQL に繋がっている」という一点だけであり、Vision との距離は依然として大きい。

優先順位としては、**engine の実装より先に品質ゲートを直すべき**である。ルート `mix.exs` に `precommit` を 1 行足し、CI を 1 本置く作業は数時間で終わるが、これを engine のあとに回すと、検査されないコードで発注ロジックを書くことになる。次いで `Readiness` と telemetry の枠を先に置き、そのうえで `dry_run` の縦貫通（Ticker 購読 → risk で拒否 → 意図をログと DB に記録）を最初のマイルストーンにするのが、この設計に最も素直な進め方である。

---

## `mix precommit` 実行結果

評価ルールに従い、Docker 経由（`docker compose run --rm app ...`）で実行した。ホスト側の Elixir は 1.19.5 / OTP 28 で、Dockerfile がピンする 1.18.3 / OTP 27 と一致しないため、判定はコンテナ内の結果を正とする。

```
$ docker compose run --rm app mix precommit
==> ui
    error: module UiWeb.ConnCase is not loaded and could not be found
    │
  2 │   use UiWeb.ConnCase, async: true
    │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    │
    └─ test/ui_web/controllers/error_html_test.exs:2: UiWeb.ErrorHTMLTest (module)
== Compilation error in file test/ui_web/controllers/error_html_test.exs ==
** (CompileError) ... cannot compile module UiWeb.ErrorHTMLTest (errors have been logged)
exit code: 1
```

原因は `compose.yaml` L38 の `MIX_ENV: ${MIX_ENV:-dev}` が `apps/ui/mix.exs` L32-L36 の `preferred_envs: [precommit: :test]` を上書きし、`elixirc_paths(:test)` が効かなくなること。`MIX_ENV=test` を明示すると通る。

```
$ docker compose run --rm -e MIX_ENV=test app mix precommit
==> ui
Running ExUnit with seed: 252235, max_cases: 64
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)
6 tests, 0 failures
exit code: 0
```

`apps/bitflyer` に `precommit` alias が無いため、同アプリのテストは実行されていない。参考として `mix test` を単体で実行すると両アプリが走る。

```
$ docker compose run --rm -e MIX_ENV=test app mix test
==> bitflyer
1 doctest, 1 test, 0 failures
==> ui
6 tests, 0 failures
exit code: 0
```

個別ゲートも確認した。

```
$ docker compose run --rm -e MIX_ENV=test app sh -lc "mix format --check-formatted; mix compile --force --warnings-as-errors"
（差分なし。bitflyer 5 ファイル / ui 19 ファイルを警告ゼロで再コンパイル）
exit code: 0
```

**要約**: 整形と警告ゼロコンパイルは通る。テストも全 7 件が緑。ただし文書化されたコマンド `docker compose run --rm app mix precommit` はそのままでは失敗し、環境変数を補って成功させても検査対象が `apps/ui` に限られる。品質ゲートとしては未成立と判断する。

---

## 検証したファイル

コードを直接読んで検証した主要ファイル（`deps/` と `_build/` を除く追跡ファイルはほぼ全件を確認した）。

### 基準文書

- `.workspace/0_doc/vision.md`
- `.workspace/0_doc/architecture/overview.md`
- `.workspace/0_doc/architecture/env/dev.md`
- `.workspace/0_doc/architecture/env/prod.md`
- `.workspace/0_doc/evaluation/tech-stack.md`
- `.cursor/rules/evaluation.mdc`

### 作業管理

- `.workspace/2_todo/02-ci-github-actions.md`
- `.workspace/2_todo/03-cd-prod-host.md`
- `.workspace/3_archive/01-bootstrap-umbrella-and-docker.md`
- `.workspace/1_backlog/elixir-umbrella-phoenix-ash.md`
- `.workspace/1_backlog/paper-trade-adapter.md`
- `.workspace/1_backlog/discord-notify-adapter.md`

### apps/bitflyer

- `apps/bitflyer/mix.exs`
- `apps/bitflyer/lib/bitflyer.ex`
- `apps/bitflyer/lib/bitflyer/application.ex`
- `apps/bitflyer/lib/bitflyer/repo.ex`
- `apps/bitflyer/lib/bitflyer/system.ex`
- `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`
- `apps/bitflyer/priv/repo/migrations/20260904092539_add_heartbeats.exs`
- `apps/bitflyer/test/bitflyer_test.exs`
- `apps/bitflyer/test/test_helper.exs`
- `apps/bitflyer/README.md`

### apps/ui

- `apps/ui/mix.exs`
- `apps/ui/lib/ui/application.ex`
- `apps/ui/lib/ui_web.ex`
- `apps/ui/lib/ui_web/endpoint.ex`
- `apps/ui/lib/ui_web/router.ex`
- `apps/ui/lib/ui_web/telemetry.ex`
- `apps/ui/lib/ui_web/live/status_live.ex`
- `apps/ui/lib/ui_web/components/layouts.ex`
- `apps/ui/lib/ui_web/plugs/locale.ex`
- `apps/ui/lib/ui_web/hooks/locale.ex`
- `apps/ui/lib/ui_web/controllers/locale_controller.ex`
- `apps/ui/lib/ui_web/controllers/page_controller.ex`
- `apps/ui/assets/css/app.css`
- `apps/ui/test/support/conn_case.ex`
- `apps/ui/test/test_helper.exs`
- `apps/ui/test/ui_web/live/status_live_test.exs`
- `apps/ui/README.md`

### 設定 / 実行基盤

- `mix.exs`（Umbrella ルート）
- `config/config.exs`
- `config/runtime.exs`
- `config/dev.exs`
- `config/test.exs`
- `config/prod.exs`
- `compose.yaml`
- `Dockerfile`
- `bin/docker-entrypoint.sh`
- `.env.example`
- `.gitignore`
- `.gitattributes`
- `.formatter.exs`
- `README.md`

### 実行して確認した事項

- `docker compose run --rm app mix precommit`（失敗を再現）
- `docker compose run --rm -e MIX_ENV=test app mix precommit`（6 tests）
- `docker compose run --rm -e MIX_ENV=test app mix test`（7 tests）
- `mix format --check-formatted` / `mix compile --force --warnings-as-errors`
- `Bitflyer.Repo.config()[:database]` が `MIX_ENV=test` で `docker_bitflyer_dev` を返すこと
- `psql -l` による実在データベース一覧（`docker_bitflyer_dev` のみ）
- `git ls-files` による `.github/` 不在、`.dockerignore` 不在の確認
- `Decimal` / `:decimal` の出現 0 件、`apps/bitflyer` 内の `Logger` / `:telemetry` 使用 0 件
