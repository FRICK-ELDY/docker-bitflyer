# Environment: Production

本番環境の目的は、承認済みの戦略を **実資金** で 24 時間動かし続けること。

落ちても自動で戻る。ただし状態が不明なときは、取引を止めて資金を守る。

## 目的

- 単一ホスト（初期）で Compose 相当の構成を常時稼働させる
- 障害後も、取引所の事実（残高・建玉・未約定）と内部状態を一致させてから再開する
- 異常時は人に届く。届かない監視は監視ではない

## 構成

| 項目 | 方針 |
| --- | --- |
| オーケストレーション | Docker Compose または同等の常駐構成。初期は単一ホスト |
| 再起動 | アプリ系は自動再起動。データストアは慎重に再起動する |
| 取引モード | 実発注。`TRADE_MODE=live` + `BITFLYER_LIVE_CONFIRM`（UTC 当日）+ Ready。初回は最小ロットと厳しい上限から |
| 接続先 | bitFlyer 本番 API。開発キーは使わない |
| データストア | 名前付きボリュームまたはホストの永続ディスク。定期バックアップ |
| 秘密情報 | ホストのシークレットまたは環境変数。リポジトリ・イメージ・ログに出さない |
| 公開ポート | 管理 UI や DB を不用意に公開しない |
| UI 認証 | `UI_BASIC_AUTH_USERNAME` / `UI_BASIC_AUTH_PASSWORD` 必須（`:browser` のみ。`/health*` は認証なし）。`/ops/dashboard` も同じ保護 |
| HTTP bind | 既定 `PHX_HTTP_IP=127.0.0.1`。VLAN 越しに出すときだけ明示変更 |
| API キー | `BITFLYER_API_KEY` / `BITFLYER_API_SECRET`。`TRADE_MODE=live` 時必須（欠落は起動停止） |
| Risk 上限 | `BITFLYER_MAX_ORDER_SIZE` / `POSITION_SIZE` / `DAILY_LOSS` / `ORDERS_PER_MINUTE` / `PRICE_DEVIATION_PCT` を明示（開発既定は live で拒否） |
| 取引所エラー | 401/403 は即 `:auth_failed` サーキット。その他の確定拒否は窓内 N 回（既定 60s / 5 回）で `:consecutive_exchange_errors`。鍵を直したあとは突合→`mix bitflyer.resume` |
| Strategy | 既定無効。`BITFLYER_STRATEGY_ENABLED=true` が必要。`FixedOnce` は live で有効化不可 |

## bitFlyer API キー

- 環境変数名は上記で固定。ホスト側シークレットのみ。Git・イメージ・ログに出さない
- `dry_run` / `paper` では省略可。`live` では両方揃っていないと起動しない
- 権限は取引に必要な参照・発注のみ。**出金・送付権限は付けない**（Vision / overview と同旨）
- live 起動突合で `GET /v1/me/getpermissions` を呼び、`/v1/me/withdraw` / `/v1/me/sendcoin` が含まれていれば `unsafe_api_permissions` で halt
- 公開 ticker の `timestamp` とホスト時刻の差が `max_clock_skew_ms`（既定 5s）を超えると `clock_skew` で halt
- 開発用キーと本番キーを混在させない
- 署名付き REST client は `Bitflyer.Exchange.Rest`（`TRADE_MODE=live` かつ `BITFLYER_API_*` ありで runtime が差し込む）。キー欠落・dry_run/paper の既定は `Exchange.Unavailable`

## UI 公開面

- Status（`/`）と locale 切替は BasicAuth。資格情報はホスト側シークレットのみ
- 外形監視用の `/health/live`・`/health/ready`・`/health` は認証なし（詳細は取引画面より薄い）
- 本番 Endpoint の既定 bind は loopback。`0.0.0.0` / `::` は意図的な公開時のみ
- 作業用 PC から見る場合も、ネットワーク ACL と BasicAuth の両方で守る（どちらか一方に頼らない）

## 稼働要件

