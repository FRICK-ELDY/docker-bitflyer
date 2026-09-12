# docker-bitflyer

Docker で 24 時間 365 日動かす、bitFlyer 自動売買システム。

人が常時監視しなくても、市場データの取得・戦略判定・リスク検査・発注・再起動後の復帰までを回し続ける。利益より、想定外の損失を止めることを優先する。

Elixir Umbrella（`apps/ui` Phoenix / `apps/bitflyer` Ash）と PostgreSQL を Compose で起動する。

## 現状

開発用 Compose で常駐起動できる。`TRADE_MODE` の既定は `dry_run`。本番相当は `Dockerfile.prod` + `compose.prod.yaml`（release・非 root）。live 実発注は署名付き `Bitflyer.Exchange.Rest`（キーあり時に差し込み。既定は `Unavailable`）。

起動・観測の要点:

- 開発: `docker compose up -d` で `app`（Phoenix）と `db`（PostgreSQL）が上がる
- 本番相当: `docker compose -f compose.prod.yaml --env-file .env.prod up -d --build`（詳細は [prod.md](.workspace/0_doc/architecture/env/prod.md)）
- UI は `http://127.0.0.1:4000/`（稼働確認用 Status。取引 UI ではない）
- 稼働 API: `GET /health/live`（プロセス生存・Compose healthcheck）、`GET /health/ready`（DB + Ready + Feed/鮮度）、`GET /health`（従来互換）
- 品質ゲートはローカルも CI も `mix precommit`
- CD: 明示タグ `v*` または手動で GHCR へ push（**対象 SHA の CI 緑が前提**。`main` マージ alone ではデプロイしない）

### コンポーネント別

| コンポーネント | 状態 | メモ |
| --- | --- | --- |
| market-data（Feed / Cache / 再接続 / gap-fill） | implemented | ETS 鮮度＋取引所 `source_timestamp`。stale / skew は risk。購読は JSON-RPC id の ACK 待ち（`result: true` のみ。未 ACK / error / 失敗 ACK は再接続。書込み成功だけでは connected にしない）。無通信は鮮度窓×3（`stall_timeout_ms` 上書き可）で切断→再接続 |
| strategy（Behaviour / Runner / FixedOnce） | implemented | dry_run/paper の骨。live は既定オフ・FixedOnce 禁止・Risk 上限は env 必須。適用履歴は `StrategyParameterRevision` + Order 由来 |
| risk-manager（limits / circuit / 鮮度） | partial | サイズ・建玉・頻度（再起動時 Order 温存）・価格逸脱・時計ずれは実効。MarketData 有効時は Feed 接続を Status / ready と同じ `market_feed_gate` で認可（切断直後は Cache 鮮度を待たない）。日次損失は Fill.realized_pnl（live は getexecutions `commission` を `Fill.fee` に残し net）/DailyLoss。日次ドローダウンは realized+unrealized の当日ピーク（HWM）からの下落（`Equity`。HWM は `DailyEquityPeak` に永続、読取失敗は unsynced。mark stale は認可・resume fail-closed・周期は halt しない。unrealized は内部平均×LTP の推定）。残高は BalanceCache（**live は spot `getbalance` のみ。FX/CFD 証拠金は未実装**。記録済み fee は quote 差分に織り込み、未記録 Fill だけ 20bps）。spot 在庫は getbalance base amount と買い Position（内部膨張・売建玉で halt。live 売りは建玉カバー必須）。成功時はワンショット `AuthorizedOrder`（偽造・再利用不可）。401/403 即 halt・窓内連続拒否は FailureRate |
| order-executor（dry_run / paper / live 出口） | implemented | `AuthorizedOrder.consume` 必須（`System.submit_order` 経由）。冪等キーあり。paper は成行 LTP±bps（slip+fee）/ 指値は fee のみ。認可拘束も同価格。live はゲート通過時のみ REST |
| datastore（Ash: Order / Position / Fill / Balance / DailyEquityPeak / RiskState） | implemented | `Bitflyer.Repo` に閉じる |
| cache（ETS） | implemented | 単一ノード前提。Redis なし |
| TradeMode | implemented | `dry_run` / `paper` / `live` + `BITFLYER_LIVE_CONFIRM` |
| 既定銘柄 | **spot `BTC_JPY`**（allowlist） | live は spot 限定（`FX_*` / 未登録ペアは起動・認可で拒否）。FX live は `getcollateral` 実装後（[backlog](.workspace/1_backlog/fx-collateral-adapter.md)） |
| Readiness / 突合 / resume / baseline / recover | implemented | boot・定期突合。live は権限（出金禁止）・ticker 時計検査あり。`mix bitflyer.resume` / baseline / recover。`prep_stop` はゲート閉鎖＋ drain |
| observe — telemetry / 構造化ログ | implemented | allowlist（`:kind` / `:currency` / `:limit` 含む）。prod は ConsoleReporter 既定オン（低頻度ドメインのみ） |
| observe — Discord 通知 | implemented | Incoming Webhook。halt / mismatch / disconnect + 起動直後 HEARTBEAT。未設定でも起動。発注は止めない |
| observe — health | implemented | `/health/live`・`/health/ready`・`/health`。外部監視は別ホストから ready を pull（[prod.md](.workspace/0_doc/architecture/env/prod.md)） |
| observe — LiveDashboard | implemented | BasicAuth 配下 `/ops/dashboard`（prod/dev）。Ecto/RequestLogger オフ |
| UI StatusLive | implemented | 発注可否・建玉・未約定・当日損益・halt 復帰手順・Feed・鮮度・モード色分け。BasicAuth 付き kill / resume / reconcile |
| observe — 実 API contract / Game Day | implemented | 匿名公開 corpus の意味論（`mix bitflyer.contract --corpus`）。公開 GET 探針は人手。`--private` は署名 GET のみ（発注しない）。手順は [game-day.md](.workspace/0_doc/architecture/env/game-day.md) |
| CI（`mix precommit` / GitHub Actions） | implemented | PR と `main`。`Dockerfile.prod` ビルド検証（push なし）も実行 |
| deps audit（`mix deps.audit`） | implemented | CI 別ジョブ。Hex advisory 検出時のみ fail。ツール障害は落とさない。Actions は SHA pin。Dependabot（mix / github-actions）。GitHub タグ依存はスキャン対象外 |
| CD（GHCR push） | implemented | `v*` / `workflow_dispatch`。**最新 CI（workflow 全体）success の SHA のみ**。digest を Compose に固定 |
| private bitFlyer API（署名付き REST） | implemented | `Exchange.Rest`。cancel / 照会 / 約定反映。live+キーで差し込み。既定は Unavailable |
| UI 認証（BasicAuth） | implemented | `UI_BASIC_AUTH_*`。prod 必須。`/health*` は対象外 |
| 本番 release Compose | implemented | `Dockerfile.prod` / `compose.prod.yaml` / backup・rollback 手順 |

