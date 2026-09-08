# docker-bitflyer 第2評価者 プラス点（2026-09-08）

## 採点基準

| 点数 | 基準 |
|:---:|---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティスに沿う良い設計 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る |
| +4 | プロダクションレベルと比べても遜色ない |
| +5 | 個人プロジェクトとして卓越している |

## プロジェクト全体設計

### Vision / Architecture

- **資金保全を中心に据えた設計原則が具体的である** `+3`
  > Vision は Safety first、Recoverable、Observable、Environment split、Least privilege、Idempotent actions を明文化し（`vision.md:31-38`）、Architecture は「復元→取引所突合→不整合時停止→購読→Ready」という順序まで固定している（`overview.md:122-129`）。単なる技術選定ではなく、障害時の安全側挙動を検証可能な要求へ落としている点は同規模の初期プロジェクトを明確に上回る。
  >
  > 対象ファイル: `.workspace/0_doc/vision.md`, `.workspace/0_doc/architecture/overview.md`

## apps/bitflyer

### アプリ境界

- **UI から取引ドメインへの一方向依存をビルド構成で表している** `+2`
  > `apps/ui/mix.exs:47-49` は `{:bitflyer, in_umbrella: true}` を宣言する一方、`apps/bitflyer/mix.exs:27-31` は UI に依存しない。取引所連携・Repo の正本を `bitflyer` に閉じる Architecture の依存方向をコード上でも維持している。
  >
  > 対象ファイル: `apps/ui/mix.exs`, `apps/bitflyer/mix.exs`

### datastore / Ash

- **Repo の所有権を bitflyer に限定している** `+2`
  > `Bitflyer.Repo` は `AshPostgres.Repo` として `apps/bitflyer/lib/bitflyer/repo.ex:1-12` に置かれ、`Bitflyer.Application` が直接監督する（`application.ex:8-17`）。UI 側に重複 Repo を置かない境界は明快である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

- **Ash と PostgreSQL の最小疎通経路が実装されている** `+1`
  > Heartbeat Resource は Ash Domain、AshPostgres DataLayer、専用 Repo、UUID v7、UTC タイムスタンプを一貫して定義している（`heartbeat.ex:1-29`）。対応マイグレーションも存在し（`20260904092539_add_heartbeats.exs:10-27`）、骨格段階の永続化接続として成立している。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`, `apps/bitflyer/priv/repo/migrations/20260904092539_add_heartbeats.exs`

## apps/ui

### Phoenix / LiveView

- **UI の責務を運用ステータスに限定している** `+2`
  > StatusLive はアプリ名、取引モード、DB 接続状態だけを表示し（`status_live.ex:24-97`）、bitFlyer API や裁量発注機能を持たない。Vision の非目標「裁量トレード用の高機能 UI」に踏み込んでいない。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **DB 障害を LiveView 自体のクラッシュにせず可視化する** `+1`
  > `Bitflyer.System.check_database/0` は SQL の `{:error, _}`、例外、Repo 未起動の exit をエラー値へ変換し（`system.ex:12-25`）、StatusLive は5秒ごとに再評価して unavailable と理由を表示する（`status_live.ex:100-118`）。基礎的だが運用画面として安全な失敗の見せ方である。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

## 実行基盤 / 設定

### Docker Compose

- **開発用の公開面と再起動設定が堅実である** `+2`
  > Compose は UI と PostgreSQL を `127.0.0.1` のみに公開し（`compose.yaml:3-5,20-24`）、DB healthcheck、`depends_on: condition: service_healthy`、app の `restart: unless-stopped` を備える（`compose.yaml:13-17,27,45-48`）。秘密情報をイメージへ COPY しない bind-mount 開発構成も明示されている。
  >
  > 対象ファイル: `compose.yaml`, `Dockerfile`

### config / secrets

- **取引モードの既定値が dry_run で一貫している** `+2`
  > runtime 設定は `TRADE_MODE` 未設定時に `"dry_run"` を採用し（`runtime.exs:42-44`）、Compose と `.env.example` も同じ既定を示す（`compose.yaml:34-38`, `.env.example:8-9`）。意図せず live になる既定値ではない。
  >
  > 対象ファイル: `config/runtime.exs`, `compose.yaml`, `.env.example`

- **秘密情報を実行時注入し、追跡対象外にしている** `+2`
  > 本番 `SECRET_KEY_BASE` と DB URL は runtime で必須化され（`runtime.exs:10-16,84-89`）、`.gitignore:30-40` は `.env`、鍵、secrets、credentials を除外し `.env.example` だけを許可する。Dockerfile に値を焼く処理もない。
  >
  > 対象ファイル: `config/runtime.exs`, `.gitignore`, `Dockerfile`

- **本番向け HTTPS 強制の基礎設定がある** `+1`
  > `prod.exs:10-20` は proxy の `x-forwarded-proto` を考慮した `force_ssl` と HSTS を有効化している。公開方式は未完成だが Phoenix 側の通信保護の既定は安全側である。
  >
  > 対象ファイル: `config/prod.exs`

## 横断品質

### テスト

- **LiveView テストが主要 DOM ID と利用者向け結果を検証する** `+1`
  > `status_live_test.exs:6-28` は `#app-name`、`#trade-mode`、`#db-status-label`、言語切替後の画面結果を `has_element?/3` で確認する。文字列全体や内部関数へ過度に結合せず、現状 UI の回帰として妥当である。
  >
  > 対象ファイル: `apps/ui/test/ui_web/live/status_live_test.exs`

### 開発者体験

- **コンテナ内でホスト非依存に開発できるバージョン固定がある** `+1`
  > `Dockerfile:2-15` は Elixir 1.18.3 / OTP 27 を固定し、Hex・Rebar・PostgreSQL client を用意する。`docker compose config --quiet` も 2026-09-08 の評価環境で成功した。
  >
  > 対象ファイル: `Dockerfile`, `compose.yaml`

**加点合計: +20**
