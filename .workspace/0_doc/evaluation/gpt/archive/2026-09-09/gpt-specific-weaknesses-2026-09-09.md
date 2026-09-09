# docker-bitflyer 第2評価者 マイナス点（2026-09-09）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠如。存在しないに等しい |

## 技術評価層 — apps/bitflyer

### market-data

- **到着時刻だけを鮮度とし、取引所時刻・チャネル整合・時計ずれを検証しない** `-3`
  > `Normalize` は ticker の `ltp` と `product_code` だけを残し、取引所 timestamp を捨てる。WebSocket 包の channel と message の product code の対応も検証しない。このため、遅延・リプレイされた古い価格でも「今届いた」という理由で fresh になり、価格逸脱検査もない現状では誤発注の入力になりうる。購読失敗時も Feed は connected のままで、次の切断まで再購読しない。
  >
  > 改善方針: source timestamp・monotonic receipt time・channel を正規化値に保持し、最大 source age と時計ずれを risk の拒否理由にする。購読 ACK / timeout を追跡し、購読失敗は再接続へ遷移させる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

### strategy

- **戦略コマンド境界とパラメータ適用履歴が未実装** `-2`
  > market-data から risk へ渡す strategy プロセスまたは behaviour がなく、`OrderExecutor.submit/2` は任意 map を直接受ける。Architecture の「買いたい / 売りたい / 閉じたい」と戦略から取引所 API を隔離する依存方向、Vision が求めるパラメータ適用履歴をコードで保証できない。
  >
  > 改善方針: Decimal 値、intent ID、strategy revision を持つ command struct と Strategy behaviour を定義し、出力先を `Risk` のみに固定する。適用 revision は Ash Resource に永続化する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading.ex`

### risk-manager

- **資金保全検査がサイズ・建玉・鮮度に限られる** `-4`
  > `Risk.authorize/2` は readiness、キャッシュ鮮度、注文サイズ、予測建玉を fail-closed で検査する点は良い。しかし Vision / Architecture が必須とする日次損失、発注頻度、価格逸脱、利用可能残高、連続 API 障害、時計ずれを検査しない。設定値 `max_order_size: "1"` / `max_position_size: "5"` も FX_BTC_JPY の初期安全値として非常に大きく、環境別上限になっていない。
  >
  > 改善方針: 損失・頻度・価格乖離・残高・時計ずれを単一 `authorize/2` に追加し、live は小さい本番専用上限の明示がなければ起動停止する。閾値超過は拒否だけでなく永続サーキットへ接続する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/limits.ex`, `config/config.exs`

- **公開オプションで risk 認可を無効化できる** `-3`
  > `OrderExecutor.submit/2` の `authorize?: false` は「テスト用」だが本番コードと同じ公開関数で受け付ける。呼び出しミスや将来の UI / strategy 実装から、発注経路の必須境界を迂回できる設計であり、「必ず risk-manager を通す」を型・API 境界で強制していない。
  >
  > 改善方針: 未認可 command を executor が受けない設計にし、Risk が発行する不透明な AuthorizedOrder を要求する。テスト差し替えは依存注入または test 環境限定モジュールで行う。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

### order-executor

