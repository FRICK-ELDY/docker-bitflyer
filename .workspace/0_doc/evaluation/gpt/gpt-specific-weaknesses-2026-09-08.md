# docker-bitflyer 第2評価者 マイナス点（2026-09-08）

## 採点基準

| 点数 | 基準 |
|:---:|---|
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | バグ・損失・二重発注・不整合を起こしうる欠陥 |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的欠如 |

## apps/bitflyer

### market-data / strategy

- **市場データ取得・再接続・鮮度ゲートがない** `-4`
  > `Bitflyer.Application` の子は Repo だけである（`application.ex:8-17`）。REST / WebSocket 購読、正規化、再接続、穴埋め、stale 判定がなく、Architecture の「古いデータでは発注しない」（`overview.md:35-36,139-140`）を保証できない。
  >
  > 改善方針: Req による REST client と WebSocket adapter を分け、取引所時刻と受信時刻を持つイベントを ETS へ保存し、stale を risk の拒否理由へ直結する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

- **取引所非依存の戦略コマンド境界がない** `-2`
  > 現行実装は System、Heartbeat、Repo が中心で、「買いたい / 売りたい / 閉じたい」という内部 command がない。戦略内容が後続でも、strategy が API を直接呼べない境界をまだ検証できない。
  >
  > 改善方針: Decimal の価格・数量、side、intent ID、戦略パラメータ版を持つ command と behaviour を定義し、出力先を risk-manager のみに限定する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer.ex`

### risk-manager / order-executor

- **Safety first を執行するリスク管理がない** `-5`
  > Vision はポジション、損失、発注頻度、異常値超過時の停止を必須とする（`vision.md:13-18`）が、サイズ、日次損失、価格逸脱、残高、時計ずれ、鮮度の検査もサーキット永続化もない。実発注を足した時点で無防備になる根幹的欠如である。
  >
  > 改善方針: fail-closed の単一 `authorize/2` 境界を作り、ハードリミットと停止状態を永続化する。未同期・stale・時計ずれは必ず拒否する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **冪等発注・取消・モード別出口がない** `-5`
  > `TRADE_MODE` は文字列を表示するだけで（`system.ex:28-33`）、executor、内部注文 ID、取引所注文 ID、重複排除、未確定注文突合がない。Architecture の共通経路と出口切替（`overview.md:99-108,131-137`）は未実装である。
  >
  > 改善方針: 内部注文 ID に一意制約を置く状態機械と dry_run / paper / live adapter を実装し、paper と dry_run から private order API が呼ばれない契約テストを固定する。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/system.ex`

### datastore / cache

- **復旧に必要な永続状態が Heartbeat 以外にない** `-4`
  > Ash Domain の Resource は Heartbeat だけである（`system.ex:6-10`）。注文、建玉、残高、リスク停止、パラメータ履歴という最低要件（`overview.md:112-120`）を保存できず、再起動後に取引状態を復元できない。
  >
  > 改善方針: Order、Position、BalanceSnapshot、RiskHalt、StrategyParameterRevision を Decimal・一意制約・許可状態遷移とともに永続化する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`, `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`

- **鮮度付き ETS cache と再構築経路がない** `-3`
  > Application の監督下に ETS owner がなく（`application.ex:8-17`）、市場データの age、stale、再購読を管理できない。
  >
  > 改善方針: 専用 owner が protected ETS を所有し、source timestamp と monotonic receipt time を保存する。消失時は発注不可のまま snapshot 取得後に Ready へ遷移する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`

### observe / OTP

- **取引イベントの可観測性がない** `-3`
  > Logger metadata は request ID のみ（`config/config.exs:62-65`）、Telemetry は Phoenix / VM の雛形だけである（`telemetry.ex:21-59`）。切断、拒否、注文、突合、サーキットの event / reporter / alert がない。
  >
  > 改善方針: 各境界で telemetry と構造化ログを発行し、秘密値は allowlist で除外する。通知 adapter は取引監督と兄弟にして非同期化する。
  >
  > 対象ファイル: `config/config.exs`, `apps/ui/lib/ui_web/telemetry.ex`

- **安全な起動・復元・停止シーケンスがない** `-4`
  > entrypoint は DB 待ちと `ash.setup` 後に Phoenix を起動するだけである（`bin/docker-entrypoint.sh:12-42`）。取引所突合、不整合時停止、鮮度確認、Ready 化、グレースフルな発注停止はない。
  >
  > 改善方針: `restoring → reconciling → syncing_market → ready / halted` の boot state machine を監督し、shutdown 時は新規受付を閉じて書込み完了を待つ。
  >
  > 対象ファイル: `bin/docker-entrypoint.sh`, `apps/bitflyer/lib/bitflyer/application.ex`

## apps/ui

### 運用操作性 / 公開面

