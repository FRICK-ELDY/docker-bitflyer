# docker-bitflyer 第2評価者 マイナス点（2026-09-16）

| 点数 | 基準 |
|:---:|:---|
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | 損失・二重発注・不整合を起こしうる |
| -4 | 資金保全・24/365・復帰を損なう |
| -5 | 根幹を揺るがす致命的欠陥 |

## 技術評価層 — apps/bitflyer

### risk-manager / live 会計

- **commission の内部整合は直ったが、売買別の実残高挙動を一次証跡で確定していない** `-3`
  > `Product.fee_currency/1`、`Fill.fee_currency`、`Positions`、`LiveBalance`、ハーネスは BTC_JPY の fee を BTC として一貫して扱うよう修正された（`product.ex:72-89`, `positions.ex:20-47,304-338`, `live_balance.ex:267-303`）。しかし証跡自身が「API レスポンスは単位フィールドを持たない」「実口座の非ゼロ getexecutions は置いていない」と明記し、根拠にした公式表も Lightning 現物を「各通貨ペアで異なる」とするだけで、BTC_JPY の買い・売りそれぞれの `getbalance` 差分までは明記していない（`commission-unit-evidence.md:5-25`）。
  >
  > とくに売りは、`commission` を BTC と記録しながら BTC amount は `-size`、JPY amount は `size*price - commission*price` とするモデルである（`live_balance.ex:290-302`, `live_exchange_harness.ex:221-241`）。fixture はこのモデルを実装者が与えた値であり、独立した取引所事実ではない。モデルが違えば約定後に halt するか、損益・Position が誤る。改善方針は、秘密を除去した非ゼロ手数料の実 `getexecutions` と約定前後 `getbalance` を買い・売り各1件採取し、amount 差分を fixture として固定すること。少なくとも Stage 3 前は observe-only で確認し、現状の P0 #1 完了宣言を「コード完了・実証待ち」に戻すべきである。
  > 対象ファイル: `.workspace/0_doc/architecture/env/commission-unit-evidence.md`, `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/test/support/live_exchange_harness.ex`

- **認可だけで上がった HWM は次の flush 前の crash で失われる** `-2`
  > `Risk.authorize/2` は `persist: false` で ETS peak だけを上げる（`risk.ex:640-647`）。`persisted_peak` による後続 flush は正しく追加されたが、DB 書込み点は Fill 後・突合・resume の `Equity.enforce` であり、周期突合は既定60秒である（`daily_loss.ex:200-218,271-288`, `reconciler.ex:47-55,104-117`）。認可直後、Fill も次の周期も来る前に BEAM/ホストが落ちれば HWM は古い DB 値へ戻る。前回 GPT の「最大約60秒の喪失窓」は狭まっておらず、P1 #3 は flush 機構としては実装済みでも前回指摘は未解決である。
  >
  > 改善方針は、peak 上昇時に監督下 write-behind worker へ単調 upsert を即投入し、shutdown drain と再起動回帰を追加すること。ホットパスを同期 DB 往復に戻す必要はない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

## 技術評価層 — observe / 実行基盤

### 可観測性

- **別ホスト監視は本番 VLAN1 に未配備で、ホスト死をまだ検知できない** `-2`
  > 証跡の最終更新は2026-09-13のままで、監視対象は同一物理 PC の localhost 開発 Compose、Scheduled Task は未登録、VLAN1 本番 URL への常駐も未と明記される（`watch-ready-evidence.md:10-29,73-78`）。`prod.md` の live チェックリストも VLAN1 ready pull、host exporter、heartbeat 欠落検知が未完了である（`prod.md:412-425`）。スクリプトと手順はあるが、Vision の「人が張り付かなくても」「異常時は人に届く」は配備事実で評価すべきである。
  >
  > 改善方針は、VLAN3 作業 PC に Scheduled Task を登録し、VLAN1 本番停止時の3 strikes、通知到達、監視 PC 再起動後の自動復帰を日時付きログで残すこと。これが残る間は live 解禁不可。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `.workspace/0_doc/architecture/env/prod.md`, `bin/register-watch-ready-task.ps1`

### Docker / DX

- **開発コンテナは root 実行のまま** `-1`
  > 本番 runner は `USER app` だが、開発 `Dockerfile` はユーザーを作らず root のまま bind mount 上で Mix を動かす（`Dockerfile:1-20`, `Dockerfile.prod:45-69`）。本番資金経路の欠陥ではないが、生成物所有権とホスト侵害時の権限を不要に広げる。
  >
  > 改善方針は開発用にも固定 UID/GID の非 root ユーザーを設け、Compose volume の書込みを確認すること。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

## 横断評価層

### セキュリティ / supply chain

- **Hex 以外の依存とコンテナ OS は脆弱性ゲート外** `-1`
  > CI は `mix deps.audit` と本番 image のビルド成功を確認するが、`heroicons` / `daisyui` の Git 依存、ベース image、OS package の CVE 判定をしない（`ci.yml:73-153`, `ci-cd.md:45-52`）。文書化されている点は良いが、既知 high/critical があっても CD 前提の CI workflow は成功しうる。
  >
  > 改善方針は release image と lock/SBOM を Trivy/Grype/OSV 等で走査し、例外に期限を持たせること。
  > 対象ファイル: `.github/workflows/ci.yml`, `.workspace/0_doc/architecture/ci-cd.md`

### Recoverable / 長期運用

- **DB backup はあるが隔離 restore の成功証跡がない** `-1`
  > 復元手順と「隔離環境への restore 試験を運用に含める」は文書化済みだが、日時、backup hash、復元先、migration、boot/reconcile 結果の証跡はない（`prod.md:397-410`）。Recoverable の保証は pg_dump の存在ではなく復元成功である。
  >
  > 改善方針は、隔離 Compose project へ定期 restore し、migration 後に Ready または期待どおりの安全 halt まで自動確認して記録すること。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `bin/backup-db.sh`

- **Fill / BalanceSnapshot の保持・集約方針が未定** `-1`
  > `DailyLoss.sum_realized/3` は当日 Fill を全件 `Ash.read` して Elixir 側で加算する（`daily_loss.ex:756-770`）。24/365 で Fill と snapshot が増え続ける一方、保持期間、DB 容量閾値、aggregate、VACUUM 判断がまだない。現時点の正しさを壊さないが、長期運用ほど起動・reload コストが増える。
  >
  > 改善方針は監査保持期間を明記し、日次 aggregate または DB 側 `sum`、容量アラートを導入すること。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`

**減点合計: -11**
