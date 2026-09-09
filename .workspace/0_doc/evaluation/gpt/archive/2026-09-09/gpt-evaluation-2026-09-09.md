# docker-bitflyer プロジェクト評価（第2評価者 GPT-5.6 Sol）

- 評価日: 2026-09-09
- 評価種別: 前回評価後の再評価
- 正本: `.workspace/0_doc/vision.md`、`.workspace/0_doc/architecture/overview.md` および `architecture/` の関連文書
- 評価方法: 前回 GPT / 統合評価を起点に弱点を追跡し、現行コード・設定・テストを再読して独立採点

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装済み |
| +2 | 一般的なベストプラクティスに沿う良い設計 |
| +3 | 同規模・同種の平均を明確に上回る |
| +4 | プロダクション級と比較して遜色ない |
| +5 | 個人プロジェクトとして卓越 |
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | バグ・損失・二重発注・不整合を起こしうる欠陥 |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | 根幹を揺るがす致命的欠如 |
| 0 | 実装すれば価値が上がる提案 |

## 総合スコア

| 評価層 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| apps/bitflyer | +21 | -32 | -11 |
| apps/ui | +6 | -5 | +1 |
| 実行基盤 / 設定 | +8 | -7 | +1 |
| 横断評価層 | +6 | -5 | +1 |
| **合計** | **+41** | **-49** | **-8** |

詳細:

- [プラス点](./gpt-specific-strengths-2026-09-09.md)
- [マイナス点](./gpt-specific-weaknesses-2026-09-09.md)
- [提案](./gpt-specific-proposals-2026-09-09.md)

## 合意すべき結論

1. **前回の「Phoenix / Ash / PostgreSQL の骨格だけ」という評価は、現行コードには当てはまらない。** market-data、ETS freshness、Readiness、永続状態、起動突合、risk、mode 別 executor、telemetry、health、CI と資金保全回帰テストが実装された。
2. **それでも live 運用可能ではない。** 署名付き private API client、取消・部分約定・結果不明の回復、完全な risk limits、strategy、graceful shutdown、本番 release と外部アラートがない。
3. **現時点の安全性は「実弾を出せないこと」に強く依存する。** 既定 `Unavailable` adapter は事故防止として正しいが、自動売買の価値命題は未完成である。
4. **最も危険な潜在欠陥は live の曖昧結果処理である。** timeout を rejected と確定し、受注後の ID 永続化失敗でも halt しない実装は、実 client を接続した瞬間に取引所と内部状態を分岐させうる。
5. **骨格の美しさとテスト増加は、資金保全の残欠を相殺しない。** 純点は大幅改善したが、実資金投入の判定は明確に不可である。

## 技術評価層 — apps/bitflyer

### market-data

Feed、WebSocket adapter、Req REST gap-fill、Decimal normalize、ETS cache、再接続と stale risk gate が実装された。gap-fill が新しい WS tick を上書きしない競合対策まであり、前回の `-4` 相当は大部分解決した。

一方、鮮度はローカル受信時刻だけで、取引所時刻・時計ずれ・channel と product code の対応を検証しない。fresh な異常値も拒否できないため、market-data の完成判定はまだ早い。

**小計: +3 / -3 = 0点**

### strategy

戦略アルゴリズム自体は Vision 上後続でもよい。しかし strategy command / behaviour とパラメータ revision がなく、任意 map が直接 risk / executor に入る。取引所非依存の依存方向をコードで固定できていない。

**小計: +0 / -2 = -2点**

### risk-manager

Ready、stale、注文サイズ、予測建玉を fail-closed で検査し、DB 読取失敗を安全側へ倒す。サーキットの「メモリ halt を先、永続化を後」「解除は永続化を先」という順序も良い。

ただし日次損失、頻度、価格逸脱、残高、時計ずれ、API 連続障害がない。さらに public `authorize?: false` で executor の risk を迂回できる。Vision の Safety first を満たすには不十分である。

**小計: +3 / -7 = -4点**

### order-executor

DB unique な内部注文 ID、競合時再読、DryRun / Paper / Live 出口、paper の transaction 更新、非送信 spy test は大きな前進である。

しかし実 exchange client、取消、約定追跡がなく live は動かない。より重要なのは、通信結果不明を rejected と扱い、取引所受注後の exchange ID 永続化失敗で halt / 自動照合しない点である。paper も指値を無条件即時全約定し、残高を更新しない。

TradeMode の mode 別出口・live gate の加点も、この order-executor 層に含める。

**小計: +6 / -11 = -5点**

### datastore / Ash

Order、Position、BalanceSnapshot、RiskState と migration が追加され、Decimal・unique identity・mode 分離が実体化した。Ash を永続状態、ETS を hot path に分ける方針も維持される。

未実装は StrategyParameterRevision と注文への revision / payload hash の関連付けである。

**小計: +3 / -2 = +1点**

### cache / ETS

