# docker-bitflyer 第2評価者 マイナス点（2026-09-13）

| 点数 | 基準 |
|:---:|:---|
| -1 | 軽微な改善余地 |
| -2 | 重要な機能・設計の欠如 |
| -3 | 損失・二重発注・不整合を起こしうる |
| -4 | 資金保全・24/365・復帰を損なう |
| -5 | 根幹を揺るがす致命的欠陥 |

## 技術評価層 — apps/bitflyer

### risk-manager / live 会計

- **`commission` を quote 通貨と仮定しており、BTC_JPY の実手数料単位と逆である** `-4`
  > `Fill` は「spot は quote 通貨。BTC_JPY は JPY」と断定し（`fill.ex:7-11`）、`Positions` は commission の Decimal を JPY realized PnL からそのまま引く（`positions.ex:118-168, 200-213`）。`LiveBalance` も fee を quote delta にだけ入れ、base の expected amount は約定 size 全量増加とする（`live_balance.ex:260-296`）。
  >
  > しかし bitFlyer 公式の手数料表は BTC の売買手数料を「約定数量 × 率、単位 BTC」としている（[手数料一覧](https://bitflyer.com/ja-jp/s/commission)、2026-09-13確認）。つまり `commission=0.0000015` は JPY ではなく BTC である。現実の買いでは BTC amount が `size - commission` となるのに、内部 Position は size 全量、残高 expected も size 全量になる。BTC の絶対床 1 sat を超える通常手数料なら次の突合は `balance_mismatch` / `spot_inventory_inflated` で halt する。DailyLoss への控除も 0.0000015 JPY 相当となり、実質未計上である。
  >
  > テストハーネス自身が commission を quote 残高から引くため（`live_exchange_harness.ex:192-224`）、縦回帰は誤ったモデル同士の一致を証明している。`game-day.md:145-153` も private snapshot は確認したが fee-bearing execution は未検証である。P1 #4 は未解決、P0 #1/#2 と在庫は部分解決に留まる。改善方針は fee currency を product ごとに明示し、BTC_JPY では base amount・Position/equity を同じ単位で控除または JPY mark 換算してから net PnL に入れ、実応答準拠 fixture で再試験すること。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/test/support/live_exchange_harness.ex`

- **認可だけで上がった HWM は周期永続化前の crash で失われる** `-2`
  > `Risk.authorize/2` は意図的に `persist: false` で ETS peak だけを上げる（`risk.ex:601-616`）。永続化は Fill 後・突合・resume に限定され（`daily_loss.ex:1-12, 199-217`）、周期突合は既定 60 秒（`reconciler.ex:47-55`）。価格上昇時の認可で peak が上がった直後、Fill を伴わず BEAM/ホストが落ちると、再起動後は古い DB peak へ戻り、その後の drawdown を過小評価する最大約 60 秒の窓がある。
  >
  > 改善方針: HWM 上昇を非同期 write-behind queue へ即投入し、未完了時は shutdown drain、起動時は DB peak と直近 mark から安全側へ復元する。少なくとも「認可で peak 上昇→Fill なし crash→再起動」の回帰を置く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

## 技術評価層 — observe / 実行基盤

### 可観測性

- **別ホスト監視は開発同一ホストのドリルまでで、本番常駐は未配備** `-2`
  > 証跡は監視 PC と取引 Compose が「同じ物理ホスト」と明記し、Scheduled Task も未登録である（`watch-ready-evidence.md:10-29`）。到達不能 strikes の検出は有効だが、VLAN1 本番 PC を向けた常駐、host exporter scrape、Discord heartbeat 欠落検知は未完了と自己申告している（同 `:73-78`）。Vision の「人が張り付かない」「ホスト死を外から検知」はまだ実配備されていない。
  >
  > 改善方針: VLAN3 監視 PC に task を登録し、VLAN1 URL の成功・本番 PC 停止時の alert・監視 task 再起動後の継続を証跡化する。stderr だけでなく人へ届く別経路へ接続する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`, `bin/watch-ready.ps1`

### Game Day / 取引完成度

- **Stage 2 は SQL 直投入と ready 代替確認で、取引の縦経路を通していない** `-2`
  > 実施記録は paper 建玉を Executor ではなく SQL で投入し、halt 後の認可拒否も `submit` ではなく ready 503 で代替、Discord 到達も未確認としている（`game-day.md:139-153`）。Feed 断→resume の運用経路は前進したが、「Strategy/submit→Risk→paper fill→建玉→Feed断→認可拒否→resume」の Stage 2 完了条件は満たしていない。
  >
  > 改善方針: ID 衝突を避けた専用 Game Day command または Mix task で paper Executor を通し、断線中の `System.submit_order/2` 拒否、Discord 到達、復帰後の再認可まで実行記録を残す。
  > 対象ファイル: `.workspace/0_doc/architecture/env/game-day.md`

### CI / supply chain

- **Hex 以外の依存・コンテナ OS は脆弱性ゲート外** `-1`
  > README 自身が GitHub tag 依存は `mix deps.audit` 対象外と明記する（`README.md:110-117`）。CI は Hex advisory と Docker build 成否を見るだけで、lock/SBOM/OS package の CVE 判定をしない（`ci.yml:73-153`）。
  >
  > 改善方針: Trivy/Grype/OSV 等で release image と lock/SBOM を走査し、high/critical の例外期限を定義する。
  > 対象ファイル: `.github/workflows/ci.yml`, `README.md`

### datastore / DX

- **マイグレーション drift と局所 README の軽微負債が残る** `-1`
  > precommit は `ash.codegen --check` 相当を含まない（`mix.exs:41-55`）。今回も Fill/HWM Resource と migration の整合が資金保全に直結する一方、`apps/bitflyer/README.md:1-17` は依然 Phoenix/Mix 雛形の TODO である。
  >
  > 改善方針: CI に Ash drift 検査を追加し、アプリ README は境界・主要 mix task・正本データだけに絞って更新する。
  > 対象ファイル: `mix.exs`, `apps/bitflyer/README.md`

### 本番復旧

- **DB backup 手順はあるが隔離 restore の実証がない** `-1`
  > README は backup/rollback の入口を示す（`README.md:78-88`）一方、今回の実行・Game Day 記録に PostgreSQL volume 消失からの restore と Reconcile 復帰証跡はない。Recoverable の最終保証は backup 作成ではなく復元成功である。
  >
  > 改善方針: 隔離 Compose project へ最新 backup を定期 restore し、migration→boot→Ready または期待 halt までを記録する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `bin/backup-db.sh`

**減点合計: -13**
