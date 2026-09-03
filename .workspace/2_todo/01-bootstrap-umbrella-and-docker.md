# ToDo: Umbrella と Docker の土台を作る

対応する要望: [elixir-umbrella-phoenix-ash.md](../1_backlog/elixir-umbrella-phoenix-ash.md)

目的は、戦略や実発注の前に、**Docker 上で Phoenix UI と Ash/PostgreSQL が動く骨格**を作ること。

作業は上から順に行う。前の完了条件を満たしてから次へ進む。

## 前提

- Docker と Compose が使える
- ホストに Elixir が入っていなくてもよい。生成と mix はコンテナ内で行う
- 本番 API キーは使わない
- 既存の Vision / Architecture を壊さない。技術選定は文書へ追記してからコードを増やす

## 手順

### 1. 文書に技術スタックを反映する

- [x] `architecture/overview.md` に Umbrella、`apps/ui`、`apps/bitflyer`、Ash、PostgreSQL を追記する
- [x] `architecture/env/dev.md` に Compose サービス（app / db）と開発用ポートを追記する
- [x] `README.md` の現状と起動案内を、骨格完成後に更新できるよう項目だけ先に決める

完了: コードを書く人が、アプリ境界と「誰が Repo を持つか」で迷わない。

### 2. リポジトリの除外規則を置く

- [x] Elixir / Mix / Phoenix 用の `.gitignore` を追加する
- [x] `.env` を無視し、`.env.example` だけを追跡する
- [x] 追跡対象外にする例: `_build/`、`deps/`、`*.ez`、DB ボリューム、秘密情報

完了: ビルド成果物と秘密情報が commit 対象にならない。

### 3. 開発用 Docker を先に置く

ホストに Mix がなくても生成できるようにする。

- [x] 開発用 `Dockerfile`（Elixir 安定版、Hex / Rebar、ソース bind mount 前提）
- [x] `compose.yaml`（または `docker-compose.yml`）
  - `db`: PostgreSQL。名前付きボリューム。開発用ポートは localhost のみ
  - `app`: Umbrella を起動する。`db` を待つ
- [x] `.env.example` に `DATABASE_URL`、`SECRET_KEY_BASE`、`PHX_HOST`、取引モード（既定 `dry_run`）を書く
- [x] `app` はソースをマウントし、再生成や `mix` をコンテナ内で実行できる

完了: 空に近いリポジトリでも `docker compose run --rm app mix --version` が通る。PostgreSQL が単体で上がる。

### 4. Umbrella を生成する

コンテナ内でリポジトリルートに生成する。既存の `.workspace/` と `README.md` は消さない。

- [ ] ルートを Umbrella にする（アプリ名は `docker_bitflyer`）
- [ ] `apps/bitflyer` を通常の OTP アプリとして追加する
- [ ] `apps/ui` を Phoenix アプリとして追加する（LiveView あり）
- [ ] `ui` の Ecto は Phoenix 既定のまま残さず、永続化は AshPostgres に寄せる
- [ ] ルートの `mix.exs` から両アプリが起動対象になる

完了: コンテナ内で `mix compile` が通る。`apps/ui` と `apps/bitflyer` が存在する。

### 5. Ash と PostgreSQL を繋ぐ

正本は `bitflyer` に置く。

- [ ] `bitflyer` に Ash、AshPostgres を入れる
- [ ] `Bitflyer.Repo`（`AshPostgres.Repo`）を `bitflyer` に置く
- [ ] `ui` に AshPhoenix を入れ、`bitflyer` を依存させる
- [ ] 開発用 Domain / Resource を 1 つだけ置く（例: ヘルス用の稼働記録、または空の `System` 系）。取引エンティティはまだ作らない
- [ ] `config/` で Repo、Ash domains、`DATABASE_URL` を環境変数から読む
- [ ] コンテナ起動時、または明示コマンドで `mix ash.setup` / マイグレーションが走る

完了: `docker compose up` 後、Ash が PostgreSQL にテーブルを作れる。`ui` から Domain を呼べる。

### 6. 起動経路を通す

- [ ] `bitflyer` の Application で Repo を起動する
- [ ] `ui` の Endpoint を開発ポートで公開する（localhost）
- [ ] 生存確認の LiveView またはページを 1 つ置く（アプリ名、取引モード、DB 接続可否）
- [ ] Compose の `app` コマンドを `mix phx.server` 相当にする
- [ ] `db` 未起動では app が Ready にならないよう depends_on / 接続リトライを付ける

完了: `docker compose up` だけで UI をブラウザで開ける。DB 停止時はページまたはログで失敗が分かる。

### 7. 動作確認

開発環境の検証として、次だけをこの ToDo の完了条件にする。

- [ ] 初回 `docker compose up --build` で UI と DB が上がる
- [ ] 生存確認ページが 200 を返す
- [ ] マイグレーション済みテーブルが PostgreSQL に存在する
- [ ] `docker compose restart app` のあと、UI と DB 接続が復帰する
- [ ] `.env` を commit していない

完了したら、このファイルを `.workspace/3_archive/` へ移し、要望側のステータスを更新する。

## 実装時の決めごと

- 生成コマンドの詳細（Igniter を使うか、`mix new --umbrella` と `phx.new` を分けるか）は、その時点の公式手順に従う。結果の境界（`bitflyer` が Repo を持つ）は変えない
- 戦略、注文 Resource、bitFlyer クライアントは次の ToDo にする
- 開発ポートとサービス名を決めたら `architecture/env/dev.md` に同じ値を書く

## 次の ToDo に残すもの

- bitFlyer REST / WebSocket クライアント
- 注文・建玉・残高の Ash Resource
- risk-manager と冪等な発注
- 本番用 Compose / イメージ