- **「今トレードしてよいか」と停止理由が分からない** `-2`
  > StatusLive は mode と DB 接続だけを表示する（`status_live.ex:69-94,100-113`）。DB connected でも stale、未突合、サーキット open なら取引不可だが区別できない。
  >
  > 改善方針: 公開 query interface から readiness、halt reason、最終突合、市場データ age、未確定注文数を読み、発注可否を最上部に明示する。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **本番 UI が全インターフェースへ bind し認証もない** `-3`
  > 本番 Endpoint は IPv6 wildcard に bind し（`runtime.exs:94-103`）、Router に認証 pipeline がなく `/` が公開される（`router.ex:3-25`）。ネットワーク設定ミスに対する多層防御がない。
  >
  > 改善方針: localhost / 管理 VLAN のみへ bind・publishし、reverse proxy ACL と管理者認証を重ねる。取引詳細は認証済み scope に限定する。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/router.ex`

## 実行基盤 / 設定

### health / production

- **healthcheck が readiness を判定しない** `-3`
  > Compose は `/` の HTTP 200だけを見る（`compose.yaml:49-54`）。画面は DB unavailable でも正常描画するため、市場 stale・未同期・DB断でも healthy になり得る。
  >
  > 改善方針: liveness と readiness を分け、readiness は DB、boot state、突合、market age、circuit を集約し、非 Ready 時は非2xxを返す。
  >
  > 対象ファイル: `compose.yaml`, `apps/ui/lib/ui_web/live/status_live.ex`

- **本番 release・Compose・復旧運用がない** `-3`
  > Dockerfile は開発用で（`Dockerfile:1-2`）、Compose は bind mount と `mix phx.server` を使う（`compose.yaml:25-31`）。本番成果物、固定タグ、最小公開、backup / restore、rollback 手順がない。
  >
  > 改善方針: multi-stage release image と `compose.prod.yaml` を作り、SHA/digest で配布する。停止、migration、突合、段階再開、rollback、restore drill を文書化する。
  >
  > 対象ファイル: `Dockerfile`, `compose.yaml`

### trade mode / CI

- **TRADE_MODE が無検証で live 解禁条件もない** `-3`
  > runtime は任意文字列をそのまま設定し（`runtime.exs:42-44`）、`trade_mode/0` も返すだけである（`system.ex:28-33`）。誤記や live 時の key・上限・同期完了を検証しない。
  >
  > 改善方針: 許可値を厳格変換し、不正値では起動停止する。live は専用 key 名、二重の明示設定、risk limits、同期完了が揃うまで halted とする。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/system.ex`

- **共通 precommit と CI が未整備で標準コマンドが失敗する** `-3`
  > ルート alias は setup だけ（`mix.exs:24-28`）。UI の precommit は作業ツリーを変更する `format` を含み、preferred env は子アプリにしかない（`apps/ui/mix.exs:32-36,89-99`）。2026-09-08 の `docker compose run --rm app mix precommit` は MIX_ENV=dev で test support を読めず、`UiWeb.ConnCase is not loaded` により exit 1。`.github/workflows/` も存在しない。
  >
  > 改善方針: ルートに test 環境の副作用なし alias（format check、warnings-as-errors、migration、test）を定義し、PostgreSQL service 付き GitHub Actions から同じ alias を呼ぶ。
  >
  > 対象ファイル: `mix.exs`, `apps/ui/mix.exs`, `.github/workflows/`

## 横断品質

### テスト戦略

- **資金保全経路のテストが皆無である** `-5`
  > bitflyer のテストは生成時の `hello/0` だけ（`bitflyer_test.exs:1-7`）。UI を含む全8件は `MIX_ENV=test mix test` で成功したが、冪等性、mode 分離、risk、stale、突合、不整合停止、復旧を検証しない。
  >
  > 改善方針: adapter 非呼出し、重複 intent、risk fail-closed、不整合 boot halt を優先し、外部 API を behaviour で隔離した DB crash-recovery test を追加する。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer_test.exs`, `apps/ui/test/ui_web/live/status_live_test.exs`

### DX / セキュリティ / 文書整合

- **README が完成済み骨格の現状と一致しない** `-2`
  > README は「開発用 Dockerまで」「Umbrella 本体は手順4以降」とする（`README.md:9-14`）一方、アーカイブは手順1-7完了を記録する（`01-bootstrap-umbrella-and-docker.md:1-7`）。
  >
  > 改善方針: `docker compose up --build`、UI、migration、test、precommit を現状に合わせ、未実装の取引機能と区別する。
  >
  > 対象ファイル: `README.md`, `.workspace/3_archive/01-bootstrap-umbrella-and-docker.md`

- **依存脆弱性の自動検査がない** `-1`
  > 多数の依存と GitHub 参照依存がある（`apps/ui/mix.exs:47-78`）が、deps audit、Dependabot、SBOM、更新 CI がない。
  >
  > 改善方針: CI に `mix deps.audit` と Dependabot を加え、lockfile 更新のレビュー基準を設ける。
  >
  > 対象ファイル: `apps/ui/mix.exs`, `.github/`

- **設計文書と実装の隔たりが大きく完成度表示が曖昧である** `-2`
  > Architecture は完成形を断定形で詳述する一方、実装は Repo と status page の骨格に留まる。README の「これから作るもの」（`README.md:59-65`）にも実装済み項目が混在する。
  >
  > 改善方針: 要求ごとに実装状態と受入テストを結ぶ traceability matrix を作り、live 解禁条件が全て緑になるまで未対応と明示する。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/overview.md`, `README.md`

**減点合計: -57**