完了した骨格・CI は [3_archive/](.workspace/3_archive/)。改善の優先順位は [improvement-plan.md](.workspace/0_doc/evaluation/improvement-plan.md)。

## 開発起動

前提: Docker / Compose が使えること。ホストに Elixir は不要。

```bash
cp .env.example .env
docker compose up -d --build
```

初回はイメージビルドと `deps.get` / `ash.setup` で時間がかかる。準備が終わると UI に `http://127.0.0.1:4000/` でアクセスできる。

| サービス | ホスト公開 |
| --- | --- |
| `app`（Umbrella） | `127.0.0.1:4000` |
| `db`（PostgreSQL） | `127.0.0.1:5432` |

ソースは `app` に bind mount する。よく使う操作:

```bash
docker compose logs -f app
docker compose restart app
docker compose down
```

開発用と本番用の見分け: `Dockerfile` + `compose.yaml` が開発（bind mount / `mix phx.server`）。`Dockerfile.prod` + `compose.prod.yaml` が本番（release・非 root）。詳細は [prod.md](.workspace/0_doc/architecture/env/prod.md) / [ci-cd.md](.workspace/0_doc/architecture/ci-cd.md)。

## 本番相当の起動（実弾なし）

`.env.prod` に `SECRET_KEY_BASE`・`UI_BASIC_AUTH_*`・`POSTGRES_PASSWORD`・`DATABASE_URL` を置く（キーの置き方の詳細は書かない）。検証時の `TRADE_MODE` は `dry_run`。

```bash
cp .env.example .env.prod
# 必須値を埋める
docker compose -f compose.prod.yaml --env-file .env.prod up -d --build
# または ./bin/deploy-prod.sh
# 開発用と同時なら: APP_HOST_PORT=127.0.0.1:4001 docker compose -f compose.prod.yaml --env-file .env.prod up -d --build
curl -fsS http://127.0.0.1:4000/health/live
```

バックアップ: `./bin/backup-db.sh`。ロールバック: `./bin/deploy-prod.sh rollback <image@digest>`。GHCR 配布は `v*` タグまたは Actions 手動。
## 品質ゲート

コミット前・PR 前に、ローカルで次を緑にする。

```bash
docker compose run --rm app mix precommit
```

中身は format チェック / warnings-as-errors の compile / test（両アプリ）/ 未使用 deps。`MIX_ENV` は Compose に固定しない（`.env` にも書かない）。`preferred_envs` が `precommit` を `:test` にする。

`ash.setup` は常駐起動（`phx.server`）時だけ走り、対象は開発用 DB（`docker_bitflyer_dev`）。テストは別 DB（既定 `docker_bitflyer_test`）を使うため、初回やマイグレーション追加のあとは先に次を実行する。

