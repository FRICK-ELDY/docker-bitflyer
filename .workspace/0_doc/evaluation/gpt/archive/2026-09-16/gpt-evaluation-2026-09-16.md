# docker-bitflyer 第2評価者 総合評価レポート（2026-09-16）

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-16 |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 対象コミット | `a3877463226ed5345f0201995c958627022da92d` — `a387746 Merge pull request #112 from FRICK-ELDY/chore/p2-9-minor-debt-triad` |
| 前回 GPT | 2026-09-13 archive（`cfaf0a526ca94c176997aa176ca30edd69bae307`） |
| 基準の正本 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 詳細 | [強み](./gpt-specific-strengths-2026-09-16.md) / [弱み](./gpt-specific-weaknesses-2026-09-16.md) / [提案](./gpt-specific-proposals-2026-09-16.md) |

相手評価者の当日評価文書および当日まとめは参照せず、現行コード、テスト、設定、証跡、自系統2026-09-13 archiveを直接確認した。`improvement-plan.md` の完了宣言は証拠にせず、対象コードと実行結果で再判定した。

## 現状の一文

**資金保全のコード骨格は個人プロジェクト水準を大きく超え、P0の内部会計も修正されたが、非ゼロ手数料の実残高一次証跡と別ホスト本番監視がないため、まだ live 実発注を解禁できる状態ではない。**

## 総合スコア

| 区分 | 加点 | 減点 | 純点 | 提案数 |
|:---|---:|---:|---:|---:|
| 今回 | **+110** | **-11** | **+99** | **8** |
| 前回 GPT（2026-09-13） | +104 | -13 | +91 | 8 |
| 前回比 | **+6** | **2点改善** | **+8** | ±0 |

## 観点別スコア

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| market-data | +11 | 0 | +11 |
| strategy | +6 | 0 | +6 |
| risk-manager / live 会計 | +18 | -5 | +13 |
| order-executor / recovery | +25 | 0 | +25 |
| datastore / cache / OTP | +10 | -2 | +8 |
| observe | +7 | -2 | +5 |
| apps/ui / 運用操作性 | +5 | 0 | +5 |
| Docker / config | +7 | -1 | +6 |
| CI / CD / security | +7 | -1 | +6 |
| テスト / 文書 / 取引完成度 / 全体設計 | +14 | 0 | +14 |
| **合計** | **+110** | **-11** | **+99** |

## improvement-plan 重点項目の再判定

| 優先 | # | 項目 | 判定 | コード・証跡による判断 |
|:---:|:---:|:---|:---:|:---|
| P0 | 1 | commission 単位 | **部分解決** | Product/Fill/Positions/LiveBalance は BTC 建てで整合した。ただし証跡自身が API に単位なし・非ゼロ実口座未確認と認め、売買別 getbalance 差分の一次証跡がない |
| P0 | 2 | ハーネス・反証回帰 | **部分解決** | 非ゼロ fee、買い/売り、部分約定、再起動、誤 fee_currency 反証は存在し precommit で通過。ただしハーネスの残高式は一次証跡と独立でない |
| P1 | 3 | HWM flush | **部分解決** | `persisted_peak` と低下後 flush は実装・回帰済み。ただし認可上昇から次の Fill/周期までの crash 窓は残る |
| P1 | 4 | 突合窓の対称化 | **解決** | mismatch 時に fill再同期→restore→snapshot再取得を1回行い、注入 fills も捨てる。入金は再試行後も halt |
| P1 | 5 | 別ホスト監視の実配備 | **未解決** | 証跡は2026-09-13同一ホスト localhost、Scheduled Task未登録、VLAN1未接続のまま |
| P1 | 6 | Game Day Stage 2 | **解決** | paper System.submit_order→建玉→Feed断拒否→復帰後再submit→Discord HTTP 2xxをMix taskと実施記録で確認 |
| P2 | 7 | BalanceCache.probe | **解決** | 認可が reserve と同一比較の probeを使い、Runnerに残高不足backoff |
| P2 | 8 | ticker bid/ask → spread | **解決** | Normalizeでbid/ask必須、crossed拒否、成行spread上限を認可へ接続 |
| P2 | 9 | 軽微負債3件 | **解決** | `ash.codegen --check`、両 test_helper の Sandbox manual、Bitflyer README更新、migration/snapshotのGit追跡を確認 |

集計は **解決5 / 部分解決3 / 未解決1**。計画上の「完了」をそのまま採用できるのは #4、#6〜#9。#1〜#3 は部品・回帰として前進したが、完了条件を厳密には満たしていない。