- ホストは常時起動。Docker デーモンもホスト起動時に立ち上がる
- ディスク残量、メモリ、コンテナ再起動回数を監視する
- 時刻同期（NTP 等）が生きている
- 外部 API と名前解決ができる
- 停止・再開の手順が文書化されている

## 起動シーケンス（本番）

1. シークレットと本番設定だけが読み込まれていることを確認する
2. datastore を先に健全化する
3. 内部状態を復元し、bitFlyer の残高・建玉・未約定と突合する
4. 差分があれば Ready にせず、発注を禁止したままアラートする
5. 市場データが新鮮になってから戦略を有効化する
6. ヘルスチェックが通り、監視が心拍を確認してから「稼働中」とみなす

## 安全装置

- 注文サイズ、建玉、日次損失（`Fill.realized_pnl` = 売買差 − `Fill.fee`。live の fee は getexecutions の `commission`、spot は quote 通貨）、日次ドローダウン（realized+含み）、発注回数にハードリミットを置く
- 含み損ゲート（`Risk.Equity` / `max_daily_drawdown` / live は `BITFLYER_MAX_DAILY_DRAWDOWN_JPY`）:
  `drawdown = 当日 equity ピーク（HWM） − 現在 equity`（日始ピーク 0）。
  ピーク上昇は認可では `DailyLoss` ETS のみ。`DailyEquityPeak`
  （`trade_mode` × JST 取引日）への upsert は Fill 後 / 突合 / resume。
  `DailyLoss.init` / `reload` / `reinit` が当日行を読む。読取・永続化失敗は unsynced。
  建玉の mark が stale / 欠落なら **認可と resume は fail-closed**。周期 enforce
  （boot / `run_now` / periodic / Fill 後）は **halt しない**（切断だけで永続停止にしない）。
  超過時は `daily_drawdown_exceeded` で halt。新規注文は未実現に投影しない
  （同一 LTP なら増分はほぼ 0。超過は約定後 enforce か周期で拾う）。
  `unrealized` は内部 `Position.average_price` × LTP の推定（spot に取引所平均は無い）。
  spot 在庫は突合で `getbalance` base amount と買い Position.size を比べ、
  内部膨張・売り残超過・売建玉を `position_mismatch` にする（平均は比較しない）。
  live 売りは認可でも同じカバー条件（ベースライン専用在庫は売らない）
- 価格が直近相場から乖離した注文は出さない
- 連続障害、署名エラー、想定外残高変動でサーキットブレーカを開く
- サーキットが開いたら、新規注文を止め、**理由別に未約定 live の全取消（cancel-all）を選べる**
  （`Bitflyer.Risk.OpenOrderPolicy` / `config :bitflyer, Bitflyer.Risk.OpenOrderPolicy`）
- API キーは取引に必要な権限のみ。出金は付けない
- デプロイ後は、まず参照系と dry-run 相当の確認を経てから実弾を解禁する

### 未約定ポリシー（open age / TIF / halt cancel-all）

