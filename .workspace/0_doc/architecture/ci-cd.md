# CI / CD

CI と CD を分ける。品質ゲートは CI、配布は CD。運用の正は本文書と [env/prod.md](./env/prod.md)。

## CI が保証すること

PR と `main` への push で、ローカルと同じ品質ゲート（`mix precommit`）を自動実行する。

| 項目 | 内容 |
| --- | --- |
| 入口コマンド | `mix precommit`（Umbrella ルート。`preferred_envs: :test`） |
| format | `mix format --check-formatted`（書き換えなし） |
| compile | `mix compile --warnings-as-errors` |
| test | `mix test --warnings-as-errors`（PostgreSQL 必須） |
| 未使用 deps | `mix deps.unlock --check-unused` |
| ランタイム | Elixir / OTP は開発用 `Dockerfile`・本番 `Dockerfile.prod` と揃える（現状 1.18.3 / 27） |
| DB | GitHub Actions の `postgres:16-alpine` service。接続はジョブの `TEST_DATABASE_URL`（なければ `DATABASE_URL` から `*_test` を導出） |
| 本番イメージ | 同ワークフローの `docker-prod` で `Dockerfile.prod` を **push なし**ビルド。PR ごとにも走る（時間・Actions 分増は意図的。CD ゲートも本ジョブを含む workflow 全体を見る） |

ローカル（Compose）では次と同等とする。

```bash
docker compose run --rm app mix precommit
```

**CI が緑でも、依存の既知脆弱性が無いことは保証しない。** 下節の deps audit はゲート外の可視化である。

## CI が可視化すること（ゲート外）

`mix deps.audit`（`mix_audit`）を品質ゲートとは別に実行する。現状は `continue-on-error: true` のため、脆弱性があってもジョブは緑のまま。

| 項目 | 内容 |
| --- | --- |
| コマンド | `mix deps.audit --format=json`（1 回のみ） |
| ジョブへの影響 | 落とさない（ステップは黄になり得る） |
| 成果物 | artifact `deps-audit-report`（`deps-audit.json` / `deps-audit.stderr` / `deps-audit-meta.txt`） |
| ローカル再現 | `docker compose run --rm app mix deps.audit` |

`deps-audit-meta.txt` の `outcome` で次を区別する（`json_exit=0` かつ `"pass":true` のときだけ `clean`）。

- `clean` — 既知脆弱性なし（タスク成功）
- `vulnerabilities_found` — advisory 検出（レポートを読む）
- `audit_tool_or_fetch_failed` — タスク未定義・コンパイル失敗・advisory 取得失敗など（ログ / stderr を見る）

### ツール限界

- `mix_audit` は **Hex パッケージの既知 advisory** が対象
- GitHub タグ依存（例: `apps/ui` の `heroicons` / `daisyui`）はスキャン対象外。タグ固定のレビューと更新判断は人手

## CD が保証すること

承認された参照から **本番用 release イメージ** を GHCR に載せ、本番PC が pull して入れ替えられるようにする。`main` マージ alone では実弾デプロイしない。

| 項目 | 内容 |
| --- | --- |
| 成果物 | `Dockerfile.prod` でビルドした Umbrella release（`docker_bitflyer`）。非 root・assets digest 込み |
| レジストリ | GitHub Container Registry（`ghcr.io/<owner>/<repo>`） |
| トリガー | 明示タグ `v*`、または `workflow_dispatch`（GitHub Environment `production`） |
| CI 前提 | **対象 SHA の最新 `ci.yml` run が workflow 全体 success**（`mix precommit` + `docker-prod`）。過去の success は見ない。未完了・失敗なら push しない（**自動 wait なし**・完了後に CD 再実行） |
| タグ | semver / `sha-<short>`。Compose では **digest 固定**（`APP_IMAGE=...@sha256:...`）を推奨 |
| ロールバック単位 | 直前の `APP_IMAGE`（digest）へ戻して `compose up -d` |
| ワークフロー | [`.github/workflows/cd.yml`](../../../.github/workflows/cd.yml) |

VLAN3（作業用）→ VLAN1（本番）の到達は最小ポートのみ（Vision の Least privilege）。

## CI / CD が保証しないこと

- 本番PC への自動実弾デプロイ（人が pull / 入れ替えする）
- bitFlyer / Discord など外部 API への実呼び出し
- 依存の既知脆弱性が無いこと（deps audit は可視化のみ。現状 fail させない）
- GitHub 依存（`heroicons` / `daisyui` 等）の脆弱性スキャン
- Credo / Dialyzer（後続で足してよい）

## 秘密情報

- Actions secrets に bitFlyer・Discord・本番キーを置かない
- テスト用はジョブ内の非秘密な `DATABASE_URL` と `TRADE_MODE=dry_run` で足りる
- 本番シークレットはホストの `.env.prod` のみ。イメージ・Git・CI ログに出さない
- 失敗ログにシークレットを出さない

## 運用ルール

- **CI が赤のまま `main` へマージしない**（`ci.yml` 全体: `mix precommit` + `Dockerfile.prod` ビルド検証）
- **CD は対象 SHA の最新 CI run の success を前提とする**。未完了・失敗ならすぐ失敗し、自動では待たない（CI 完了後に CD を再実行）
- deps audit の黄ステップ / artifact はマージ前に目視する運用とする（ゲート化は後続）
- `main` には CI 必須チェック（Branch protection）を掛ける方針とする。GitHub 上の設定は権限がある人が行う
- CD の GitHub Environment `production` にレビュー必須を付けられるなら付ける
- flaky テストは直すか quarantine する。黙って skip しない
- watchtower 等の自動最新追従は、発注停止ゲートなしでは採用しない

## ワークフロー

| ファイル | 役割 |
| --- | --- |
| [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) | `pull_request` / `push` to `main` → `mix precommit` + deps audit（可視化）+ `Dockerfile.prod` ビルド検証（push なし。PR でも走る＝コスト増は意図的） |
| [`.github/workflows/cd.yml`](../../../.github/workflows/cd.yml) | `v*` タグ / 手動 → **最新** `ci.yml` が success の SHA のみ GHCR push |

ソースの改行は LF 固定（`.gitattributes`）。Windows で CRLF にすると `format --check-formatted` が落ちる。
