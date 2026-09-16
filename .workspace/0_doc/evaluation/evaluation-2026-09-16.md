# docker-bitflyer 総合評価レポート 2026-09-16

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-16 |
| 種別 | **再評価**（前回 2026-09-13） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-16.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-16.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-16.md) / [weaknesses](./specific-weaknesses-2026-09-16.md) / [proposals](./specific-proposals-2026-09-16.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-13/evaluation-2026-09-13.md](./archive/2026-09-13/evaluation-2026-09-13.md) |
| 対象コミット | `a387746`（`Merge pull request #112`） |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。重大指摘（commission 証跡・監視配備・Game Day `clear_circuit`・HWM 残窓）はまとめ側でも対象ファイルを再読した。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +31 | -16 | **+15** |
| 第2（GPT） | +110 | -11 | **+99** |
| **まとめ（採用）** | **+118** | **-15** | **+103** |
| 前回まとめ（参考） | +114 | -16 | **+98** |

まとめの採点方針:

- **本サイクルで閉じた資金保全部品**（手数料モデル書き換え、HWM flush、突合対称化、probe、spread、Stage2、軽微3件）は両評価の合意を加点。基盤テーマの重複は抑制
- **完了宣言と完了条件の乖離**（commission 一次証跡・監視未配備）は GPT 寄りに重く、またはコード／証跡再読で採用
- Opus の純点が低いのは「差分評価＋precommit 省略」に近く、GPT は網羅加点。まとめは後者の粒度に寄せつつ、Opus が単独で見つけた Game Day 副作用を採用

純点は前回 **+98 → +103**。骨格は前進したが **live 解禁可を意味しない**。

---

## 合意した結論

1. **前回の live ブロッカーのうち、コード側の大半は閉じた。** HWM flush・突合窓対称化・BalanceCache.probe・spread・Game Day Stage2（paper 縦）・軽微3件は両評価が独立に確認。
2. **P0 commission の「内部会計」は直ったが、「取引所事実との独立照合」は未完。** 証跡自身が実非ゼロ未配置・単位フィールドなしを認める。売り側モデルは推定。
3. **残る live 解禁条件は実質 2 件:** (a) 売買別の一次証跡（最小ロット実測）(b) VLAN1 別ホスト監視の常駐配備。
4. **品質ゲートは緑（GPT 実行）。** `mix precommit` で bitflyer 1 doctest + 630 / ui 38、計 668、0 failures。compose / prod compose / deps.audit 成功。Opus は precommit 省略を明記。
5. **部品の質は同種個人プロジェクトの上位。** ただし「ハーネスが緑」≠「取引所の事実に対して系が回る」。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | +15（差分・厳しめ） | +99（網羅） | **+103**。前進だが live 不合格 |
| commission | `-2`（推定完了宣言） | **`-3`**（一次証跡欠如） | **`-3`**。P0 は部分完了へ戻す |
| live 解禁 | 不可（残2条件） | 不可（同旨） | **不可** |
| P0 #1/#2 | 完了宣言は不当 | 部分解決 | **部分解決** |
| HWM | `-1`（mark stale 点火） | **`-2`**（認可後 crash 窓） | **`-2`**（残窓を一本化） |
| Game Day clear_circuit | **`-2`** | 未計上 | **採用 `-2`**（コード再確認） |
| 完了宣言プロセス | **`-2`** | 表で部分解決と記述 | **`-1`**（圧縮） |
| ハーネス共有モデル | `-1` | 提案寄り | **`-1`** |
| 外部監視 | `-2` | `-2` | **`-2`** |
| FixedOnce のみ | `-1` | — | **提案へ**（Vision 準拠） |
| retention | 提案 | `-1` | **提案**（当日境界は確認済み） |
| 加点の厚さ | +31 | +110 | **重複抑制で +118** |
| 次の一手 | 監視 + 買い→売り実測 | 一次証跡 + 監視 + HWM queue | **一次証跡と監視を P0/P1 に戻す** |

---

## 現状の一文

**止め方・記帳・認可境界・fee 通貨の内部一貫性・突合の両向き救済はプロダクション候補水準に達した。残る live ブロッカーは「非ゼロ手数料の実残高一次証跡」と「別ホスト本番監視の未配備」である。**

通っている経路は「WS ACK → Feed ゲート → Strategy（live 既定オフ）→ Risk（DailyLoss/BalanceCache/Equity/spot 在庫/spread/有限 open age）→ AuthorizedOrder → モード別 executor → execution 単位 Fill（fee_currency）→ explain 成功時の tip append → halt/resume」。欠けているのは実口座での売買別差分検証と、取引ホスト外からの Ready 常駐監視である。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（GPT）。668 tests + 1 doctest / 0 failures。Opus は省略 |
| `docker compose config --quiet` | **成功**（GPT） |
| `docker compose -f compose.prod.yaml ... config --quiet` | **成功**（GPT） |
| `docker compose run --rm app mix deps.audit` | **成功**（`No vulnerabilities found.` Hex のみ） |

未実行: 実 bitFlyer private の fee-bearing 往復、VLAN1 監視常駐、隔離 restore、`Dockerfile.prod` フルビルド、本番長時間稼働。

---

## 前回からの変化

コード再読で**解決**を確認:

- commission の JPY 決め打ち → BTC（base）モデルへの内部統一と反証（JPY 決め打ち）回帰
- HWM の `persisted_peak` flush（残窓あり）
- 突合窓の fill 再同期
- BalanceCache.probe + Runner backoff
- ticker bid/ask → spread ゲート
- Game Day Stage 2 の paper Executor 貫通
- `ash.codegen --check` / Sandbox manual / Bitflyer README

未解決・新たに顕在化:

- **commission 一次証跡（売買別）— P0 に戻す**
- **別ホスト監視未配備 — 唯一の配備ブロッカー**
- HWM 認可後 crash 窓
- Game Day のグローバル clear_circuit
- 完了宣言と完了条件の乖離
- ハーネスと本番の式共有
- P3 軽微滞留（Dockerfile / websockex / scanner / restore）

---

## 優先順位（合意）

1. **非ゼロ fee の買い→売り一次証跡**（Stage 3a/3b）。秘密を除いた execution と前後 getbalance を証跡へ
2. **VLAN1 別ホスト監視の常駐登録**と証跡更新
3. **Game Day から無条件 `clear_circuit` / 安易な `mark_ready` を除去**（halt 中は中断）
4. **HWM write-behind または mark 非依存 flush**で認可後 crash 窓を閉じる
5. **improvement-plan の完了宣言に根拠 1 行必須**（満たせないものは部分完了）
6. P2: 成行 ask 拘束・ticker 2 層・GREATEST upsert・ハーネス両モデル
7. P3: retention / scanner / restore 証跡 / Dockerfile USER / websockex

---

## live 解禁可否

**不可。**

Stage 3（最小ロット実発注）へ進む最低条件:

1. 匿名化した非ゼロ fee の実応答と前後残高で、現行 fixture の買い・売り式を独立検証する
2. VLAN1 本番の `/health/ready` を別ホストから常駐監視し、停止通知を実証する

HWM 残窓と Game Day 副作用は同時に閉じるのが望ましいが、上記 2 件が閉じるまで live 実発注は禁止する。