- **実取引クライアント・取消・約定追跡がなく live 運用不能** `-5`
  > 既定の `Bitflyer.Exchange.Unavailable` は突合・発注を必ず拒否し、実 API の署名付き client はない。executor に取消、部分約定更新、約定取得、期限切れ、全取消もなく、live の注文ライフサイクルを完結できない。これは後続の高度化ではなく、自動売買という価値命題そのものの未実装である。
  >
  > 改善方針: Req を使う署名付き private REST adapter、取消・未約定照会・約定反映を behaviour に追加し、レート制限と 5xx の再試行境界を定義する。live 解禁前に fixture 契約テストと最小ロットの段階運用を必須化する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange.ex`, `apps/bitflyer/lib/bitflyer/exchange/unavailable.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **通信結果不明を rejected と確定し、受注後 ID 永続化失敗を回復できない** `-4`
  > `Exchange.place_order/1` の全エラーを `rejected` に更新するが、timeout や切断は「取引所が受注したか不明」であり拒否とは限らない。さらに受注成功後に `exchange_order_id` の DB 更新が失敗しても pending 行を返すだけで halt せず、再試行は既存内部 ID を idempotent として即返す。取引所には注文があるのに内部 ID 対応を失う状態を自動回復できない。
  >
  > 改善方針: `submission_unknown` 状態を追加し、通信不明・ID 永続化失敗では即座に Readiness を halt する。内部 ID / child order acceptance ID を用いた照会で事実を確定するまで再送せず、確定拒否だけを `rejected` にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **paper 約定が指値条件と残高を再現しない** `-2`
  > paper の limit 注文は市場価格との交差を見ず、指定価格で即時全約定する。更新対象は Order と Position だけで、仮想 BalanceSnapshot を動かさない。Architecture が意図する「本番と同経路の検証」としては、残高不足、部分約定、未約定、取消を再現できない。
  >
  > 改善方針: ticker / board に基づく約定条件、部分約定、手数料、残高引当を状態機械として実装し、Order・Position・Balance を同一 DB transaction で更新する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

### datastore / Ash

- **戦略パラメータ履歴が永続対象から欠落** `-2`
  > Order、Position、BalanceSnapshot、RiskState は追加されたが、Architecture の最低要件である戦略パラメータ適用履歴がない。注文にも strategy revision / intent payload hash がなく、後から「どの設定がこの注文を出したか」を再現できない。
  >
  > 改善方針: immutable な StrategyParameterRevision を追加し、Order に revision と command hash を関連付ける。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

### OTP / 起動・復帰

- **内部残高が空なら取引所残高を検証せず Ready になれる** `-4`
  > live 突合の balance 比較は内部 snapshot に存在する通貨だけを走査する。新規 DB や snapshot 消失で内部一覧が空なら、取引所側に資金があっても比較ゼロ件で成功する。Risk に残高検査もないため、残高の正本がないまま live Ready へ進める。
  >
  > 改善方針: live 初回は対象通貨の baseline snapshot がなければ halted にし、明示的な import / 承認を要求する。必須通貨集合を設定し、内部・取引所の双方に存在することを突合する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **グレースフルシャットダウンが未実装** `-3`
  > executor と永続更新が実装された現在も、Application stop で新規受付を閉じる処理、進行中 submission の drain、子 spec の shutdown 猶予、Compose の `stop_grace_period` がない。デプロイ・Windows Update・コンテナ停止時に「送信中だが結果未確定」を増やす。
  >
  > 改善方針: shutdown coordinator が最初に readiness / order gate を閉じ、送信中件数がゼロまたは timeout になるまで待つ。Supervisor の shutdown と Compose の停止猶予を同じ値にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`

## 技術評価層 — apps/ui

### 運用操作性

- **「今トレードしてよいか」を一目で判断できない** `-2`
  > readiness と DB は表示されるようになったが、live confirm、exchange order gate、市場データ age、Feed 接続、最終突合時刻、サーキット理由、未確定注文数、建玉がない。`ready` 表示だけでは stale により risk が拒否する状態を運用者が判別できない。
  >
  > 改善方針: `trading_allowed?` を最上部に大きく表示し、阻害理由を列挙する OperationalStatus query を bitflyer 側に置く。詳細カードに market age・最終突合・未確定注文を追加する。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

### 認証・公開面

- **本番 UI が wildcard bind かつ認証なし** `-3`
  > production Endpoint は IPv6 全インターフェースに bind し、StatusLive の browser scope に認証がない。現状の情報量は限定的でも、今後建玉・停止理由を足すほど運用情報の漏洩面が広がる。VLAN / Docker publish の設定ミスに対する多層防御がない。
  >
  > 改善方針: 本番は管理 VLAN / loopback へ bind・publishを限定し、TLS 下の BasicAuth または管理者認証を追加する。`/health` は最小情報のまま認証不要に分離する。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/router.ex`