| 項目 | 方針 |
| --- | --- |
| 自前 TIF | **未実装。** 取引所既定（実質 GTC）。注文ごとの `expires_at` は持たない |
| open age | `max_open_age_ms`（既定 `:infinity`）。定期突合 tick で `inserted_at` 超過の live open を `cancel/2` |
| halt cancel-all | 理由ごと boolean。`true` のとき halt 成功後に live open を best-effort 逐次取消（失敗しても halt 維持） |
| 取消する理由（既定 true） | `manual_halt`, `daily_loss_exceeded`, `daily_drawdown_exceeded`, `consecutive_exchange_errors`, `auth_failed`, `fill_sync_failed`, `fill_price_unavailable` |
| 取消しない理由（既定 false） | `reconcile_mismatch`, `submission_unknown`, `persist_failed`, `restore_failed`, `exchange_unavailable`, `invalid_exchange_payload`, `unsafe_api_permissions`, `clock_skew`, `risk_halted`, `failure_rate_unsynced`（証拠保全・recover 優先） |
| 再起動／CircuitSync | 永続 halt を ETS に載せたとき、および既に halted の同期 tick でも `ensure_halt_cancels` を再実行（一回限りではない）。目的は未完了 cancel の再試行 |
| cancel 背圧 | in-flight 中はスキップ。失敗／open 残留後は `halt_cancel_retry_backoff_ms`（既定 30s）。状態は `HaltCancelGate` GenServer 所有 ETS（LV 等の呼び出し元終了でも消えない）。非同期 Task は Gate が monitor し、`finish` 前の死でロック解除＋backoff。`:cleared` 後は resume / `:force` まで open list を省略。`Circuit.open`／初回 ETS 適用は `:force`。in-flight 失効は `halt_cancel_in_flight_stale_ms`（既定 600s、monitor の保険） |
| open age 実行 | 突合 GenServer 上では非同期 Task。halt cancel の Gate とは共有しない |
| ID 無し / ACTIVE 残 | 既存 `cancel/2` と同じ（ローカル終端 or fill 同期後に終端。取引所 ACTIVE なら pending 維持） |

運用で TTL を有効にする例: `max_open_age_ms: 3_600_000`（1 時間）。live 解禁前に理由マップを環境に合わせて見直す。

## 監視とアラート

同一ホスト上の Compose healthcheck・stdout・LiveDashboard はホスト停止で一緒に消える。
**同一ホスト死を外部が検知できる**ことが外部監視の完了条件。次の 3 点を取引ホストの外に置く。

### 別ホストからの `/health/ready`（必須）

| 項目 | 値 |
| --- | --- |
| URL | `https://<公開面>/health/ready`（認証なし。詳細は取引画面より薄い） |
| 成功 | HTTP 200 かつ JSON `"status":"ready"` |
| 失敗 | 接続不能・タイムアウト・503（halt / Feed 断 / stale / DB 断） |
| 間隔 | 60s |
| タイムアウト | 5s |
| 連続失敗 | 3 でアラート |

Compose の `/health/live` はコンテナ再起動用。WS 断では落とさない。盲目運転とホスト死は **ready を別ホストから pull** する。同一ホストの cron で Healthchecks.io に push しても、ホスト死は届かない。

公開面が loopback のみなら、監視ホストから Tailscale / WireGuard / SSH トンネルで到達させる。インターネットに晒すなら TLS + IP allowlist。

探針スクリプト（監視ホスト側。実行ビットは不要）:

```bash
# 単発（cron / Kuma Command）
READY_URL=https://bot.example/health/ready bash bin/watch-ready.sh

# 常駐（60s・連続 3 失敗で stderr alert）
READY_URL=https://bot.example/health/ready READY_LOOP=1 READY_INTERVAL=60 READY_STRIKES=3 \
  bash bin/watch-ready.sh
```

Uptime Kuma（安価 VPS など）の例: Monitor type HTTP(s)、URL 上記、Keyword `"status":"ready"`、間隔 60s、retries 3。失敗で Discord / メール。Kuma 自体は取引 PC に置かない。

計画上の「完了」は手順と探針があること。別ホストのジョブが実際に動いているかは live チェックリスト側。

### ホスト exporter（必須）

取引ホストの disk / メモリ / 時刻ずれはアプリ JSON に出ない。exporter を取引ホストで listen し、**別ホストが scrape** する。

#### Linux

`compose.observe.yaml`（`pid: host` + `/proc` `/sys` `/` を bind。既定 `127.0.0.1:9100`）。

```bash
docker compose -f compose.prod.yaml -f compose.observe.yaml --env-file .env.prod up -d
```

LAN から取るときは `NODE_EXPORTER_HOST_PORT=0.0.0.0:9100` と FW / Tailscale。
見るもの: `node_boot_time_seconds`（再起動ループ）、`node_filesystem_avail_bytes`、`node_memory_MemAvailable_bytes`、scrape 時刻と `node_time_seconds` のずれ（NTP）。

