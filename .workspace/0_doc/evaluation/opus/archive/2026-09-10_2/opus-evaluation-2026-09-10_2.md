# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-10_2

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10（第2回 / `_2`） |
| 評価者 | Claude Opus 5（第1評価者） |
| 種別 | 再評価（前回 2026-09-10） |
| 対象コミット | `2c21cf9`（`Merge pull request #68 from FRICK-ELDY/fix/p3-cleanup-noise`） |
| 基準 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 詳細 | [strengths](./opus-specific-strengths-2026-09-10_2.md) / [weaknesses](./opus-specific-weaknesses-2026-09-10_2.md) / [proposals](./opus-specific-proposals-2026-09-10_2.md) |
| 前回（自系統） | [opus/archive/2026-09-10](./archive/2026-09-10/opus-evaluation-2026-09-10.md) |
| 前回まとめ | [archive/2026-09-10/evaluation-2026-09-10.md](../archive/2026-09-10/evaluation-2026-09-10.md) |
| 改善計画 | [improvement-plan.md](../improvement-plan.md) |

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。判断はすべて対象ファイルの再読と実行検証に基づく。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
| 加点合計 | **+185** |
| 減点合計 | **-24** |
| **純点** | **+161** |
| 提案（0点） | 15 件 |

前回（自系統）比: **+115 → +161**（加点 +148 → +185、減点 -33 → -24）。

スコアの読み方を先に書く。加点が伸びたのは、前回「空振り」と書いた日次損失・残高・連続障害・WS ストール・metrics・LiveSafety・Decode strict・baseline/recover などが**実装品質ごと**戻ってきたためである。減点が -33 から -24 に下がった一方で、**純点の上昇は「live 解禁可」を意味しない**。残減点の中核は「測っている量が違う」（FX にスポット残高）と「部分約定の価格が累積 VWAP」であり、骨格の美しさで相殺してはいけない。

---

## 主要結論

1. **improvement-plan の P0–P3「済」主張は、コード再読ですべて確認できた。** DailyLoss/BalanceCache の本番認可接続、両建て net、live Strategy 既定無効 + FixedOnce 拒否、Decode strict、baseline / recover / FailureRate / stall / InFlight、AuthorizedOrder / FillPricing / StatusLive halt。いずれも回帰テストが残っている。

2. **資金保全の骨格は、同種の個人プロジェクトとして明確に上位にある。** DailyLoss の世代+barrier、BalanceCache の hold 会計、AuthorizedOrder のワンショット、Ready 条件にリスクキャッシュ同期を含める判断、baseline / recover の承認プロトコル。前回「止まらない／戻れない」と書いた穴の多くは塞がった。

3. **最大の新規問題は、既定銘柄 `FX_BTC_JPY` にスポット残高モデルを当てていること（`-3`）。** 残高正本は `getbalance` のみ（rest.ex L140-145）。売りは BTC 拘束（risk.ex L117-118）。FX の正本は証拠金であり、検査は動いているが測っている量が違う。P0 #2 を形だけ満たして中身を取り違えている。

4. **部分約定の size は差分化済みだが、price は累積 VWAP のまま（`-2`）。** LiveFills は `delta_order` で数量は正しい（live_fills.ex L224-232）一方、`fill_price` は `info.average_price` をそのまま使う（L186-190）。建玉平均・実現損益・日次損失・突合平均比較がずれる。fail-closed（halt）には倒れるが、部分約定が普通に起きるだけで無人稼働が止まる。

5. **live 発注あたりの open-order 同期が二重（`-2`）。** `System.submit_order` と `OrderExecutor.do_submit` の両方が `maybe_sync_live_fills` を呼ぶ。自分の同期がレート制限→FailureRate halt を誘発しうる。

6. **品質ゲートは緑で、テスト数も厚い。** `mix precommit` で bitflyer 1 doctest + 352 tests / ui 35 tests、0 failures。前回（187+23）から大幅増。

