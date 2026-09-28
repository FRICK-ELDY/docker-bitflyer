# 第1評価者（Claude Opus 5）— 提案（0点）詳細 2026-09-29

対象コミット: `80c486f`（`docs: 作業PCの ready 常駐で監視条件を閉じ、解除手順を残す`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
種別: **同日の上書き再評価**（P1 #3 の実装と P1 #5 の完了宣言の後で書き直した）

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

**件数 12 件。点数は 0（加点も減点もしない）。**

提案は批判ではなく「次のステップ」である。マイナス点の最小修正はそちらに改善方針として書いたので、ここには**最小修正を超えて価値を足すもの**を置く。

朝の下書きからの差分は 2 件である。

- **削除**: 「`prod.md` に強制終了では HWM が戻ることを明記する」。P1 #3 の同期化で前提が消えたため、提案として不要になった。
- **追加**: 「監視の `READY_URL` を VLAN1 本番 PC へ向け、ホスト死検知を記録する」。所有者が P1 #5 の見方を下げたので**減点はしない**が、Vision の 24/365 に対して最も効く次の一手なので提案として残す。
- **追加**: 「`:write_behind` の改名と HWM 往復のレイテンシ観測」。

---

## 技術評価層 — apps/bitflyer

### 手数料・銘柄

- **一次証跡のある銘柄だけを live 認可する evidence allowlist** `0`
  > マイナス点（`-1`）で挙げた「証跡は `BTC_JPY` だけなのに認可は spot 8 銘柄を通す」の、最小修正を超えた形である。
  >
  > `Product` に `@evidenced_products`（当面 `BTC_JPY` のみ）を持ち、`Risk.check_live_product/2`（risk.ex L262）と `LiveSafety.assert_live_products!/1`（live_safety.ex L50-74）がそちらを見る。新しいペアは `commission-unit-evidence.md` に実測表（買い・売りの `size` / `price` / `commission` / 実差分）を追記したうえで集合へ入れる、という手順を `prod.md` に 3 行で固定する。
  >
  > 効果は 2 つ。(1) 銘柄を増やすときに「証跡を書く」が必須の一手順になる。(2) `Product.fee_currency/1` の moduledoc にある「他の spot は仮定である」という但し書き（product.ex L108-110）が、コメントではなく型で表現される。P0 #1 で作った「観測して記録する」規律を、次の銘柄へそのまま引き継げる。**優先度: 高**
  > 参考: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

### 停止と復帰

- **halt イベントの追記テーブル（`RiskState` は現在値専用にする）** `0`
  > マイナス点（`-1`）で挙げた `halted_at` 上書き（reconciler.ex L390-398）の、厚いほうの解である。
  >
  > `halt_events`（`id` / `reason` / `trade_mode` / `opened_at` / `closed_at` / `operator` / `detail`）を足し、halt のたびに追記、`Resume` が最新行の `closed_at` を埋める。`RiskState` は「いま止まっているか」だけを持つ。
  >
  > これがあると「今日は何回止まったか」「どの理由が一番長く止めたか」が SQL 1 本で出る。Status UI の halt 復帰手順の横に直近 5 件を並べれば、運用者が「またこれか」を認識できる。Vision の成功の見方（L41-45）にある「安全側に倒れたことを後から説明できる」に、時間軸を足す変更である。**優先度: 中**
  > 参考: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

- **`RiskState` にモード次元を入れる（少なくとも現状維持を明文化する）** `0`
  > 現在の `RiskState` は `name == "default"` の単一行で、`trade_mode` を持たない。前サイクルで Game Day が live の停止理由を消しうる形でこの設計が表に出た。タスク側（読んで中断する）で閉じたので実害は無いが、**グローバル 1 行という設計判断そのものが overview に書かれていない**。
  >
  > 選択肢は 3 つ。(a) 現状維持と決めて「停止はプロセス全体の状態であり、モードは同時に 1 つしか動かない」と overview に 1 行書く。(b) `RiskState` に `trade_mode` を足して identity を `{name, trade_mode}` にする。(c) `name` をモード別にする。
  >
  > 資金保全には効かないので提案に留めるが、**(a) でよいから明文化する**のが次の評価者・次の自分のためになる。**優先度: 低**
  > 参考: `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`, `.workspace/0_doc/architecture/overview.md`

### risk-manager / HWM