## 技術評価層 — 実行基盤 / 設定

### Docker / production

- **本番 release image・Compose・backup / rollback がない** `-3`
  > Dockerfile は bind mount 前提の root 実行開発 image で、`mix deps.get` と migration を常駐起動ごとに実行する。本番用 multi-stage release、digest 固定、DB backup / restore、承認付き配布、ロールバック手順がなく、Vision の本番PCで 24/365 稼働する実行形が未完成である。
  >
  > 改善方針: 非 root の release image と `compose.prod.yaml` を作り、migration と server 起動を分離する。バックアップ復元試験、停止→配布→突合→段階再開→rollback を runbook 化する。
  >
  > 対象ファイル: `Dockerfile`, `compose.yaml`, `.workspace/2_todo/03-cd-prod-host.md`

### health / 設定

- **health が市場 stale・Feed 切断を unhealthy にしない** `-2`
  > `/health` は DB と Readiness のみを見る。Readiness は突合成功後に ready のままであり、WebSocket が切れて cache が stale になっても health は 200 を返す。risk は注文を拒否するため資金面は安全側だが、盲目運転を外形監視で検知できない。
  >
  > 改善方針: liveness と readiness を分離し、外形 readiness に feed 接続、全必須 market key の age、最終突合 age を含める。起動中 200 が必要なら `/live` と `/ready` を別パスにする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`, `compose.yaml`

- **live 用 API 秘密情報と最小権限の起動検査が未定義** `-2`
  > `.env.example` と runtime に bitFlyer API key / secret の名前がなく、live 時に必須値、開発キー混入、出金権限なしを検査する経路もない。現時点の unavailable adapter は安全だが、実 client 追加時の誤設定防止枠が先行していない。
  >
  > 改善方針: secret 名と注入元を固定し、live のみ必須化する。起動時に権限照会または運用チェックを行い、出金権限・環境不一致なら halted にする。
  >
  > 対象ファイル: `.env.example`, `config/runtime.exs`, `.workspace/0_doc/architecture/env/prod.md`

## 横断評価層

### 可観測性

- **イベント語彙はあるが永続 reporter・外部アラートがない** `-3`
  > domain telemetry と Logger allowlist は大幅に改善した。しかし reporter は LiveDashboard の開発画面だけで、Discord 等の到達可能な通知、メトリクス永続化、心拍、再起動ループ・未約定滞留・ディスク・時刻同期の監視がない。無人 24/365 の「人に届く」条件を満たさない。
  >
  > 改善方針: 発注経路と独立した通知 adapter と retry queue を置き、halt / reconcile mismatch / 長時間 stale / submission unknown を通知する。ホスト監視と heartbeat の到達試験も運用に含める。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/telemetry.ex`, `.workspace/1_backlog/discord-notify-adapter.md`

### セキュリティ

- **依存脆弱性の自動検査がない** `-1`
  > CI は品質ゲートを実行するが、`mix deps.audit`、Dependabot、SBOM 等はない。Req、WebSockex、Phoenix、Ash を外部接続と管理 UI に使う以上、既知脆弱性を継続検知する入口が必要である。
  >
  > 改善方針: Dependabot と定期 audit を追加し、まず可視化、運用安定後に重大度で fail させる。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/`

### プロジェクト全体設計 / DX

- **README と実装状態が再び乖離している** `-1`
  > README は「市場データ・戦略・リスク・発注 engine は未実装」「これから作るもの」とするが、market-data、risk、executor、永続 Resource、突合は現行コードに存在する。未実装なのは strategy と実 live lifecycle であり、現状表示が粗すぎる。
  >
  > 改善方針: コンポーネント別に implemented / partial / unavailable を明記し、live 不可の理由を具体化する。
  >
  > 対象ファイル: `README.md`

**減点合計: -49**