7. **文書と自己改善サイクルは引き続き資産。** README は risk を `partial` +「含み損は未計上」と正直化。評価→plan→1PR→再評価が 3 サイクル回っている。

---

## improvement-plan P0–P3 検証表

| # | 項目 | 判定 | コード根拠 |
|:---:|:---|:---:|:---|
| P0-1 | 日次損失の実効化 | **解決** | `DailyLoss` + `DailyLossSync.around_fill`。`Risk.resolve_daily_loss` は ETS 既定・unsynced fail-closed（risk.ex L530-568）。注入は test のみ |
| P0-2 | 残高検査の実効化 | **解決（モデルは別問題）** | `BalanceCache` + reserve/consume/release。authorize は ETS 既定（risk.ex L576-592）。**ただし FX にはスポットモデルが不適切 → 新規 `-3`** |
| P0-3 | 両建て建玉突合 | **解決** | `net_positions/1`（reconcile.ex L315-377）。hedged 時は avg 厳密比較を外す |
| P0-4 | live 既定の安全化 | **解決** | `LiveSafety`（strategy 既定 false・FixedOnce 拒否・Risk env 必須）。runtime.exs L162 付近 |
| P0-5 | Decode strict | **解決** | 不正数値は `:invalid_number`、0 丸めなし（decode.ex L15-73）。snapshot 失敗→halt |
| P1-6 | baseline import | **解決** | `Startup.Baseline` + `BaselineImport` + hash confirm。Ready にしない |
| P1-7 | submission_unknown 回収 | **解決** | `SubmissionRecovery` + `mix bitflyer.recover` |
| P1-8 | 連続障害・auth サーキット | **解決** | `FailureRate`（401/403 即 halt、窓内 N 回） |
| P1-9 | WS stall watchdog | **解決** | `feed.ex` stall_timeout_ms → `:stale_watchdog` |
| P1-10 | in-flight drain | **解決** | `InFlight` + `prep_stop` drain。timeout 時 submission_unknown + halt |
| P2-11 | 本番 metrics 消費者 | **解決** | ConsoleReporter prod 既定 + `/ops/dashboard` |
| P2-12 | clock skew / permissions | **解決** | authorize + live reconcile。`getpermissions` 出金禁止 |
| P2-13 | OrderRate 再起動復元 | **解決** | `warm_from_db`、失敗時 unsynced |
| P2-14 | CD↔CI 結合 | **解決** | CD が最新 CI workflow success 必須 + Dockerfile.prod ビルド検証 |
| P2-15 | 戦略パラメータ履歴 | **解決** | `StrategyParameterRevision` + Order 由来属性 |
| P3-16 | paper FillPricing | **解決** | slip+fee。認可拘束も同価格 |
| P3-17 | AuthorizedOrder | **解決** | mint/consume・偽造再利用不可 |
| P3-18 | Kill switch / StatusLive | **解決** | StatusLive + `System.halt_trading` / resume / reconcile |
| P3-19 | 残骸棚卸し | **解決** | Heartbeat / PageController / Mailer / swoosh / マーケヘッダ削除 |

---

## 特に検証した項目（依頼どおり）

| 項目 | 結果 |
|:---|:---|
| DailyLoss / BalanceCache → 本番認可 | **接続済み**。未注入時 ETS。unsynced は拒否。本番での注入迂回は無視 |
| reconcile 両建て net | **実装済み**（buy−sell） |
| live Strategy 既定無効 / FixedOnce | **実装済み**（`BITFLYER_STRATEGY_ENABLED=true` のみ。FixedOnce は起動拒否） |
| Decode strict | **実装済み** |
| baseline / recover / FailureRate / stall / InFlight | **いずれも実装済み** |
| AuthorizedOrder / FillPricing / StatusLive halt | **いずれも実装済み** |
| 部分約定の価格計算 | **size は差分 OK / price は累積 VWAP で欠陥** |
| FX_BTC_JPY vs spot 残高 | **不妥当**（getbalance + BTC 売り拘束） |

---

## 前回からの変化（自系統マイナス）

