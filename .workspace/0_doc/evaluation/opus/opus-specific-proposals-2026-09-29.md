# 第1評価者（Claude Opus 5）— 提案（0点）詳細 2026-09-29

対象コミット: `afc46bb`（`Merge pull request #123 from FRICK-ELDY/fix/p2-10-completion-evidence`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
    10|| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

**件数 12 件。点数は 0（加点も減点もしない）。**

提案は批判ではなく「次のステップ」である。マイナス点に挙げた項目の最小修正はそちらに改善方針として書いたので、ここには**最小修正を超えて価値を足すもの**と、improvement-plan の P3 / 後回し欄に載っているものを置く。

---

## 技術評価層 — apps/bitflyer

### 手数料・銘柄

    20|- **一次証跡のある銘柄だけを live 認可する evidence allowlist** `0`
  > マイナス点（`-1`）で挙げた「証跡は `BTC_JPY` だけなのに認可は spot 8 銘柄を通す」の、最小修正を超えた形である。
  >
  > `Product` に `@evidenced_products`（当面 `BTC_JPY` のみ）を持ち、`Risk.check_live_product/2` と `LiveSafety.assert_live_products!/1` がそちらを見る。新しいペアは `commission-unit-evidence.md` に実測表（買い・売りの `size` / `price` / `commission` / 実差分）を追記したうえで集合へ入れる、という手順を `.cursor/rules` か `prod.md` に 3 行で固定する。
  >
  > 効果は 2 つある。(1) 銘柄を増やすときに「証跡を書く」が必須の一手順になる。(2) `Product.fee_currency/1` の moduledoc にある「他の spot は仮定である」という但し書きが、コメントではなく型で表現される。P0 #1 で作った「観測して記録する」という規律を、次の銘柄へそのまま引き継げる。
  > 参考: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

### 停止と復帰

    30|- **halt イベントの追記テーブル（`RiskState` は現在値専用にする）** `0`
  > マイナス点（`-1`）で挙げた `halted_at` 上書きの、厚いほうの解である。
  >
  > `halt_events`（`id` / `reason` / `trade_mode` / `opened_at` / `closed_at` / `operator` / `detail`）を足し、`Circuit.open/2` が追記、`Circuit.close/1` が最新行の `closed_at` を埋める。`RiskState` は「いま止まっているか」だけを持つ。
  >
  > これがあると「今日は何回止まったか」「どの理由が一番長く止めたか」が SQL 1 本で出る。Status UI の halt 復帰手順の横に直近 5 件を並べれば、運用者が「またこれか」を認識できる。Vision の成功の見方（L41-44）にある「安全側に倒れたことを後から説明できる」に、時間軸を足す変更である。retention は P3 #11 と一緒に決めればよい。
  > 参考: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`, `apps/bitflyer/lib/bitflyer/observe/exposure.ex`

- **`RiskState` にモード次元を入れる（または `name` をモード別にする）** `0`
  > 現在の `RiskState` は `name == "default"` の単一行で、`trade_mode` を持たない（circuit.ex L16, L150-158）。前サイクルで Game Day が live の停止理由を消しうる、という形でこの設計が表に出た。今サイクルはタスク側（読んで中断する）で閉じたので実害は無いが、**グローバル 1 行という設計判断そのものが overview に書かれていない**。
    40|  >
  > 選択肢は 3 つ。(a) 現状維持と決めて「停止はプロセス全体の状態であり、モードは同時に 1 つしか動かない」と overview に 1 行書く。(b) `RiskState` に `trade_mode` を足して identity を `{name, trade_mode}` にする。(c) `name` を `"default:live"` のようにモード別にする。
  >
  > 資金保全には効かないので提案に留めるが、**(a) でよいから明文化する**のが次の評価者・次の自分のためになる。今は「単一行である」という事実がコードを読まないと分からない。
  > 参考: `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`, `.workspace/0_doc/architecture/overview.md`

- **`PeakWriter` の再試行に指数バックオフと、`DailyLoss` 側のログ抑制** `0`
  > マイナス点（`-1`）の最小修正は `@retry_ms` の指数化だが、そこから一歩進めるなら「再試行の状態そのものを観測できるようにする」ことである。
  >
  > `PeakWriter` に `retry_count` と `first_failed_at` を持たせ、`prep_stop` の `drain` 失敗や `/health/ready` の JSON、Status UI に「HWM 未永続 N 件・最古 M 秒前」を出す。いまは `pending_count/1` がテスト用にあるだけで、運用者からは見えない（peak_writer.ex L72-84）。
  >
    50|  > DB が復旧したあとに「何件詰まっていて何件書けたか」が残ると、`persist_failed` halt からの復帰判断が速くなる。
  > 参考: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/health.ex`

