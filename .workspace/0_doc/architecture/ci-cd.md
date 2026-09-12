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
| Hex advisory | 別ジョブ `deps-audit`。`mix deps.audit` が `"pass":false` のときだけ落とす。ツール/取得障害は落とさない |

ローカル（Compose）では次と同等とする。

```bash
docker compose run --rm app mix precommit
```

**CI が緑でも、GitHub タグ依存や Actions 以外の供給網に既知脆弱性が無いことは保証しない。** Hex advisory は下節の別ジョブが検出時だけ落とす。

## deps.audit ゲート（precommit から分離）

`mix deps.audit`（`mix_audit`）は `mix precommit` に入れない。CI の別ジョブ `deps-audit` で 1 回だけ回す。分類は `bin/classify-deps-audit.sh`。

| 項目 | 内容 |
| --- | --- |
| コマンド | `mix deps.audit --format=json`（1 回のみ） |
| ジョブへの影響 | `"pass":false`（advisory 検出）だけ失敗。ツール/取得障害は warning で成功 |
| 成果物 | artifact `deps-audit-report`（`deps-audit.json` / `deps-audit.stderr` / `deps-audit-meta.txt`） |
| ローカル再現 | `docker compose run --rm app mix deps.audit` |

`deps-audit-meta.txt` の `outcome` で次を区別する（`json_exit=0` かつ `"pass":true` のときだけ `clean`）。

- `clean` — 既知脆弱性なし（ジョブ成功）
- `vulnerabilities_found` — advisory 検出（ジョブ失敗。CD しない）
- `audit_tool_or_fetch_failed` — タスク未定義・コンパイル失敗・advisory 取得失敗など（ジョブは成功。artifact を目視）

### ツール限界

- `mix_audit` は **Hex パッケージの既知 advisory** が対象
- GitHub タグ依存（例: `apps/ui` の `heroicons` / `daisyui`）はスキャン対象外。Dependabot の mix PR と人手レビュー
- Docker イメージ（CI の `postgres:16-alpine`、`Dockerfile` / `compose.yaml` のベース）はゲート外。Dependabot も今は `mix` と `github-actions` のみ
- Actions は commit SHA 固定。Dependabot `github-actions` が SHA と版コメントを更新する

## CD が保証すること

承認された参照から **本番用 release イメージ** を GHCR に載せ、本番PC が pull して入れ替えられるようにする。`main` マージ alone では実弾デプロイしない。

| 項目 | 内容 |
| --- | --- |
| 成果物 | `Dockerfile.prod` でビルドした Umbrella release（`docker_bitflyer`）。非 root・assets digest 込み |
| レジストリ | GitHub Container Registry（`ghcr.io/<owner>/<repo>`） |
| トリガー | 明示タグ `v*`、または `workflow_dispatch`（GitHub Environment `production`） |
| CI 前提 | **対象 SHA の最新 `ci.yml` run が workflow 全体 success**（`precommit` + `deps-audit` + `docker-prod`）。過去の success は見ない。未完了・失敗なら push しない（**自動 wait なし**・完了後に CD 再実行） |
| タグ | semver / `sha-<short>`。Compose では **digest 固定**（`APP_IMAGE=...@sha256:...`）を推奨 |
| ロールバック単位 | 直前の `APP_IMAGE`（digest）へ戻して `compose up -d` |
| ワークフロー | [`.github/workflows/cd.yml`](../../../.github/workflows/cd.yml) |

VLAN3（作業用）→ VLAN1（本番）の到達は最小ポートのみ（Vision の Least privilege）。

## CI / CD が保証しないこと

- 本番PC への自動実弾デプロイ（人が pull / 入れ替えする）
- bitFlyer / Discord など外部 API への実呼び出し（公開 GET 契約も CI では叩かない。人が `mix bitflyer.contract`。オフライン意味論は `mix bitflyer.contract --corpus` / `Contract.check_corpus`）
- GitHub 依存（`heroicons` / `daisyui` 等）に既知脆弱性が無いこと（Hex advisory 以外。Dependabot は更新 PR のみ）
- Docker イメージ（`postgres:16-alpine` 等）に既知脆弱性が無いこと
- audit ツール障害時に「今 Hex advisory が無い」こと（そのときはジョブを落とさない）
- Credo / Dialyzer（後続で足してよい）

## 秘密情報

- Actions secrets に bitFlyer・Discord・本番キーを置かない
- テスト用はジョブ内の非秘密な `DATABASE_URL` と `TRADE_MODE=dry_run` で足りる
- 本番シークレットはホストの `.env.prod` のみ。イメージ・Git・CI ログに出さない
- 失敗ログにシークレットを出さない

## 運用ルール

- **CI が赤のまま `main` へマージしない**（`ci.yml` 全体: `mix precommit` + `deps-audit` + `Dockerfile.prod` ビルド検証）
- **CD は対象 SHA の最新 CI run の success を前提とする**。未完了・失敗ならすぐ失敗し、自動では待たない（CI 完了後に CD を再実行）
- `deps-audit` が `audit_tool_or_fetch_failed` のときは artifact を目視してからマージする（ジョブは緑）
- `main` の必須チェック（Branch protection）に次を含める。GitHub 上の設定は権限がある人が行う。**必須にしないと `deps-audit` 赤のまま merge でき、CD だけが拒む**
  - `mix precommit`
  - `mix deps.audit`
  - `Build Dockerfile.prod (no push)`
- CD の GitHub Environment `production` にレビュー必須を付けられるなら付ける
- flaky テストは直すか quarantine する。黙って skip しない
- watchtower 等の自動最新追従は、発注停止ゲートなしでは採用しない

## ワークフロー

| ファイル | 役割 |
| --- | --- |
| [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) | `pull_request` / `push` to `main` → `mix precommit` + `deps-audit`（advisory 検出時のみ fail）+ `Dockerfile.prod` ビルド検証（push なし。PR でも走る＝コスト増は意図的） |
| [`.github/dependabot.yml`](../../../.github/dependabot.yml) | 週次。`mix` と `github-actions`（SHA pin 維持） |
| [`.github/workflows/cd.yml`](../../../.github/workflows/cd.yml) | `v*` タグ / 手動 → **最新** `ci.yml` が success の SHA のみ GHCR push |

ソースの改行は LF 固定（`.gitattributes`）。Windows で CRLF にすると `format --check-formatted` が落ちる。