| 区分 | 件数 |
|:---|---:|
| 解決 | 15 |
| 部分解決 | 1（ticker のみ → FillPricing で `-2`→`-1`） |
| 未解決（軽微） | 7（websockex、Status 情報密度、ash.codegen、dev root、Sandbox mode、契約 fixture、生 Ecto balances） |

前回の資金保全系 `-4`/`-2` はすべて解決。新規の重い減点は FX モデル `-3`、部分約定 VWAP `-2`、二重 sync `-2`、BalanceSnapshot 全件読 `-2`。

---

## 実行検証

すべて Docker 経由（`d:\Work\FRICK-ELDY\docker-bitflyer`）で実行した。

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（exit 0、約 8 秒） |
| └ `bitflyer` | **1 doctest, 352 tests, 0 failures** |
| └ `ui` | **35 tests, 0 failures** |
| `docker compose config --quiet` | **成功**（exit 0） |

実行ログから安全装置の発火も確認（抜粋）: `submission_unknown` critical、`persist_failed` critical、`boot reconcile halted`（baseline / clock_skew / invalid_number / unsafe_api_permissions）、`order rate warm failed; marked unsynced`、`prep_stop: in-flight drain timed out`。

**未実行**: 実 bitFlyer API 接続、`Dockerfile.prod` フルビルド、本番 Compose 起動、`mix deps.audit`（今回スコープ外。CI ジョブは存在を確認）。

---

## 現状の一文

**「止め方・壊れ方・戻り方」の骨格は揃い、前回の空振り安全装置は実効化した。残る live ブロッカーは、既定銘柄 FX にスポット残高を当てていることと、部分約定の増分価格が累積 VWAP のままであること。**

通っている経路は「WS → 鮮度/skew → Strategy（live 既定オフ）→ Risk（DailyLoss/BalanceCache 含む）→ AuthorizedOrder → モード別 executor → Fill/Position → 突合/halt → Discord/Status → resume/baseline/recover」。dry_run / paper の縦貫通と回帰は厚い。欠けているのは「FX で正しい量を測ること」と「部分約定の価格を正しい増分にすること」。

---

## 優先改善リスト

live 解禁の前に必要なものを上に置いた。

1. **FX 証拠金モデル** — `getcollateral` 正本 + 必要証拠金拘束。スポット `BTC_JPY` は現行維持。**これが live（FX 既定）解禁の第一条件。**
2. **部分約定の増分価格** — `filled_notional` 差分、または `exchange_execution_id` 単位の Fill 取込（unique 制約と一体）。
3. **live fill 同期の二重呼び出し解消** + 最小間隔 / クライアント側レート制限。
4. **`BalanceCache.load_latest` の全件読を DISTINCT ON / limit に直す**（24/365 の劣化防止）。
5. **含み損ドローダウン**（建玉持ち越し戦略の前に）。paper soak。Status に建玉・日次損益。
6. 軽微負債の一括掃除 — Sandbox `:manual`、`ash.codegen --check`、生 Ecto コメント、dev Dockerfile USER、`apps/bitflyer/README` TODO。

戦略アルゴリズムの高度化・板の本格購読は、引き続きこれらの後でよい。

---

## live 解禁の可否（第1評価者の判断）

**不可（FX 既定のままでは）。**

理由:

- **残高・拘束の正本が FX と不一致**（優先改善 1）。検査網は繋がったが、測っている量が違う。
- **部分約定で建玉・損益・突合がずれる**（優先改善 2）。無人稼働で頻発しうる。

スポット `BTC_JPY` のみ・最小ロット・厳しい上限・Strategy 無効の観察運転なら、骨格としては段階的解禁を議論できる水準に近づいた。ただし現状の既定プロダクトと README の想定は FX であり、**現状設定のまま `TRADE_MODE=live` で実発注してはならない。**

逆に言えば、優先改善 1–3 を片付け、paper soak で 24h 以上 greened すれば、最小ロットでの段階的解禁を再評価できる。骨格そのものはその段階にある。