## 前回 GPT（2026-09-13）からの変化

### 解決済み

- **commission の JPY 決め打ち**: `Product.fee_currency/1`、`Fill.fee_currency`、base fee Position、quote mark損益へ修正。旧モデルを落とす反証回帰も追加。
- **Stage 2 の SQL / ready代替**: 専用 Mix task が paper Executor と Risk を同一 BEAM で通す。
- **Ash migration drift / 雛形 README**: precommitの drift checkとsnapshot同期、責務READMEへ更新。
- **Balance probe欠如**: 認可とreserveの比較ロジックが一本化され、残高不足loopもbackoff。
- **spread欠如**: ticker bid/askを正規化し、成行認可へ接続。
- **取引所先行の突合窓**: fill再同期を1回入れ、説明不能差分だけhaltする。

### 部分解決

- **commission 会計**: 内部実装は直ったが、実口座の非ゼロ buy/sell と getbalance差分による独立検証が未完。
- **HWM 永続化**: `persisted_peak` flushは正しいが、認可直後 crash の喪失窓が残る。

### 未解決

- **別ホスト本番監視**: VLAN1向き常駐、host exporter scrape、heartbeat欠落検知が未配備。
- **Hex外 supply chain**: Git依存・release image OSのCVE scannerなし。
- **隔離DB restore**: 手順のみで成功証跡なし。
- **長期保持**: Fill/snapshot retentionとDB aggregateなし。
- **開発Docker非root化**: 本番のみ非root。

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**。bitflyer: 1 doctest + 630 tests、ui: 38 tests、計668 tests、0 failures |
| `docker compose config --quiet` | **成功** |
| placeholder秘密値を環境注入した `docker compose -f compose.prod.yaml config --quiet` | **成功** |
| `docker compose run --rm app mix deps.audit` | **成功**。`No vulnerabilities found.`（Hex advisory範囲） |
| `git diff --check` | **成功** |

precommit は約329秒。warning/error/criticalログは故障注入テストの期待出力で、終了コードは0だった。実行していないものは、実bitFlyer発注・取消、非ゼロ手数料の実口座約定、VLAN1監視task登録、host exporter、隔離DB restore、長時間soakである。

評価開始時点から前回文書のarchive移動に伴う既存の削除・未追跡が作業ツリーにあった。本評価では指定された4文書だけを新規作成し、既存変更を上書きしていない。

## 優先順位

1. **P0: 非ゼロ fee の一次証跡** — BTC_JPY買い・売り各1件の匿名化 execution と前後 getbalance amountを採取し、現fixtureの式を独立検証する。
2. **P1: VLAN1別ホスト監視を実配備** — Scheduled Task、3 strikes通知、監視PC再起動後復帰まで記録する。
3. **P1: HWM write-behind** — 認可でpeak上昇した直後のcrashでもDB高値が残るよう監督下queueとdrainを追加する。
4. **P2: 隔離restore Game Day** — backup hashから空DB復元、migration、boot/reconcileまで定期実証する。
5. **P3: scanner / retention / dev非root** — release image CVE、日次aggregate、容量監視、開発権限を整理する。

## live 解禁可否

**不可。**

コードは fee-bearing 回帰まで通り、安全側に halt する設計も強い。しかし次の2条件が閉じていない。

1. P0 commission の売買別残高モデルが、自己作成fixtureではなく実取引所一次証跡で確認されていない。
2. P1 #5 の別ホスト本番監視が未配備で、取引PC停止時に人へ届く保証がない。

Stage 3へ進む最低条件は、匿名化した非ゼロ fee の実応答・前後残高で fixtureを確定し、VLAN1本番の `/health/ready` を別ホストから常駐監視して停止通知を実証すること。HWM crash窓も資金保全上は同時に閉じるのが望ましい。

## 忌憚ない総括

今回の改善は実質的である。前回の最大欠陥だった fee の通貨モデルは ProductからPosition、Fill、残高、DailyLossまで接続され、反証回帰も含む。突合窓、probe、spread、Game Day、Ash driftもそれぞれコードとテストで確認できた。668 testsが緑で、二重発注防止、受注不明、取消hold、Ready fail-closedの密度は個人開発の平均を明確に超える。

一方、最重要P0の証跡はまだ「公式表からの推定 + その推定で作ったfixture」であり、実取引所との独立照合ではない。さらに外部監視は手順書のままである。内部品質が高いからこそ、次に必要なのは機能追加ではなく、取引所事実と本番配備事実で最後の仮定を消すことである。
