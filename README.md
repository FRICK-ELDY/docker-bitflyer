# docker-bitflyer

Docker で 24 時間 365 日動かす、bitFlyer 自動売買システム。

人が常時監視しなくても、市場データの取得・戦略判定・リスク検査・発注・再起動後の復帰までを回し続ける。利益より、想定外の損失を止めることを優先する。

Elixir Umbrella（`apps/ui` Phoenix / `apps/bitflyer` Ash）と PostgreSQL を Compose で起動する。

## 現状

開発用の骨格は動く。

- `docker compose up -d` で `app`（Phoenix）と `db`（PostgreSQL）が上がる
- UI は `http://127.0.0.1:4000/`（稼働確認用 Status。取引 UI ではない）
- 稼働 API: `GET /health/live`（プロセス生存・Compose healthcheck）、`GET /health/ready`（DB + Ready + Feed/鮮度。WS 断検知）、`GET /health`（従来互換）
- 品質ゲートはローカルも CI も `mix precommit`
- `.dockerignore` で `.env` / `_build` / `deps` 等をビルドコンテキストから除外（本番イメージへの混入防止）
- 市場データ・戦略・リスク・発注の engine は未実装（`TRADE_MODE` の既定は `dry_run`）

完了した骨格作業は [3_archive/01-bootstrap-umbrella-and-docker.md](.workspace/3_archive/01-bootstrap-umbrella-and-docker.md)。次の本番配布は [2_todo/03-cd-prod-host.md](.workspace/2_todo/03-cd-prod-host.md)。

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

## 品質ゲート

コミット前・PR 前に、ローカルで次を緑にする。

```bash
docker compose run --rm app mix precommit
```

中身は format チェック / warnings-as-errors の compile / test（両アプリ）。`MIX_ENV` は Compose に固定しない（`.env` にも書かない）。`preferred_envs` が `precommit` を `:test` にする。

`ash.setup` は常駐起動（`phx.server`）時だけ走り、対象は開発用 DB（`docker_bitflyer_dev`）。テストは別 DB（既定 `docker_bitflyer_test`）を使うため、初回やマイグレーション追加のあとは先に次を実行する。

```bash
docker compose run --rm -e MIX_ENV=test app mix ash.setup --domains Bitflyer.System,Bitflyer.Trading
```

（上書きしたいときは `TEST_DATABASE_URL` を設定する。CI はジョブ内で setup してから `precommit` する。）

GitHub Actions も同じ `mix precommit` を PR と `main` で実行する。範囲の詳細は [architecture/ci-cd.md](.workspace/0_doc/architecture/ci-cd.md)。**CI が赤のまま `main` へマージしない。**

## 環境変数

`.env.example` をコピーして使う。追跡するのは example だけ。

| 名前 | 既定の意味 |
| --- | --- |
| `DATABASE_URL` | Compose 内ホスト `db` 向け（開発用 DB） |
| `TEST_DATABASE_URL` | 任意。未設定時は `DATABASE_URL` の DB 名を `*_test` に寄せる |
| `SECRET_KEY_BASE` | Phoenix 用（後で生成し直す） |
| `PHX_HOST` | `localhost` |
| `TRADE_MODE` | `dry_run` |
| `DISCORD_WEBHOOK_URL` | 任意。Discord Incoming Webhook。未設定でも起動する |

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
| [`.workspace/0_doc/architecture/ci-cd.md`](.workspace/0_doc/architecture/ci-cd.md) | CI が保証すること / しないこと |
| [`.workspace/0_doc/architecture/env/dev.md`](.workspace/0_doc/architecture/env/dev.md) | 開発環境（`app` / `db`、ポート） |
| [`.workspace/0_doc/architecture/env/prod.md`](.workspace/0_doc/architecture/env/prod.md) | 本番環境 |
| [`.workspace/0_doc/evaluation/`](.workspace/0_doc/evaluation/) | 技術選定・評価・改善提案 |
| [`.workspace/2_todo/03-cd-prod-host.md`](.workspace/2_todo/03-cd-prod-host.md) | 今の ToDo（本番 CD） |
| [`.workspace/3_archive/`](.workspace/3_archive/) | 完了した ToDo（骨格・CI など） |
| `.workspace/1_backlog/` | まだ着手しない項目 |

## これから作るもの

- 市場データ、戦略、リスク、発注、永続化の各コンポーネント
- 本番用 release / Compose と配備手順（[ToDo 03](.workspace/2_todo/03-cd-prod-host.md)）
- 秘密情報を Git に入れない本番実行手順

詳細は Vision と Architecture を先に読む。改善の優先順位は [improvement-plan.md](.workspace/0_doc/evaluation/improvement-plan.md)。

## 注意

- API キー、パスフレーズ、本番設定をリポジトリにコミットしない
- 開発環境の既定は `dry_run` とする。`paper` と `live` は明示する
- 本番キーに出金権限を付けない
- `.env` に `MIX_ENV` を書かない（品質ゲートの `preferred_envs` が効かなくなる）