#### Windows（Docker Desktop では compose.observe.yaml を使わない）

1. [windows_exporter releases](https://github.com/prometheus-community/windows_exporter/releases) の MSI を取引ホストに入れる
2. 既定 listen は `0.0.0.0:9182`。可能なら localhost + Tailscale に閉じる
3. collector 例: `cpu,cs,logical_disk,memory,os,system,time`
4. 別ホストから `http://<取引ホスト>:9182/metrics` を scrape（FW は監視ホストだけ許可）
5. 見るもの: `windows_system_system_up_time`、`windows_logical_disk_free_bytes`、`windows_os_physical_memory_free_bytes`、`windows_time_computed_time_offset_seconds`

時系列蓄積・SLO ダッシュボードは後続（P3 #18）。ここでは「ホストが応答するか」が閉じればよい。

### 通知 heartbeat（通知経路死を見るとき必須）

ホスト死の正本は別ホストの ready pull。Discord は **通知経路そのものの死** を見る。
`DISCORD_WEBHOOK_URL` が無いと HEARTBEAT は出ない（起動はする）。経路死を検知する運用では Webhook を置く。

Webhook があるとき、起動直後に 1 通、以降は既定 15 分（`DISCORD_HEARTBEAT_INTERVAL_MS`、0 / infinity でオフ）。
イベント cooldown は掛けない。HTTP は Discord プロセスを待たせない。未設定・送信失敗でも発注は止めない。

運用: **2 間隔（既定 30 分）来なければ** 通知経路またはプロセス死。Discord チャンネルを人が見るか、別経路（メール / 別 webhook）で欠落を取る。halt / mismatch / disconnect のイベント通知とは別に、沈黙自体をアラートにする。

### ホスト内の補助（外部監視の代替にしない）

最低限、次も見る（率・推移の本命は後続の永続 metrics）。

- コンテナの死活と再起動ループ
- WebSocket の切断時間とデータ遅延
- 未約定注文の滞留
- 内部状態と取引所状態の不一致
- 日次損益とリミット接近

率・推移の見方:

- **ログ**: prod 既定で `Telemetry.Metrics.ConsoleReporter` が低頻度ドメイン（disconnect / rejected / order / reconcile / circuit / readiness / health）をイベント毎に stdout へ出す。tick・Phoenix・VM は除外。長期保管で埋もれる場合は `UI_METRICS_CONSOLE=false`
- **画面**: `https://…/ops/dashboard`（Status と同じ `UI_BASIC_AUTH_*`）。loopback / ACL 配下で公開する。Ecto・RequestLogger・OS env 表示・破壊操作はオフ。Processes / ETS / Applications はライブラリ既定で残るため、Status 単独より OTP 内省の到達面が広い
- アプリの Prometheus scrape エンドポイントは未導入（P3 #18）

アラートは「起きたこと」と「今トレードしてよいか」が分かる文言にする。

## 障害時の原則

1. 新規発注を止める
2. 取引所側の事実を取り直す
3. 内部状態を事実に合わせる。推測で埋めない
4. 合わせられないなら停止したまま人に渡す
5. 復旧後も、最初の数件は通常より厳しい上限で様子を見る

## 停止・再開

### 停止（グレースフル）

コンテナへの SIGTERM / `docker compose stop app` で `Application.prep_stop/1` が走り、発注ゲートが閉じたあと進行中の submit/cancel を drain する（既定 10s。timeout 時は ID 未確定の pending を `submission_unknown` + halt）。その後に子の `shutdown`（明示指定は各 5s、Supervisor 直列）が続き、全体は Compose の `stop_grace_period`（45s）に収める。

### halted の見え方

- `GET /health/ready` または `GET /health` が 503、またはレスポンスの readiness が `halted:...`
- 新規 submit は拒否される（`:circuit_open` / `:unsynced`）
- Feed 切断・市場データ stale は `GET /health/ready` が 503（`reason` が `feed_disconnected` / `stale_market_data` 等）。`Risk.authorize` も同じゲートで拒否する。Compose の `/health/live` は落とさない
- WS が生きたまま tick が止まった場合は Feed の stall watchdog（既定は `market_data_max_age_ms × 3`、`stall_timeout_ms` で上書き可）で `:stale_watchdog` 切断→自動再接続。人手再起動は不要

### 初回 baseline（`mix bitflyer.baseline`）

live で必須通貨（既定: JPY / BTC）の `BalanceSnapshot` が無いと起動突合は `balance_baseline_missing` で止まる。人手 SQL ではなく承認付き import で作る。

1. 取引所残高を確認したうえで dry-run:

   ```bash
   docker compose exec -e BITFLYER_BASELINE_OPERATOR=alice app mix bitflyer.baseline --dry-run
   ```

2. hash・金額を見て問題なければ、**dry-run と同じ hash** を付けて confirm（**Ready にはしない**）:

   ```bash
   docker compose exec -e BITFLYER_BASELINE_OPERATOR=alice app \
     mix bitflyer.baseline --confirm --hash=<dry-run の hash>
   ```

   再取得結果が dry-run と違えば `snapshot_hash_mismatch` で拒否する（見た金額の承認）。

3. 起動突合または `mix bitflyer.resume` が成功したときだけ Ready。release なら常駐 BEAM 上で:

   ```bash
   bin/docker_bitflyer rpc 'Bitflyer.Release.import_baseline(dry_run: true, operator: "alice")'
   bin/docker_bitflyer rpc 'Bitflyer.Release.import_baseline(confirm: true, operator: "alice", expected_hash: "<hash>")'
   ```

必須通貨のうち tip が無いものだけを書く（欠落分の補完可）。全必須通貨に tip がある場合は `baseline_already_complete`。

live 運用中の残高 tip は定期／起動突合が、内部 Fill 合計と **支払超過側** の手数料許容幅で説明できる差分だけ取引所 `getbalance` から append する。`Fill.fee` が揃っていれば quote 側に実手数料を織り込み、許容は絶対床だけ。fee 未記録（NULL）の Fill だけ 20bps を残す。想定より増える差分（入金）は幅内でも halt。Fill が無いときの 1 JPY 床は使わない。説明不能な差分（外部入出金など）は `balance_mismatch` で halt する。人手で正本を切り直すときは承認付き `--rebaseline`（初期化とは別経路）:

```bash
docker compose exec -e BITFLYER_BASELINE_OPERATOR=alice app \
  mix bitflyer.baseline --rebaseline --dry-run
docker compose exec -e BITFLYER_BASELINE_OPERATOR=alice app \
  mix bitflyer.baseline --rebaseline --confirm --hash=<dry-run の hash>
```

release なら:

```bash
bin/docker_bitflyer rpc 'Bitflyer.Release.import_baseline(dry_run: true, rebaseline: true, operator: "alice")'
bin/docker_bitflyer rpc 'Bitflyer.Release.import_baseline(confirm: true, rebaseline: true, operator: "alice", expected_hash: "<hash>")'
```

`--rebaseline` は必須 tip が揃っているときだけ書く。欠落がある場合は通常の初回 import を使う。

### submission_unknown 回収（`mix bitflyer.recover`）

発注 timeout 等で Order が `submission_unknown`（または ID 未埋込の `pending`）になり halt したとき、取引所 `getchildorders` を時刻窓 + side + size（limit は price）で照合して ID を埋める。**Ready にはしない**。

1. halt 理由と対象 `internal_order_id` をログから確認する
2. dry-run で候補を見る:

   ```bash
   docker compose exec -e BITFLYER_RECOVER_OPERATOR=alice app \
     mix bitflyer.recover --dry-run --internal-order-id=<id>
   ```

3. 結果に応じて confirm（いずれも dry-run の `hash` 必須）:

   - **候補 1 件**: `--confirm --hash=<hash>`
   - **候補複数**: 取引所画面と突合し `--confirm --hash=<hash> --exchange-order-id=JRF-...`
   - **候補 0**: 取引所に無いと確認できたら `--confirm --hash=<hash> --absent`（cancelled。**BalanceCache hold は残す** — 誤解放で available 過大にしない）

4. 続けて `mix bitflyer.resume`（下記）。release なら:

   ```bash
   bin/docker_bitflyer rpc 'Bitflyer.Release.recover_submission(dry_run: true, operator: "alice", internal_order_id: "<id>")'
   bin/docker_bitflyer rpc 'Bitflyer.Release.recover_submission(confirm: true, operator: "alice", internal_order_id: "<id>", expected_hash: "<hash>")'
   ```

窓幅は `--window-seconds`（既定 300）。一覧は要求 count（既定 500）に対し内部で count+1 を取り、超過時のみ切り捨て失敗（ちょうど count 件でも成功）。`child_order_date` 欠落・不正も一覧失敗。曖昧な候補を自動確定しない。

対象は `submission_unknown` と persist_failed 由来の **ID 未埋込 `pending`**。誤 `--absent` で `cancelled` になっても ID 無しなら再 recover で紐付けできる（hold は継続）。

### kill switch（即 halt）

発注を直ちに止める。**正本は同一 BEAM** の StatusLive **Kill switch**（BasicAuth 後）または release rpc。

```bash
# 推奨（同一 BEAM）
docker compose -f compose.prod.yaml exec app \
  /app/bin/docker_bitflyer rpc "Bitflyer.Release.halt_trading()"
```

`mix bitflyer.halt` は **RiskState 永続化の補助**。`compose exec` の Mix は別 BEAM のため常駐の Readiness ETS は即時更新しない。常駐の `Risk.CircuitSync`（既定 2s）が DB→ETS を同期すると新規発注は止まる。即停止は StatusLive / rpc を使う。

```bash
docker compose exec app mix bitflyer.halt
```

### 再開（`mix bitflyer.resume` / StatusLive）

remote console だけに頼らず、再突合成功時のみ halt を外す。**同一 BEAM なら StatusLive の Resume / Reconcile now が推奨**（ETS 乖離が無い）。

1. 不整合の原因を直す（残高・建玉・設定・取引所側）
2. StatusLive で Resume を押すか、稼働コンテナで:

   ```bash
   docker compose exec app mix bitflyer.resume
   ```

   成功時のみ RiskState の永続 halt を解除し、当該 BEAM を Ready にする。突合失敗時は halt を維持して終了コード 1。
3. **常駐の `phx.server` と別プロセスで Mix を叩いた場合**は、DB は直っても常駐側 ETS の halted が残る。続けて再起動する:

   ```bash
   docker compose restart app
   ```

   起動突合が通り Ready になる。同一 BEAM 上なら IEx で `Bitflyer.System.resume()` でもよい。
4. `GET /health/ready` で status が `ready` であることを確認する（従来の `GET /health` でも readiness は確認可）

やってはいけないこと: 突合せず `clear_halt` / RiskState だけを手で書き換えて再開する。

詳細は [dev.md](./dev.md) を正とする。本番だけで許すことは次に限る。

- 実資金での発注
- 永続データのバックアップ対象化
- 外部通知チャネルの正式運用

本番だけで許さないこと:

- 未検証の戦略パラメータ変更
- 開発用モックや開発キーの混入
- 監視なしでの連続稼働

## 実行形（release Compose）

| ファイル | 役割 |
| --- | --- |
| `Dockerfile.prod` | multi-stage `mix release`（非 root・assets digest） |
| `compose.prod.yaml` | 本番相当の `app` / `db`。開発用 `compose.yaml` と混線しない |
| `.env.prod` | ホスト側シークレットのみ（Git に入れない） |
| `bin/deploy-prod.sh` | pull/build → up → `/health/live` 待ち。rollback サブコマンドあり |
| `bin/backup-db.sh` | `pg_dump` → `backups/*.sql.gz` |

イメージ参照は `APP_IMAGE`（**digest 固定推奨**）。未設定時のみローカル `docker-bitflyer:local` を build する。`:latest` だけに頼らない。

配布の流れ（誰がいつ更新するか）は [ci-cd.md](../ci-cd.md) を正とする。成果物は GHCR。`main` マージ alone では実弾デプロイしない。Actions CD は **対象 SHA の最新 `ci.yml`（workflow 全体）成功**を前提に push する。

### ローカル／本番PC での一度上げ（実弾なし）

```bash
cp .env.example .env.prod
# SECRET_KEY_BASE / UI_BASIC_AUTH_* / POSTGRES_PASSWORD / DATABASE_URL / POSTGRES_DB を埋める
# TRADE_MODE=dry_run のまま
docker compose -f compose.prod.yaml --env-file .env.prod up -d --build
curl -fsS http://127.0.0.1:4000/health/live
```

Status は BasicAuth 必須。`/health*` は認証なし。

### 入れ替え手順（作業用PC → 本番PC）

1. **事前**: ディスク残量、時刻同期、Docker 稼働、現行 `APP_IMAGE`（digest）を記録
2. **デプロイ前**: 新規発注を止める（halt / 運用操作）。可能なら未約定を把握する。`TRADE_MODE=live` のまま勝手に再開しない
3. `APP_IMAGE=ghcr.io/<owner>/<repo>@sha256:... ./bin/deploy-prod.sh`  
   または `docker compose -f compose.prod.yaml --env-file .env.prod pull && ... up -d`
4. **起動後**: `/health/live`・`/health/ready`・ログ。`live` なら取引所突合。不整合なら Ready にせず停止のまま
5. **事後**: 監視の心拍。問題なければ段階的に発注再開（初回は厳しい上限）
6. **失敗時**: `./bin/deploy-prod.sh rollback ghcr.io/...@sha256:<previous>`

release 上の resume（Mix 無し・常駐ノードへ rpc）:

```bash
docker compose -f compose.prod.yaml --env-file .env.prod exec app \
  /app/bin/docker_bitflyer rpc "Bitflyer.Release.resume()"
```

`eval` は別プロセスになるため resume には使わない。rpc で同一 BEAM の ETS を更新する。

### バックアップ / 復元

```bash
./bin/backup-db.sh
# → backups/docker_bitflyer_prod_<UTC>.sql.gz
```

復元（概略。本番ではメンテナンス枠で）:

1. 新規発注を止める / `app` を止める
2. 空の DB または復旧先へ `gunzip -c backups/....sql.gz | docker compose -f compose.prod.yaml exec -T db psql -U ... -d ...`
3. `app` を上げ、突合が通るまで Ready にしない

定期取得と **隔離環境への restore 試験** を運用に含める（バックアップの存在だけでは Recoverable と言えない）。

### live 解禁チェックリスト（短い）

コードと手順があることと、別ホストのジョブが動いていることは別。下は運用側の確認。

- [ ] `TRADE_MODE=dry_run`（または paper）で入れ替え・ロールバックを一度成功している
- [ ] API キーは出金なし。ホスト `.env.prod` のみ
- [ ] BasicAuth・公開面（ホスト loopback / ACL）が有効
- [ ] 別ホストが `/health/ready` を 60s で pull し、非 ready / 到達不能でアラートする
- [ ] ホスト exporter（Linux 9100 / Windows 9182）を別ホストが scrape する
- [ ] `DISCORD_WEBHOOK_URL` を置き、起動直後の HEARTBEAT と 2 間隔欠落を人が検知できる
- [ ] `mix bitflyer.contract`（公開 GET）が緑。必要なら `--private`（署名 GET のみ。発注しない）
- [ ] [game-day.md](./game-day.md) の paper 障害注入と Stage 記録がある
- [ ] 最小ロット・厳しい risk 上限（Stage 3 以降は **P0 完了後**。現状は live 実発注禁止）
- [ ] `BITFLYER_LIVE_CONFIRM` に UTC 当日を明示したうえで `live` に切り替える
