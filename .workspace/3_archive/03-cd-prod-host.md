# ToDo: 本番ホスト向け CD を組み込む

対応する前段: [02-ci-github-actions.md](./02-ci-github-actions.md)

ステータス: 完了。`.workspace/3_archive/` へ移す。

目的は、承認済みの成果物を **本番PC（単一ホスト・Compose）** へ安全に届け、入れ替え後も資金を守る経路を文書と手順で固定すること。PR ごとの自動実弾デプロイはしない。

作業は上から順に行う。前の完了条件を満たしてから次へ進む。

## 前提

- [Vision の本番環境](../0_doc/vision.md) と [env/prod.md](../0_doc/architecture/env/prod.md) を正とする
- 本番は VLAN1 の本番PC。作業用PC から監視・デプロイする
- CI で format / compile / test が通っていること
- 本番 API キー・Webhook 等はホスト側シークレットのみ。Git・イメージ・CI ログに出さない
- 初回 CD の検証は `dry_run` または発注停止状態で行う。`live` 解禁は別判断

## 手順

### 1. 文書に CD 方針を書く

- [x] `architecture/ci-cd.md` に CD の流れを追記する
- [x] 配布の形を固定する: **CI が本番用イメージをビルド → コンテナレジストリへ push → 本番PC が pull して Compose で入れ替え**
- [x] トリガーを固定する: `main` へのマージだけでは実弾を動かさない。明示タグ（例: `v*`）または手動承認を必須にする
- [x] ロールバックの単位（前イメージタグへ戻す）を一文で書く
- [x] VLAN3 → VLAN1 の到達は最小ポートのみ、と Vision の Least privilege に合わせる旨を残す

完了: 「何が成果物で、誰がいつ本番を更新するか」が文書だけで説明できる。

### 2. 本番用イメージを定義する

- [x] 本番用 `Dockerfile.prod` を追加する
- [x] `MIX_ENV=prod` の release をビルドする（`releases: [docker_bitflyer: ...]`）
- [x] ソースの bind mount に依存しない
- [x] assets の minify / digest が release に含まれる
- [x] イメージに `.env`・API キー・`SECRET_KEY_BASE` を焼かない
- [x] ベースの Elixir / OS バージョンを CI・開発と揃える（1.18.3 / 27）

完了: ローカルまたは CI で本番用イメージがビルドでき、コンテナ単体で起動コマンドが定義されている。

### 3. 本番用 Compose を置く

- [x] `compose.prod.yaml` を追加する
- [x] サービスは開発と同じ境界（`app` / `db`）を維持
- [x] ホストへの公開は最小（`127.0.0.1:4000`、DB は expose のみ）
- [x] UI BasicAuth 必須 + `PHX_HTTP_IP` 方針を Compose / prod.md に固定
- [x] `db` は名前付きボリューム。バックアップは `bin/backup-db.sh` + prod.md
- [x] `APP_IMAGE` でタグ / digest 参照（未設定時のみローカル build）
- [x] `.env.example` に本番 Compose 用の注記を追加

完了: シークレットをホストに置いた前提で、Compose ファイルだけ見れば起動構成が追える。

### 4. CI からレジストリへ push する

- [x] `.github/workflows/cd.yml`（test ジョブとは分離）
- [x] レジストリは GHCR
- [x] push 条件: `v*` または `workflow_dispatch` + Environment `production`
- [x] イメージタグに SHA / semver
- [x] `GITHUB_TOKEN` で GHCR（長期 PAT をリポジトリに書かない）

完了: 承認された参照から、追跡可能なタグのイメージがレジストリに存在する。

### 5. 本番PC 側の入れ替え手順を固定する

- [x] `prod.md` に事前 / 停止 / pull / up / 突合 / 再開 / ロールバックを記載
- [x] `bin/deploy-prod.sh`（deploy / rollback）
- [x] スクリプトは発注停止の確認なしに `live` を再開しない

完了: 人一人が文書どおりに追えば、作業用PC から本番を更新できる。

### 6. 安全装置と検証（実弾なしで先に通す）

- [x] 手順とスクリプトを用意（ローカルで `compose.prod` を一度上げる）
- [x] ロールバック手順を同じ文書・スクリプトに固定
- [x] Discord は既存アダプタ。デプロイ通知は後続でよい（ログで代替可）
- [x] `live` 解禁チェックリストを `prod.md` に短く置く

完了: 実弾なしで「配る → 入れ替える → 戻す」が文書とスクリプトで追える。

### 7. README とアーカイブ準備

- [x] `README.md` に本番デプロイへのポインタ
- [x] 開発用と本番用の Compose / Dockerfile の見分けを README に書く
- [x] 完了後、このファイルを `.workspace/3_archive/` へ移す

## 実装時の決めごと

- 初期は単一ホスト Compose。Kubernetes や複数ホストは対象外
- `apps/ui` と `apps/bitflyer` のリリース分割はしない
- watchtower 等の自動最新追従は、発注停止ゲートなしでは採用しない
- ペーパー取引や戦略本体はこの ToDo で作らない

## 完了の見方

- 本番用 Dockerfile と Compose がある
- 承認付きの経路でイメージがレジストリに載る（workflow 定義済み）
- 本番PC での pull / 入れ替え / ロールバック手順が文書化されている
- `main` マージ alone では実弾デプロイが走らない
- シークレットが Git・イメージ・CI ログに出ていない