- **`:write_behind` の改名と、HWM 往復のレイテンシ観測（新規）** `0`
  > P1 #3 の同期化で、オプション名と実態がずれた。`schedule_write_behind/4`（daily_loss.ex L393-403）は名前のとおり「後で書く」ではなく、`PeakWriter` の upsert 完了まで待つ write-through である。
  >
  > やること 3 つ。(1) `:write_behind` を `:write_through`（または `:durable_peak`）へ改名し、`schedule_write_behind/4` も名前を合わせる。(2) `PeakWriter.enqueue/4` の所要時間を telemetry に出す。(3) `p99` と「5 秒タイムアウトで `:unsynced` へ倒れた回数」を metrics に載せる。
  >
  > (2)(3) が要るのは、この往復が**認可の応答時間の上限を決めるようになった**ためである。いまは遅い DB と速い DB の区別が運用側から見えない。`@retry_ms` の指数化（weaknesses の改善方針）と同時にやると、`PeakWriter` の状態（`pending_count` / `retry_count` / 最古の未永続経過秒）を `/health/ready` の JSON か Status UI に出すところまで一度で届く。いまの `pending_count/1`（peak_writer.ex L80-89）はテスト用にしか使われていない。**優先度: 中**
  > 参考: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

### strategy

- **live で有効化できる薄い戦略 1 本** `0`
  > マイナス点（`-1`）の反転条件である。必要なのは高度さではなく、**エントリとエグジットの条件が明示され、`LiveSafety.assert_strategy_allowed!/2`（live_safety.ex L93-103）の禁止リストに載らないモジュールが 1 本ある**ことである。`Strategy` behaviour と `Revision`（パラメータ適用履歴）は既にあるので、追加は `evaluate/3` の実装 1 本とテストで足りる。
  >
  > これが入ると「起動 → 購読 → 判定 → リスク → 発注 → 突合 → 停止/再開」の全段が本物になり、Game Day Stage 2 の縦経路もダミーではなくなる。**優先度: 低**（他の解禁条件が揃ってから）
  > 参考: `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### market-data

- **private execution WebSocket による約定通知（ポーリングの削減）** `0`
  > 現在の live 約定反映は `LiveFills.sync_open_orders/1` のポーリングである。bitFlyer Lightning は private の `child_order_events` / `parent_order_events` を提供しているので、購読すれば約定の反映遅延と REST 回数が同時に減る。
  >
  > 効くのは突合窓である。いまは `fill_sync_retries` で「取引所先行 / Fill 未同期」を 1 回だけ救済しているが、push で埋まっていれば救済に入る頻度自体が下がる。既に `Socket.Client` behaviour と `Feed` の ACK 待ち再接続があるので、認証つきチャンネルの購読を足す形になる。**優先度: 中**（live 連続運用に入ってから効く）
  > 参考: `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

---

## 横断評価層

### テスト戦略

- **プロパティベーステスト（金額・数量・冪等キー・HWM 単調性）** `0`
  > `stream_data` は依存に無く、706 本はすべて例示ベースである。効く先が 3 つある。
  >
  > 1. **HWM の単調性**: `DailyEquityPeak.upsert/3` と `PeakWriter` の組に、任意順・任意個の `(mode, day, peak)` 列を流したあと DB の値が最大値と一致する、という性質。`put_pending/5`（peak_writer.ex L371-385）と `drop_covered/3`（L401-415）の比較はここで効く
  > 2. **Decimal の丸め**: `LiveBalance.explain/4`（live_balance.ex L66）に対して、任意の Fill 列で「支払超過側だけが許容される」「増加は必ず拒否される」という性質
  > 3. **冪等キー**: 同一 `internal_order_id` を任意の順序・並行度で流しても Order が 1 行で、REST 呼び出しが 1 回以下、という性質
  >
  > `Decimal` と単調性は**例示テストが最も取りこぼしやすい**種類なので、1 と 2 だけでも入れる価値がある。**優先度: 中**
  > 参考: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

### 可観測性

- **監視の `READY_URL` を VLAN1 本番 PC へ向け、ホスト死検知を記録する（新規）** `0`
  > P1 #5 の完了は採用した（見方が作業PCの常駐へ書き換えられ、証跡とスクリプトがそれを満たす）。**この提案は減点ではなく、次の段である。**
  >
  > 現在の常駐は `READY_URL` が同一ホストの開発 Compose（`127.0.0.1:4000`）で、監視と対象が同じ物理ホストに乗っている（watch-ready-evidence.md L105）。したがって検知できるのは「アプリが 503 を返す」「ポートが死んだ」までで、**ホストごと落ちた場合（Windows Update の再起動、WSL2 のハング）は沈黙と正常の区別が付かない**。Vision L122 が本番 PC の予期しない再起動をリスクとして明記し、overview L169 が「同一ホスト死の検知は取引ホストの外」と書いているのは、まさにここである。
  >
  > やることは配線だけである。`$env:READY_URL` を VLAN1 本番 PC へ向けて `bin/register-watch-ready-task.ps1` を実行し（証跡 L64-68 に手順がある）、取引ホストを実際に止めて `ready watch alert` が出た記録を証跡に足す。公開面が loopback なら Tailscale / SSH トンネルを挟む（証跡 L71）。1 回の作業で閉じ、`prod.md` の Uptime Kuma 例と置き場所が重なる。**優先度: 高**
  > 参考: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `bin/register-watch-ready-task.ps1`, `.workspace/0_doc/architecture/env/prod.md`