### strategy

- **live で有効化できる薄い戦略 1 本** `0`
  > マイナス点（`-1`）の反転条件である。improvement-plan の「意図的に後回し」欄も、解禁後に薄い live 戦略 1 本は例外的に先行可としている（improvement-plan.md L76）。
  >
  > 必要なのは高度さではなく、**エントリとエグジットの条件が明示され、`LiveSafety` の禁止リストに載らないモジュールが 1 本ある**ことである。`Strategy` behaviour と `Revision`（パラメータ適用履歴）は既にあるので、追加は `evaluate/3` の実装 1 本とテストで足りる。
  >
  > これが入ると「起動 → 購読 → 判定 → リスク → 発注 → 突合 → 停止/再開」の全段が本物になり、Game Day Stage 2 の縦経路もダミーではなくなる。
    60|  > 参考: `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`, `apps/bitflyer/lib/bitflyer/strategy/revision.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

### market-data

- **private execution WebSocket による約定通知（ポーリングの削減）** `0`
  > 現在の live 約定反映は `LiveFills.sync_open_orders/1` のポーリングで、`System.submit_order/2` の認可前に 1 回走る（order_executor.ex L30-39, L260-278）。bitFlyer Lightning は private の `child_order_events` / `parent_order_events` を提供しているので、これを購読すれば約定の反映遅延と REST 回数が同時に減る。
  >
  > 効くのは突合窓である。いまは `fill_sync_retries` で「取引所先行 / Fill 未同期」を 1 回だけ救済しているが（reconcile.ex L290-354）、push で埋まっていれば救済に入る頻度自体が下がる。
  >
  > 既に `Socket.Client` behaviour と `Feed` の ACK 待ち再接続があるので、認証つきチャンネルの購読を足す形になる。improvement-plan の後回し欄にも載っている（L77）。**優先度: 中**（live 連続運用に入ってから効く）
    70|  > 参考: `apps/bitflyer/lib/bitflyer/market_data/socket/client.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

---

## 横断評価層

### テスト戦略

