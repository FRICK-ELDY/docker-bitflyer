# CI / CD

CI と CD を分ける。この文書の当面の正本は **CI**。CD（本番イメージ配布・本番PC 更新）は [ToDo 03](../../2_todo/03-cd-prod-host.md) と [env/prod.md](./env/prod.md) に残す。

## CI が保証すること

PR と `main` への push で、ローカルと同じ品質ゲートを自動実行する。

| 項目 | 内容 |
| --- | --- |
| 入口コマンド | `mix precommit`（Umbrella ルート。`preferred_envs: :test`） |
| format | `mix format --check-formatted`（書き換えなし） |
| compile | `mix compile --warnings-as-errors` |
| test | `mix test --warnings-as-errors`（PostgreSQL 必須） |
| 未使用 deps | `mix deps.unlock --check-unused` |
| ランタイム | Elixir / OTP は開発用 `Dockerfile` と揃える（現状 1.18.3 / 27） |
| DB | GitHub Actions の `postgres:16-alpine` service。接続はジョブの `TEST_DATABASE_URL`（なければ `DATABASE_URL` から `*_test` を導出） |

ローカル（Compose）では次と同等とする。

```bash
docker compose run --rm app mix precommit
```

## CI が保証しないこと

- 本番イメージのビルド・レジストリ push
- 本番PC へのデプロイ・入れ替え
- bitFlyer / Discord など外部 API への実呼び出し
- Credo / Dialyzer / deps audit（後続で足してよい）

## 秘密情報

- Actions secrets に bitFlyer・Discord・本番キーを置かない
- テスト用はジョブ内の非秘密な `DATABASE_URL` と `TRADE_MODE=dry_run` で足りる
- 失敗ログにシークレットを出さない

## 運用ルール

- **CI が赤のまま `main` へマージしない**
- `main` には CI 必須チェック（Branch protection）を掛ける方針とする。GitHub 上の設定は権限がある人が行う
- flaky テストは直すか quarantine する。黙って skip しない

## ワークフロー

定義は [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml)。トリガーは `pull_request` と `push` to `main`。

ソースの改行は LF 固定（`.gitattributes`）。Windows で CRLF にすると `format --check-formatted` が落ちる。
