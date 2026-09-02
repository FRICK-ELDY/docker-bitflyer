# docker-bitflyer

Docker で 24 時間 365 日動かす、bitFlyer 自動売買システム。

人が常時監視しなくても、市場データの取得・戦略判定・リスク検査・発注・再起動後の復帰までを回し続ける。利益より、想定外の損失を止めることを優先する。

## 現状

初期ドキュメントを置いた段階。実装はこれから。

## ドキュメント

作業用の文書は `.workspace` に置く。

| パス | 内容 |
| --- | --- |
| [`.workspace/0_doc/vision.md`](.workspace/0_doc/vision.md) | 目的と設計原則 |
| [`.workspace/0_doc/architecture/overview.md`](.workspace/0_doc/architecture/overview.md) | 全体構成 |
| [`.workspace/0_doc/architecture/env/dev.md`](.workspace/0_doc/architecture/env/dev.md) | 開発環境 |
| [`.workspace/0_doc/architecture/env/prod.md`](.workspace/0_doc/architecture/env/prod.md) | 本番環境 |
| `.workspace/0_doc/evaluation/` | 評価メモ |
| `.workspace/1_backlog/` | まだ着手しない項目 |
| `.workspace/2_todo/` | 今やる項目 |
| `.workspace/3_archive/` | 完了・破棄した項目 |

## これから作るもの

- Compose による開発 / 本番の起動一式
- 市場データ、戦略、リスク、発注、永続化の各コンポーネント
- 秘密情報を Git に入れない実行手順

詳細は Vision と Architecture を先に読む。

## 注意

- API キー、パスフレーズ、本番設定をリポジトリにコミットしない
- 開発環境の既定は dry-run / paper とする
- 本番キーに出金権限を付けない