```bash
docker compose run --rm -e MIX_ENV=test app mix ash.setup --domains Bitflyer.Trading
```

（上書きしたいときは `TEST_DATABASE_URL` を設定する。CI はジョブ内で setup してから `precommit` する。）

GitHub Actions は PR / `main` で `mix precommit` に加え `deps-audit`（Hex advisory 検出時のみ fail）と `Dockerfile.prod` ビルド検証（push なし）も行う。範囲の詳細は [architecture/ci-cd.md](.workspace/0_doc/architecture/ci-cd.md)。**CI が赤のまま `main` へマージしない。** CD（GHCR）は対象 SHA の**最新** `ci.yml`（workflow 全体）success を前提とする（未完了時は待たず失敗・再実行）。

### deps audit（precommit から分離）

`mix precommit` には入れない。CI の別ジョブが `mix deps.audit --format=json` を 1 回実行し、`"pass":false` のときだけ落とす。Hex の取得障害などは warning でジョブ成功（配布は止めない）。artifact `deps-audit-report`。ローカル再現:

```bash
docker compose run --rm app mix deps.audit
```

Hex の既知 advisory が対象。`heroicons` / `daisyui` など GitHub タグ依存はスキャンされない。更新 PR は Dependabot（`.github/dependabot.yml`）。Actions は commit SHA 固定。**CI 緑 ≠ GitHub 依存に既知脆弱性なし。**

## 環境変数

`.env.example` をコピーして使う。追跡するのは example だけ。

| 名前 | 既定の意味 |
| --- | --- |
| `DATABASE_URL` | Compose 内ホスト `db` 向け（開発用 DB） |
| `TEST_DATABASE_URL` | 任意。未設定時は `DATABASE_URL` の DB 名を `*_test` に寄せる |
| `SECRET_KEY_BASE` | Phoenix 用（後で生成し直す） |
| `PHX_HOST` | `localhost` |
| `TRADE_MODE` | `dry_run` |
| `BITFLYER_LIVE_CONFIRM` | live 時のみ。UTC 当日 `YYYY-MM-DD` |
| `BITFLYER_API_KEY` / `BITFLYER_API_SECRET` | Private API。`TRADE_MODE=live` 時のみ必須。出金権限は付けない |
| `BITFLYER_MAX_*` / `BITFLYER_STRATEGY_ENABLED` | live 専用。上限 5 項目は必須。戦略は既定オフ（FixedOnce 不可） |
| `DISCORD_WEBHOOK_URL` | 任意。Discord Incoming Webhook。未設定でも起動する |
| `DISCORD_HEARTBEAT_INTERVAL_MS` | 通知 HEARTBEAT 間隔（既定 900000 = 15 分）。`0` / `infinity` でオフ |
| `UI_BASIC_AUTH_USERNAME` / `UI_BASIC_AUTH_PASSWORD` | Status UI・`/ops/dashboard`。prod 必須。dev は両方揃ったときだけ有効 |
| `UI_METRICS_CONSOLE` | ConsoleReporter。未設定時は prod のみオン（tick/Phoenix/VM 除外）。`false` でオフ |
| `PHX_HTTP_IP` | prod のみ。既定 `127.0.0.1`（公開面最小化） |

## bitFlyer API で取得できる情報

