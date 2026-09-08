# ToDo: GitHub Actions で CI を通す

ステータス: 未着手。

目的は、PR と `main` で **同じ品質ゲート**（format / compile / test）を自動実行し、壊れたコードをマージしないこと。CD や本番デプロイはこの ToDo の対象外。

作業は上から順に行う。前の完了条件を満たしてから次へ進む。

## 前提

- リモートは GitHub（`FRICK-ELDY/docker-bitflyer`）
- Umbrella 骨格（`apps/ui` / `apps/bitflyer` / Compose）は既にある
- 本番 API キーは CI に置かない。取引所への副作用も出さない
- 既存の Vision / Architecture を壊さない。CI の方針は文書へ追記してからワークフローを増やす
- ローカルと CI は同じコマンド列を使う（`mix precommit` 相当）

## 手順

### 1. 文書に CI 方針を書く

- [ ] `architecture/overview.md` または新規 `architecture/ci-cd.md` に、CI で何を保証するかを追記する
- [ ] 保証する範囲を固定する: format、warnings-as-errors の compile、`mix test`（PostgreSQL）
- [ ] 保証しない範囲を明示する: 本番イメージの配布、本番PC へのデプロイ、実発注の検証
- [ ] `README.md` に「CI が何を走らせるか」を追記できるよう項目だけ決める（本文更新は手順 6）

完了: 実装者が「CI に何を載せ、何を載せないか」で迷わない。

### 2. ローカルと CI で同じゲートを定義する

- [ ] Umbrella ルートの `mix.exs` に `precommit`（または同等の alias）を置く
- [ ] 最低限の内容: `compile --warnings-as-errors`、`format --check-formatted`（または format 後に差分なしを確認）、`test`
- [ ] `apps/ui` 側の `precommit` と重複・矛盾しないようにする（ルートから Umbrella 全体が対象になる形を優先）
- [ ] テスト用の `DATABASE_URL` / Repo 設定が `MIX_ENV=test` で動くことを確認する
- [ ] コンテナ内でもホストでも、同じ alias で通ることを確認する

完了: ローカルで `mix precommit`（または文書化した同等コマンド）が緑になる。

### 3. GitHub Actions のワークフローを置く

- [ ] `.github/workflows/ci.yml`（名前は任意だが 1 本にまとめる）を追加する
- [ ] トリガー: `pull_request` と `push` to `main`（必要なら対象ブランチを文書と同じにする）
- [ ] Elixir / OTP のバージョンは開発用 `Dockerfile`（現状 Elixir 1.18 / OTP 27 系）に合わせる
- [ ] PostgreSQL を `services:` で起動し、テストから接続できる
- [ ] キャッシュ（`deps` / `_build`）を入れてよい。壊れやすい場合は後で外す
- [ ] シークレットはテスト用 DB 接続情報だけで足りる。bitFlyer / Discord / 本番キーは入れない

完了: 空の PR でもワークフローが起動し、ジョブ定義が GitHub 上で見える。

### 4. CI ジョブの中身を通す

ジョブ内で次を順に実行する（alias にまとめてもよい）。

- [ ] `mix deps.get`
- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] 必要なら `mix ash.setup` 相当（テスト DB のマイグレーション）を test の前に走らせる
- [ ] `mix test`
- [ ] 失敗時はログだけで原因が分かること。秘密情報がログに出ないこと

任意（初期に入れてもよいが、失敗で本線を止めすぎない）:

- [ ] 開発用 `Dockerfile` の `docker build` 煙突テスト（時間が重いなら別ジョブ・`workflow_dispatch` でも可）

完了: `main` 上で CI が緑。意図的に壊した PR では赤になる。

### 5. ブランチ保護と運用の決めごと

- [ ] `main` に CI 必須チェックを掛ける方針を文書に書く（GitHub の Branch protection は権限がある人が設定）
- [ ] 「CI 赤のままマージしない」をチームルールとして README または Architecture に一文残す
- [ ] flaky になったら直すか quarantine する。黙って skip しない

完了: マージ前に何を見るかが文書と GitHub 設定の両方で説明できる。

### 6. README とアーカイブ準備

- [ ] `README.md` の現状・よく使うコマンドに、CI とローカル `precommit` を追記する
- [ ] 開発起動の記述が骨格完了前のままなら、このタイミングで事実に合わせて直す
- [ ] 完了後、このファイルを `.workspace/3_archive/` へ移す

完了: 新規参加者が「push 前に何を走らせ、CI が何を見るか」を README から辿れる。

## 実装時の決めごと

- CI は GitHub Actions を正とする。他の CI SaaS は初期スコープ外
- テストは `TRADE_MODE=dry_run` 前提。外部 API はモックまたは呼ばない
- Credo / Dialyzer は後続で足してよい。最初の完了条件には入れない
- CD（イメージ push・本番PC 更新）は [03-cd-prod-host.md](./03-cd-prod-host.md) に残す

## 完了の見方

- `.github/workflows/` に CI ワークフローがある
- PR または `main` の push で format / compile / test が自動実行される
- ルートからローカル同等のゲート（`precommit` 等）が文書化されている
- 本番シークレットが Actions secrets に入っていない
- Architecture（または `ci-cd.md`）に CI の範囲が書いてある

## 次の ToDo に残すもの

- 本番用 release イメージのビルドとレジストリ push
- 本番PC への配布と入れ替え手順（CD）
- デプロイ前後の発注停止・突合・段階再開