- **プロパティベーステスト（金額・数量・冪等キー・HWM 単調性）** `0`
  > `stream_data` は依存に無く、`property` 宣言も 0 件である（`apps/` 全体を検索して該当なし）。705 本はすべて例示ベースである。
  >
  > 効く先が 3 つある。
    80|  >
  > 1. **HWM の単調性**: `DailyEquityPeak.upsert/3` と `PeakWriter` の組に対して、任意順・任意個の `(mode, day, peak)` 列を流したあと DB の値が最大値と一致する、という性質。`drop_covered/3` や `put_pending/5` の比較（peak_writer.ex L376-419）はここで効く
  > 2. **Decimal の丸め**: `LiveBalance.explain/4` の `fee_allowance/3` と `fee_explained?/2`（live_balance.ex L247-258, L331-355）に対して、任意の Fill 列で「支払超過側だけが許容される」「増加は必ず拒否される」という性質
  > 3. **冪等キー**: 同一 `internal_order_id` を任意の順序・並行度で `submit/2` に流しても Order が 1 行で、REST 呼び出しが 1 回以下、という性質
  >
  > improvement-plan の後回し欄（L77「プロパティ / モデルベース試験の本格導入」）にあるとおり急ぎではない。ただし `Decimal` と単調性は**例示テストが最も取りこぼしやすい**種類なので、1 と 2 だけでも入れる価値がある。**優先度: 中**
  > 参考: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`

### 可観測性

    90|- **Prometheus / SLO（時系列をホスト外へ）** `0`
  > improvement-plan P3 #12。現在は `LiveDashboard`（プロセス内）と `ConsoleReporter`（stdout）が metrics の出口で、どちらも**プロセスが死ぬと過去が消える**（overview L165-166）。`compose.observe.yaml` にホスト exporter があるが、アプリ側のドメイン metrics は載っていない。
  >
  > `telemetry_metrics_prometheus_core` で `/metrics` を出し、別ホストから scrape する。カーディナリティは既に allowlist で絞られているので（telemetry.ex L36）、ラベルに `internal_order_id` が漏れる心配が構造的に小さいのは有利である。
  >
  > これが入ると「拒否率がいつから上がったか」「再接続が何回目で成功しているか」が率と推移で追える。別ホスト監視（P1 #5）を立てる作業と置き場所が重なるので、**同時にやると安い**。
  > 参考: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `compose.observe.yaml`, `.workspace/0_doc/architecture/env/prod.md`

### セキュリティ・依存

   100|- **Hex 以外の脆弱性スキャン（release イメージ / lock の Trivy 等）** `0`
  > improvement-plan P3 #13。`ci-cd.md` L73-74 が自ら非保証と書いている範囲である（GitHub タグ依存と Docker イメージ）。`Dockerfile.prod` は `debian:bookworm-slim` と `elixir:1.18.3-otp-27-slim` に依存しており、`mix deps.audit` はここを一切見ない。
  >
  > CI の `docker-prod` ジョブは既に `Dockerfile.prod` をビルドしている（ci.yml L137-154）ので、そのイメージに対して Trivy を 1 ステップ足すだけで済む。high 以上を fail、ただし**例外に期限を付ける**（`.trivyignore` にコメントで失効日を書き、期限切れを落とす）運用にすると、無期限の例外が溜まらない。
  > 参考: `.github/workflows/ci.yml`, `Dockerfile.prod`, `.workspace/0_doc/architecture/ci-cd.md`

### 運用・復旧

- **隔離環境での restore 証跡（backup hash → 空 DB → migration → boot/reconcile）** `0`
  > improvement-plan P3 #14。`bin/backup-db.sh` と手順は揃っているが、「実際に空の DB へ戻して起動突合まで通した」記録が無い。Vision の Recoverable（L34）は手順ではなく**成功記録**で担保したい種類の原則である。
   110|  >
  > 1 回やれば閉じる。backup の SHA-256 → 別 Compose プロジェクトの空 DB へ restore → `mix ash.setup` → `TRADE_MODE=paper` で起動 → `/health/ready` が 200、を `.workspace/0_doc/architecture/env/` に 1 ファイルで残す。`watch-ready-evidence.md` と同じ書式でよい。
  > 参考: `bin/backup-db.sh`, `.workspace/0_doc/architecture/env/prod.md`

- **データ保持方針と `sum_realized/3` の DB 集計化** `0`
  > improvement-plan P3 #11。`DailyLoss.sum_realized/3` は当日分の `Fill` を**全行メモリに読んでから** `Enum.reduce` で合計する（daily_loss.ex L901-918）。当日境界で絞られているので無限には育たないが（前サイクルで確認済み）、日次出来高が増えれば `reload` のたびに行数に比例したコストがかかる。
  >
  > `Ash` の集計（`Ash.Query.aggregate` / `sum`）へ寄せれば、読むのは 1 行になる。あわせて `fills` / `balance_snapshots` の retention を「当面なし」でもよいので明文化する。24/365 で回すなら「いつ表が肥大するか」の判断基準が要る。
  > 参考: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `apps/bitflyer/lib/bitflyer/trading/fill.ex`

   120|- **`prod.md` に「強制終了では HWM が戻る」ことと、その運用対策を明記する** `0`
  > マイナス点（`-1`）で挙げた残差の、コードを増やさない閉じ方である。
  >
  > ノード強制終了で `DailyLoss` と `PeakWriter` の両メモリが消えると DB 未着の高値が残らない（peak_writer.ex L13-14）。これは設計上の選択（認可の戻り前に DB へ行かない）であって、バグではない。だとすれば**運用文書に条件と対策を書くのが正しい閉じ方**である。
  >
  > 書くこと: (1) SIGTERM 経由の停止（Compose stop、Windows Update の再起動）は `prep_stop` の `drain` を通るので影響しない、(2) 影響するのは電源断・`kill -9`・WSL2 の強制終了、(3) 対策は `.wslconfig` とホスト電源設定、(4) 戻った場合の影響は「当日ドローダウンが一段低い基準から測り直される＝保護が緩む方向」。improvement-plan P1 #3 の部分完了は維持したまま、残差の扱いだけ確定できる。
  > 参考: `.workspace/0_doc/architecture/env/prod.md`, `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`

---

   130|## 優先度まとめ

| 優先度 | 提案 |
|:---|:---|
| 高 | 一次証跡のある銘柄だけを live 認可する evidence allowlist |
| 高 | `prod.md` に強制終了時の HWM 残差と運用対策を明記 |
| 中 | halt イベントの追記テーブル |
| 中 | プロパティベーステスト（HWM 単調性・Decimal 丸め） |
| 中 | Prometheus / SLO（別ホスト監視と同時に） |
| 中 | private execution WebSocket |
   140|| 中 | 隔離 restore 証跡 |
| 低 | `PeakWriter` の再試行状態を運用面に出す |
| 低 | live で有効化できる薄い戦略 1 本（解禁条件が揃ってから） |
| 低 | Hex 外 scanner（Trivy） |
| 低 | `RiskState` のモード次元（少なくとも現状維持の明文化） |
| 低 | データ保持方針と `sum_realized` の DB 集計化 |

**合計 12 件。すべて 0 点。**