専用 owner、protected ETS、read concurrency、monotonic receipt time、table 消失時 miss、risk との接続が実装された。単一ノード前提で Redis を増やしていない。加点は market-data の `+3` に含め、ここでは重複計上しない。

**小計: +0 / -0 = 0点**

### observe

取引イベント語彙、allowlist metadata、Logger metadata、LiveDashboard metrics が揃った。秘密らしき任意 key を telemetry / Logger metadata へ流さない設計は妥当である。

外部通知と永続 reporter の欠如は横断可観測性で減点する。

**小計: +2 / -0 = +2点**

### OTP / Application

取引側 supervisor に Repo、Readiness、Cache、TaskSupervisor、Reconciler、Feed が載り、UI Application と兄弟分離される。起動・定期突合、不整合 halt も実装された。

ただし live で内部 BalanceSnapshot が空なら取引所残高を比較せず Ready になれる。Application shutdown、submission drain、Compose 停止猶予もない。

**小計: +4 / -7 = -3点**

## 技術評価層 — apps/ui

### Phoenix / LiveView

StatusLive は `Bitflyer.System` の公開 interface だけを読み、bitFlyer API / Repo を直接呼ばない。裁量 UI に逸脱せず、Ready / halt reason を主要 DOM ID とテスト付きで表示する。

ただし `trading_allowed?`、market age、Feed、最終突合、未確定注文、建玉は見えず、「今トレードしてよいか」は一目で判断できない。

**小計: +4 / -2 = +2点**

### health / 公開面

`GET /health` は DB 断・halt を 503 にし、DB エラー詳細を公開しない。Compose も同じ path を見るため、前回の healthcheck 欠陥は主要部分が解決した。

本番 UI は wildcard bind で認証なしのままである。market stale / Feed 切断を health が検知しない点は実行基盤側で減点した。

**小計: +2 / -3 = -1点**

## 技術評価層 — 実行基盤 / 設定

### Docker Compose / Dockerfile

開発 Compose は localhost publish、DB health dependency、restart、bind mount、名前付き build / deps volume、dry_run 既定を一貫実装し、`docker compose config --quiet` も成功した。`.dockerignore` も追加された。

本番 release image / Compose、non-root、backup / restore、rollback、停止猶予はない。現状は 24/365 本番配置の構成ではない。

**小計: +4 / -3 = +1点**

### config / 環境変数

TRADE_MODE の厳格検証、UTC 当日 confirm、test DB 分離は解決済みである。開発の既定も dry_run で一貫する。

bitFlyer API key / secret の名前、live 専用注入、最小権限検査は未定義である。

**小計: +2 / -2 = 0点**

### CI / CD

ルート `mix precommit` と PostgreSQL service 付き GitHub Actions が追加され、ローカル・CI の入口が統一された。CD は設計文書どおり未実装だが、本番運用欠如は Docker / production の減点へ含めた。

**小計: +2 / -0 = +2点**

### health

DB / halted は正しく 503 になる一方、Ready 後の market stale、Feed disconnect、最終突合 age は 200 のままである。発注は Risk が止めるため即損失には直結しないが、外形監視は盲目運転を検知できない。

**小計: +0 / -2 = -2点**

## 横断評価層

### テスト戦略

評価時の `mix precommit` は bitflyer 85 tests + 1 doctest、ui 10 tests、失敗 0。重複 intent、mode 分離、boot halt、stale、risk 拒否、突合、market reconnect、telemetry を実 DB / spy adapter で検証する。前回の「資金保全テスト皆無」は解決済みである。

プロパティ・モデルベース・実 API fixture 契約は次段階の提案とし、現時点では減点しない。

**小計: +3 / -0 = +3点**

### 可観測性・デバッグ容易性

イベント語彙と構造化ログは改善したが、Discord 等の到達通知、metrics reporter、心拍、host / clock / disk 監視がない。24/365 無人運用では「イベントを発行した」だけでは Observable 完了にならない。

**小計: +0 / -3 = -3点**

### エラーハンドリング・安全側フォールバック

Readiness、stale、DB 読取失敗、persisted circuit、exchange unavailable は安全側へ倒れる。一方、live submission の通信不明と ID 永続化失敗は安全な状態機械になっていない。この重大点は order-executor で採点済みのため重複減点しない。

**小計: +0 / -0 = 0点**

### 変更容易性・保守性

ui → bitflyer の一方向依存、exchange / socket / REST behaviour、Domain 分離、第三アプリを作らない方針は保たれる。急増した実装でも論理境界は比較的明瞭である。

**小計: +1 / -0 = +1点**

### 開発者体験（DX）

README から Compose 起動、test DB setup、precommit、関連文書へ到達できる。ただし README の engine 未実装表記は現行コードと再びずれており、partial / unavailable の粒度が必要である。

**小計: +0 / -1 = -1点**

### 取引完成度

