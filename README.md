# docker-bitflyer

Docker で 24 時間 365 日動かす、bitFlyer 自動売買システム。

人が常時監視しなくても、市場データの取得・戦略判定・リスク検査・発注・再起動後の復帰までを回し続ける。利益より、想定外の損失を止めることを優先する。

Elixir Umbrella（`apps/ui` Phoenix / `apps/bitflyer` Ash）と PostgreSQL を Compose で起動する。

## 現状

技術スタックとアプリ境界を文書で固定した段階。実装は [ToDo 手順 2 以降](.workspace/2_todo/01-bootstrap-umbrella-and-docker.md) で進める。

起動手順の本文は、骨格（手順 6）が通ってからこの README に移す。

## 開発起動

（未実装。`docker compose up` の手順をここに書く。）

## 環境変数

（未実装。`.env.example` をここに要約する。）

名前だけ先に固定する: `DATABASE_URL`、`SECRET_KEY_BASE`、`PHX_HOST`、`TRADE_MODE`（既定 `dry_run`）。値は Git に入れない。

## よく使う mix

（未実装。コンテナ内で使う `mix` をここに書く。）

## ドキュメント

作業用の文書は `.workspace` に置く。

| パス | 内容 |
| --- | --- |
| [`.workspace/0_doc/vision.md`](.workspace/0_doc/vision.md) | 目的と設計原則 |
| [`.workspace/0_doc/architecture/overview.md`](.workspace/0_doc/architecture/overview.md) | 全体構成とアプリ境界 |
| [`.workspace/0_doc/architecture/env/dev.md`](.workspace/0_doc/architecture/env/dev.md) | 開発環境（`app` / `db`、ポート） |
| [`.workspace/0_doc/architecture/env/prod.md`](.workspace/0_doc/architecture/env/prod.md) | 本番環境 |
| [`.workspace/0_doc/evaluation/tech-stack.md`](.workspace/0_doc/evaluation/tech-stack.md) | 技術選定の評価 |
| [`.workspace/2_todo/01-bootstrap-umbrella-and-docker.md`](.workspace/2_todo/01-bootstrap-umbrella-and-docker.md) | 今の ToDo |
| `.workspace/1_backlog/` | まだ着手しない項目 |
| `.workspace/3_archive/` | 完了・破棄した項目 |

## これから作るもの

- Compose による開発 / 本番の起動一式
- 市場データ、戦略、リスク、発注、永続化の各コンポーネント
- 秘密情報を Git に入れない実行手順

詳細は Vision と Architecture を先に読む。

## 注意

- API キー、パスフレーズ、本番設定をリポジトリにコミットしない
- 開発環境の既定は `dry_run` とする。`paper` と `live` は明示する
- 本番キーに出金権限を付けない