公式: [HTTP / Realtime API ドキュメント](https://api.bitflyer.jp/docs/api)。エンドポイントは `https://api.bitflyer.com/v1/`。Realtime は `wss://ws.lightstream.bitflyer.com/json-rpc`。

一覧は取引所側が提供する取得系の要約。本リポジトリが全部を実装しているわけではない（現状の利用は下表の「本リポ」列）。

### HTTP Public（認証不要）

| 取得できる情報 | 主なパス | 本リポ |
| --- | --- | --- |
| マーケット一覧（`product_code` / 現物・CFD） | `GET /v1/markets`（契約は `getmarkets`） | contract corpus |
| 板（bids / asks / mid） | `GET /v1/board` | — |
| Ticker（LTP・出来高など） | `GET /v1/ticker` | market-data（gap-fill）+ contract |
| 約定履歴（市場） | `GET /v1/executions`（契約は `getexecutions`） | contract corpus |
| 板の状態（通常 / BUSY 等） | `GET /v1/getboardstate` | — |
| 取引所の稼働状態 | `GET /v1/gethealth` | — |
| ファンディングレート | `GET /v1/getfundingrate` | — |
| ファンディングレート履歴 | `GET /v1/getfundingratehistory` | — |
| 法人アカウント最大レバレッジ | `GET /v1/getcorporateleverage` | — |
| チャット | `GET /v1/getchats` | — |

### HTTP Private（`BITFLYER_API_*`・権限が必要）

| 取得できる情報 | 主なパス | 本リポ |
| --- | --- | --- |
| API キーの権限一覧 | `GET /v1/me/getpermissions` | live 起動検査（出金・送付禁止） |
| 資産残高 | `GET /v1/me/getbalance` | Rest 突合（**live 残高正本。既定 spot**） |
| 証拠金の状態 | `GET /v1/me/getcollateral` | —（FX live 未対応） |
| 通貨別証拠金 | `GET /v1/me/getcollateralaccounts` | — |
| 注文一覧（未約定含む） | `GET /v1/me/getchildorders` | Rest 突合・照会 |
| 親注文一覧 / 詳細 | `GET /v1/me/getparentorders` 等 | 使わない想定 |
| 自分の約定一覧 | `GET /v1/me/getexecutions` | Rest 約定反映 |
| 建玉一覧（CFD / FX） | `GET /v1/me/getpositions` | Rest 突合（**spot では呼ばない**） |
| 残高履歴 | `GET /v1/me/getbalancehistory` | — |
| 証拠金変動履歴 | `GET /v1/me/getcollateralhistory` | — |
| 取引手数料 | `GET /v1/me/gettradingcommission` | — |
| 預入アドレス / コイン入出金履歴 | `GET /v1/me/getaddresses` 等 | 使わない（出金権限禁止） |
| 銀行口座 / 入出金履歴 | `GET /v1/me/getbankaccounts` 等 | 使わない |

発注・取消・出金などは取得ではなく操作 API（`sendchildorder` / `cancelchildorder` 等）。本システムの live 出口で使うのは発注・取消側。**出金 API は使わない。**

### live（spot 限定）の運用前提

- 既定・推奨は **`BTC_JPY` + `getbalance`**。`product_codes` に `FX_*` を入れると live 起動が拒否される
- **同一 API キー口座の手動 FX/CFD 建玉は監視しない。** spot 設定時は `getpositions` を呼ばず建玉突合もしないため、口座に残る CFD エクスポージャはボットの Ready / Risk から見えない。live 解禁前に当該キー口座を spot 専用にするか、手動建玉を解消すること
- spot の内部 `Position` は Risk の建玉上限用であり、取引所建玉との突合対象外。**在庫の正本は `getbalance`（BTC/JPY）**。Fill 後の Position ドリフトは残高突合と LiveFills に依存する

### Realtime（WebSocket）

公開チャネル例（`product_code` 付き）:

| チャネル | 内容 | 本リポ |
| --- | --- | --- |
| `lightning_ticker_*` | Ticker 更新 | market-data Feed |
| `lightning_board_snapshot_*` / `lightning_board_*` | 板スナップショット / 差分 | — |
| `lightning_executions_*` | 市場の約定ストリーム | — |

注文イベント受信など Private のリアルタイムは API キー権限「注文のイベントを受信」が必要。現状の Feed は公開 ticker のみ。

## よく使う mix

すべてコンテナ内で実行する。

```bash
docker compose run --rm app mix --version
docker compose run --rm app mix precommit
docker compose run --rm app mix test
docker compose run --rm app mix setup
```

## ドキュメント

作業用の文書は `.workspace` に置く。

| パス | 内容 |
| --- | --- |
| [`.workspace/0_doc/vision.md`](.workspace/0_doc/vision.md) | 目的と設計原則 |
| [`.workspace/0_doc/architecture/overview.md`](.workspace/0_doc/architecture/overview.md) | 全体構成とアプリ境界 |
| [`.workspace/0_doc/architecture/ci-cd.md`](.workspace/0_doc/architecture/ci-cd.md) | CI / CD（GHCR・digest・ロールバック単位） |
| [`.workspace/0_doc/architecture/env/dev.md`](.workspace/0_doc/architecture/env/dev.md) | 開発環境（`app` / `db`、ポート） |
| [`.workspace/0_doc/architecture/env/prod.md`](.workspace/0_doc/architecture/env/prod.md) | 本番環境・入れ替え・backup |
| [`.workspace/0_doc/evaluation/`](.workspace/0_doc/evaluation/) | 技術選定・評価・改善提案 |
| [`.workspace/3_archive/`](.workspace/3_archive/) | 完了した ToDo（骨格・CI・本番 CD など） |
| `.workspace/1_backlog/` | まだ着手しない項目 |

## これから作るもの

- 戦略アルゴリズムの高度化

詳細は Vision と Architecture を先に読む。改善の優先順位は [improvement-plan.md](.workspace/0_doc/evaluation/improvement-plan.md)。
## 注意

- API キー、パスフレーズ、本番設定をリポジトリにコミットしない
- 開発環境の既定は `dry_run` とする。`paper` と `live` は明示する
- 本番キーに出金権限を付けない（`BITFLYER_API_*` 発行時）
- `.env` に `MIX_ENV` を書かない（品質ゲートの `preferred_envs` が効かなくなる）
