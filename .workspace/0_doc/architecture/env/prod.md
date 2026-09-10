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

- 注文サイズ、建玉、日次損失、発注回数にハードリミットを置く
- 価格が直近相場から乖離した注文は出さない
- 連続障害、署名エラー、想定外残高変動でサーキットブレーカを開く
- サーキットが開いたら、新規注文を止め、必要なら全取消方針を設定で選べるようにする
- API キーは取引に必要な権限のみ。出金は付けない
- デプロイ後は、まず参照系と dry-run 相当の確認を経てから実弾を解禁する

## 監視とアラート

最低限、次を見る。

- コンテナの死活と再起動ループ
- WebSocket の切断時間とデータ遅延
- 未約定注文の滞留
- 内部状態と取引所状態の不一致
- 日次損益とリミット接近
- ディスク / メモリ / 時刻同期

率・推移の見方:

- **ログ**: prod 既定で `Telemetry.Metrics.ConsoleReporter` が低頻度ドメイン（disconnect / rejected / order / reconcile / circuit / readiness / health）をイベント毎に stdout へ出す。tick・Phoenix・VM は除外。長期保管で埋もれる場合は `UI_METRICS_CONSOLE=false`
- **画面**: `https://…/ops/dashboard`（Status と同じ `UI_BASIC_AUTH_*`）。loopback / ACL 配下で公開する。Ecto・RequestLogger・OS env 表示・破壊操作はオフ。Processes / ETS / Applications はライブラリ既定で残るため、Status 単独より OTP 内省の到達面が広い
- Prometheus エクスポートは未導入（必要になったら後続）

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
- Feed 切断・市場データ stale は `GET /health/ready` が 503（`reason` が `feed_disconnected` / `stale_market_data` 等）。Compose の `/health/live` は落とさない
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

必須通貨のうち tip が無いものだけを書く（欠落分の補完可）。全必須通貨に tip がある場合は `baseline_already_complete`。live 運用中の残高更新は引き続き紙の append ではなく取引所突合が正本。

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

`mix bitflyer.halt` は **RiskState 永続化の補助**。`compose exec` の Mix は別 BEAM のため常駐の Readiness ETS は更新しない。ただし authorize は永続 RiskState を見るので新規発注は拒否される。ETS 表示を揃えるには StatusLive / rpc / `restart app`。

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

- [ ] `TRADE_MODE=dry_run`（または paper）で入れ替え・ロールバックを一度成功している
- [ ] API キーは出金なし。ホスト `.env.prod` のみ
- [ ] BasicAuth・公開面（ホスト loopback / ACL）が有効
- [ ] Discord 等の心拍が届く（未設定ならログ監視を代替とし、後続で必須化）
- [ ] 最小ロット・厳しい risk 上限
- [ ] `BITFLYER_LIVE_CONFIRM` に UTC 当日を明示したうえで `live` に切り替える