market-data → risk → executor → paper 永続化という縦貫通はできたが、strategy と live private API / lifecycle がないため実運用は不可である。重大欠如は各技術層で採点済みのため、ここでは重複加減点しない。

**小計: +0 / -0 = 0点**

### セキュリティ・秘密情報・権限

runtime 注入、Git ignore、Docker context 除外、health 情報抑制は良い。依存脆弱性の自動検査がなく、API key 最小権限の実装も未完成である。API key 側は config 層で採点済み。

**小計: +0 / -1 = -1点**

### プロジェクト全体設計

Vision / Architecture の品質は高く、前回から Safety / Recoverable / Idempotent の多くがコードとテストに接続された。改善計画 P0〜P2 を短期間で実装へ落とした自己改善サイクルは明確である。

**小計: +2 / -0 = +2点**

## 前回からの変化

### 解決済み

- ルート `mix precommit` と `preferred_envs: :test`
- PostgreSQL service 付き GitHub Actions CI
- test DB の development DB からの分離
- `.dockerignore`
- `TRADE_MODE` 許可値検証と live 二重確認
- Readiness の単一正本と fail-closed 初期状態
- DB / halt を判定する `GET /health` と Compose 接続
- 取引 telemetry 語彙と metadata allowlist
- Order / Position / BalanceSnapshot / RiskState の永続化
- 起動・定期 reconcile と不整合時の永続 halt
- 鮮度付き ETS cache
- market-data の REST / WebSocket、再接続、穴埋め
- risk の Ready / stale / サイズ / 建玉検査とサーキット
- DryRun / Paper / Live 出口と内部注文 ID の DB unique
- 重複 intent、mode 分離、boot halt、risk 拒否の回帰テスト

### 部分解決

- risk-manager: 中核境界はできたが、損失・頻度・価格逸脱・残高・時計ずれがない
- order-executor: 冪等骨格はあるが、live の結果不明・取消・約定追跡がない
- health: DB / halt は見るが、market stale / Feed / 最終突合 age を見ない
- StatusLive: halt reason は見えるが、総合的な発注可否は見えない
- 起動復帰: 突合はあるが、初回 balance baseline と shutdown drain がない
- 可観測性: event はあるが reporter / 外部通知がない
- README: 前回の骨格説明は直ったが、その後の engine 実装を反映していない

### 未解決

- strategy command と戦略パラメータ履歴
- 本番 UI の bind 制限・認証
- 本番 release / Compose / backup / rollback
- graceful shutdown
- 実 bitFlyer private API client と API key 最小権限検査
- 依存脆弱性の継続検査

## 実行検証結果

### `docker compose run --rm -e MIX_ENV=test app mix precommit`

**成功（exit 0、約19秒）**。

- bitflyer: 1 doctest + 85 tests、0 failures
- ui: 10 tests、0 failures
- `deps.unlock --check-unused`
- `format --check-formatted`
- `compile --warnings-as-errors`
- `test --warnings-as-errors`

前回の `UiWeb.ConnCase is not loaded` は再現せず、ルート品質ゲート修正を実行で確認した。

### `docker compose config --quiet`

**成功（exit 0）**。Compose の構文・展開に問題なし。

### `.github/workflows/`

**存在を確認**。`.github/workflows/ci.yml` は PR と main push を対象に、Elixir 1.18.3 / OTP 27、PostgreSQL 16、test DB setup、`mix precommit` を実行する。

## 優先順位

1. **live submission の不明状態を安全化**: `submission_unknown`、即 halt、取引所照会、outbox
2. **risk 検査を完成**: 日次損失、頻度、価格逸脱、残高、時計ずれ、環境別の小さい上限
3. **実 client より先に API 契約・秘密・権限を固定**: 取消、約定、未約定、rate limit、出金権限禁止
4. **live 初回 balance baseline と shutdown drain**
5. **OperationalStatus / `/ready` / StatusLive**: market age、Feed、最終突合、発注可否
6. **外部アラートと本番 release / backup / rollback**
7. **strategy command と parameter revision**
8. property / model-based test、Game Day、SBOM はその後

## 総評

前回からの改善量は非常に大きい。現在は「骨格」ではなく、**安全側に倒れる paper 対応取引基盤の初期実装**と呼べる。特に TradeMode、Readiness、stale risk、永続 halt、DB unique idempotency、資金保全回帰テスト、共通 CI は、Architecture を実装へ移した明確な成果である。

ただし、実資金を扱う基準ではまだ不合格である。実 API がないこと以上に、現行 Live adapter が timeout を rejected と確定すること、受注後の ID 永続化失敗で halt しないこと、初回残高 baseline がなくても Ready になれることが危険である。完全な risk limits、graceful shutdown、外部通知、本番配布も欠ける。

したがって、**paper で安全機構を育てる段階には進めるが、live 接続は不可**と結論する。

**最終評価: +41 / -49 = -8点**
