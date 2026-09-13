# docker-bitflyer 総合評価レポート 2026-09-13

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-13 |
| 種別 | **再評価**（前回 2026-09-12） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-13.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-13.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-13.md) / [weaknesses](./specific-weaknesses-2026-09-13.md) / [proposals](./specific-proposals-2026-09-13.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-12/evaluation-2026-09-12.md](./archive/2026-09-12/evaluation-2026-09-12.md) |
| 対象コミット | `cfaf0a5`（`Merge pull request #103`） |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。重大指摘（手数料通貨・HWM flush・突合窓）はまとめ側でも対象ファイルと公式手数料ページを再読した。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +231 | -15 | **+216** |
| 第2（GPT） | +104 | -13 | **+91** |
| **まとめ（採用）** | **+114** | **-16** | **+98** |
| 前回まとめ（参考） | +102 | -24 | **+78** |

まとめの採点方針:

- **本サイクルで閉じた資金保全部品**（tip 前進骨格、ハーネス、ACK、Feed 認可、spot 在庫、有限 open age、ページング）は両評価の合意を加点。同一テーマの重複は抑制
- **live 接続時に顕在化する意味論**（commission 通貨、HWM 周期 flush、突合窓の非対称）は GPT 寄りに重く、またはコード再読で採用
- 「P0 ファイルが揃った」で Vision の Recoverable / 24/365 を相殺しすぎない

純点は前回 **+78 → +98**。前回の致命点（約定後に tip が進まない）の**骨格**は入った。ただし **live 解禁可を意味しない**。新しい致命点は「BTC_JPY の手数料単位を JPY と決め打ちし、公式の『単位は通貨ペアで異なる』と矛盾する」ことである。

---

## 合意した結論

1. **前回まとめの P0（残高 tip 前進・縦ハーネス）と P1 の大半（在庫・Feed 認可・手数料列）はファイルとして存在する。** 両評価者が独立に確認。ゼロ手数料なら「発注 → 部分約定 → 突合 → tip 前進 → 再起動 → Ready」が回帰で通る。
2. **両評価者が独立に HWM の残差を見つけた。** 認可は `persist: false`。周期のあいだに上がった peak は DB に載らず、再起動で drawdown が緩む。
3. **部品の質は引き続き同種個人プロジェクトの上位にある。** ACK、pid 付き Feed snapshot、SpotInventory の認可/突合共用、有限 open age、execution ページング。dry_run / paper とゼロ手数料 live 骨格は厚い。
4. **品質ゲートは緑。** `mix precommit` で bitflyer 1 doctest + 599 / ui 38、計 637、0 failures（両評価者）。compose / prod compose / deps.audit も成功。
5. **「ハーネスが緑」と「取引所の事実に対して系が回る」は別である。** ハーネスは commission を quote（JPY）から引く。公式手数料表は単位が通貨ペアで異なり、Bitcoin は Unit: BTC と書く。fee-bearing 実約定の縦 1 本は未証明。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 骨格として +216、Stage 3 可 | 意味論欠陥で +91、live 不可 | **+98**。前進だが live 不合格 |
| commission 通貨 | 未計上（P1 #4 を解決と判定） | **`-4`**（BTC 単位） | **`-4`**（GPT）。公式ページとコードを再読 |
| live 解禁 | Stage 3（単発・有人）可 | **不可** | **不可**。一約定後 halt しうる状態で Stage 3 に進まない |
| P0 #1/#2 | 解決 | 部分解決 | **部分解決**（ゼロ手数料のみ） |
| P1 #4 手数料 | 解決 | **未解決** | **未解決** |
| HWM | **`-2`**（周期間 flush） | **`-2`**（認可後 crash） | **採用**（同じ穴） |
| 突合窓の非対称 | **`-2`** | 未計上 | **採用**（`reconcile.ex` 再読） |
| P1 #3 HWM 宣言 | 部分解決（過大） | 解決 | **部分解決**（Opus） |
| 外部監視 | `-1` | `-2` | **`-1`**（証跡前進を認める） |
| Game Day Stage 2 | 解決 | `-2` | **`-1`**（SQL/ready 代替を残差とする） |
| P3 軽微滞留 | `-1`×複数 + プロセス `-1` | drift/README `-1` | **`-3`** に圧縮 |
| 加点の厚さ | +231 | +104 | **重複抑制で +114** |
| 次の一手 | HWM flush + 突合対称化 | commission を実単位へ | **P0 に手数料単位を置く** |

---

## 現状の一文

**止め方・記帳・認可境界・ゼロ手数料の tip 前進はプロダクション候補水準に達した。残る live ブロッカーは「実約定の手数料通貨を、取引所の事実と同じ会計へ載せられていない」ことである。**

通っている経路は「WS ACK → Feed ゲート → Strategy（live 既定オフ）→ Risk（DailyLoss/BalanceCache/Equity/spot 在庫/有限 open age）→ AuthorizedOrder → モード別 executor → execution 単位 Fill → explain 成功時の tip append → halt/resume」。欠けているのは BTC_JPY `commission` の単位確定と、それを含む fee-bearing 縦回帰である。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（bitflyer 1 doctest + 599 / ui 38 / 0 failures）。両評価者 |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（`.env.prod` あり） |
| `docker compose run --rm app mix deps.audit` | **成功**（`No vulnerabilities found.` Hex のみ） |

未実行: 実 bitFlyer private API の fee-bearing `getexecutions`、最小ロット Game Day Stage 3、`Dockerfile.prod` フルビルド、本番長時間稼働、VLAN1 向け監視常駐。

---

## 前回からの変化

前回まとめ（2026-09-12）の優先課題のうち、コード再読で**骨格として**解決を確認:

- live 約定後の BalanceSnapshot tip 前進（ゼロ手数料）
- 発注 → 部分約定 → 周期突合 → 再起動 → Ready の縦回帰（ハーネス）
- 当日 HWM の DB 行（init/reload。flush 残差あり）
- Fill.fee 列と `gross − fee`（単位は未確定）
- spot 在庫突合と売りカバー
- Risk 認可の Feed 接続ゲート
- 購読 ACK
- live 有限 open age
- `getexecutions` ページング
- watch-ready の開発ドリル証跡
- paper Game Day Stage 2（部分）

未解決・新たに顕在化:

- **BTC_JPY commission の通貨単位（新規 P0）**
- 認可 HWM の周期間非永続
- 突合窓の片側救済
- 別ホスト監視の未配備
- Game Day の Executor 未貫通
- P3 軽微負債（5 サイクル連続）

---

## 優先順位（合意）

1. **commission 単位の確定と会計への一貫反映**（private GET の非ゼロ execution。BTC なら base / Position / mark 損益）
2. **ハーネスと縦回帰を実単位に直し、誤った通貨なら必ず失敗させる**
3. **HWM の flush**（認可で上がった peak を persist 点で書く）
4. **突合窓の対称化**
5. VLAN1 向け watch-ready 常駐、Game Day の Executor 経路、P3 を実際に 3 件消す

戦略アルゴリズムの高度化は、上記の後でよい。

---

## live 解禁の可否（まとめ）

**不可。** 条件が揃うまで `TRADE_MODE=live` での実発注を禁止する（improvement-plan の P0）。

observe-only live、公開/署名 GET（とくに非ゼロ commission の execution）、paper の完遂は有用である。**手数料単位が未証明のまま Stage 3 に進んではならない。** 一約定のあと halt しうる状態は、前回禁止した「tip 不前進」と同じ形である。