- **Prometheus / SLO（時系列をホスト外へ）** `0`
  > 現在は `LiveDashboard`（プロセス内）と `ConsoleReporter`（stdout）が metrics の出口で、どちらも**プロセスが死ぬと過去が消える**（overview L166-167）。`compose.observe.yaml` にホスト exporter があるが、アプリ側のドメイン metrics は載っていない。
  >
  > `telemetry_metrics_prometheus_core` で `/metrics` を出し、別ホストから scrape する。メタデータは既に allowlist で絞られている（telemetry.ex L129-134）ので、ラベルに `internal_order_id` が漏れる心配が構造的に小さいのは有利である。
  >
  > これが入ると「拒否率がいつから上がったか」「再接続が何回目で成功しているか」が率と推移で追える。上の `READY_URL` 差し替えと置き場所が重なるので、**同時にやると安い**。**優先度: 中**
  > 参考: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `compose.observe.yaml`, `.workspace/0_doc/architecture/env/prod.md`

### セキュリティ・依存

- **Hex 以外の脆弱性スキャン（release イメージ / lock の Trivy 等）** `0`
  > `ci-cd.md` が自ら非保証と書いている範囲である（GitHub タグ依存と Docker イメージ）。`Dockerfile.prod` は base イメージに依存しており、`mix deps.audit` はここを一切見ない。
  >
  > CI の `docker-prod` ジョブは既に `Dockerfile.prod` をビルドしている（ci.yml L134-150）ので、そのイメージに対して Trivy を 1 ステップ足すだけで済む。high 以上を fail、ただし**例外に期限を付ける**（`.trivyignore` にコメントで失効日を書き、期限切れを落とす）運用にすると、無期限の例外が溜まらない。**優先度: 低**
  > 参考: `.github/workflows/ci.yml`, `Dockerfile.prod`, `.workspace/0_doc/architecture/ci-cd.md`

### 運用・復旧

- **隔離環境での restore 証跡（backup hash → 空 DB → migration → boot/reconcile）** `0`
  > `bin/backup-db.sh` と手順は揃っているが、「実際に空の DB へ戻して起動突合まで通した」記録が無い。Vision の Recoverable（L35）は手順ではなく**成功記録**で担保したい種類の原則である。
  >
  > 1 回やれば閉じる。backup の SHA-256 → 別 Compose プロジェクトの空 DB へ restore → `mix ash.setup` → `TRADE_MODE=paper` で起動 → `/health/ready` が 200、を `.workspace/0_doc/architecture/env/` に 1 ファイルで残す。`watch-ready-evidence.md` と同じ書式でよい。**優先度: 中**
  > 参考: `bin/backup-db.sh`, `.workspace/0_doc/architecture/env/prod.md`

- **データ保持方針と当日実現 net の DB 集計化** `0`
  > `DailyLoss` の当日実現 net は `Fill` を全行メモリに読んでから合計する。当日境界で絞られているので無限には育たないが、日次出来高が増えれば `reload` のたびに行数に比例したコストがかかる。`Ash` の集計へ寄せれば読むのは 1 行になる。
  >
  > あわせて `fills` / `balance_snapshots` の retention を「当面なし」でもよいので明文化する。24/365 で回すなら「いつ表が肥大するか」の判断基準が要る。**優先度: 低**
  > 参考: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

---

## 優先度まとめ

| 優先度 | 提案 |
|:---|:---|
| 高 | 一次証跡のある銘柄だけを live 認可する evidence allowlist |
| 高 | 監視の `READY_URL` を VLAN1 本番 PC へ向け、ホスト死検知を記録する |
| 中 | halt イベントの追記テーブル |
| 中 | `:write_behind` の改名と HWM 往復のレイテンシ観測 |
| 中 | プロパティベーステスト（HWM 単調性・Decimal 丸め） |
| 中 | Prometheus / SLO（`READY_URL` 差し替えと同時に） |
| 中 | private execution WebSocket |
| 中 | 隔離 restore 証跡 |
| 低 | live で有効化できる薄い戦略 1 本 |
| 低 | `RiskState` のモード次元（少なくとも現状維持の明文化） |
| 低 | Hex 外 scanner（Trivy） |
| 低 | データ保持方針と当日実現 net の DB 集計化 |

**合計 12 件。すべて 0 点。**
