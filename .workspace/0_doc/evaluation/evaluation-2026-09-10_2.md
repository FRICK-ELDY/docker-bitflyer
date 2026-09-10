# docker-bitflyer 総合評価レポート 2026-09-10_2

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10_2（同日2回目） |
| 種別 | **再評価**（前回 2026-09-10） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-10_2.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-10_2.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-10_2.md) / [weaknesses](./specific-weaknesses-2026-09-10_2.md) / [proposals](./specific-proposals-2026-09-10_2.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-10/evaluation-2026-09-10.md](./archive/2026-09-10/evaluation-2026-09-10.md) |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +185 | -24 | **+161** |
| 第2（GPT） | +66 | -33 | **+33** |
| **まとめ（採用）** | **+90** | **-44** | **+46** |
| 前回まとめ（参考） | +73 | -37 | **+36** |

まとめの採点方針:

- **実装された資金保全骨格の質**（DailyLoss barrier、BalanceCache hold、AuthorizedOrder、LiveSafety、両建て net、baseline/recover、InFlight、CD↔CI）は Opus 寄りに加点（同一テーマの重複は抑制）
- **live 接続時に顕在化する意味論欠陥**（部分約定の増分価格、FX にスポット残高、Decode の構造 skip）は GPT 寄りに重く減点
- 「部品は揃った」で Vision の実弾資金保全を相殺しすぎない

純点は前回 **+36 → +46**。前回 P0 の空振り安全装置は接続された。ただし **live 解禁可を意味しない**。

---

## 合意した結論

1. **前回まとめの P0 #1〜#5（空振り接続・両建て・LiveSafety・Decode 数値）は部品として解決した。** DailyLoss/BalanceCache は本番認可へ接続、両建ては net、live は Strategy 既定無効、NaN/Inf は `:invalid_number`。両評価者がコード再読で確認。
2. **P0 #1/#2 の「済」は過大宣言になりうる。** 一括約定・スポット会計では実効だが、(a) 複数回部分約定で累積 `average_price` を差分 Fill に掛ける、(b) 既定 `FX_BTC_JPY` に `getbalance` + BTC/JPY 拘束を当てる、の2点が残る。
3. **Decode の数値 strict と構造 skip は別問題。** 未知 side / 識別子欠落行の skip は実エクスポージャを snapshot から消せる（GPT 採用）。
4. **運用候補までの骨格は揃った。** submission_unknown 回収、baseline、AuthorizedOrder、stall watchdog、FailureRate、kill/resume、paper FillPricing、Status、認証、release/CD、deps audit、387 tests が緑。
5. **品質ゲートは緑。** `mix precommit` で bitflyer 1 doctest + 352 / ui 35、0 failures（両評価者）。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 骨格として +161 | 意味論欠陥で +33 | **+46**。大幅前進だが live 不合格 |
| P0「すべて済」 | 部品は解決（FX は別問題） | #1/#2/#5 は部分解決 | **部分解決**（GPT 寄り） |
| 部分約定 VWAP | `-2`（halt 側） | **`-5`**（DailyLoss 破壊） | **`-5`**（GPT） |
| FX スポット残高 | `-3` | **`-5`** | **`-5`**（GPT） |
| Decode 構造 skip | P0-5 解決扱い | **`-4`** | **採用**（コード再読で確認） |
| OrderRate 競合 | 未計上（軽微扱いなし） | `-3` | **採用** |
| live 二重 sync | `-2` | 関連して post-place 握り | **両方採用** |
| BalanceCache 全件読 | `-2` | 未計上 | **採用**（Opus） |
| 加点の厚さ | +185 | +66 | **重複抑制で +90** |
| 次の一手 | FX → 増分価格 → 二重 sync | 増分価格 → FX → Decode | **P0 に両方を統合** |

---

## 現状の一文

**止め方・戻り方・認可境界の骨格はプロダクション候補水準に達した。残る live ブロッカーは「測っている量（FX vs スポット）」と「部分約定の増分価格」と「private snapshot の黙殺 skip」である。**

通っている経路は「WS → 鮮度/skew → Strategy（live 既定オフ）→ Risk（DailyLoss/BalanceCache）→ AuthorizedOrder → モード別 executor → Fill/Position → 突合/halt → Discord/Status → resume/baseline/recover」。dry_run / paper の縦貫通は厚い。欠けているのは実弾意味論の正しさ。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（bitflyer 1 doctest + 352 / ui 35 / 0 failures） |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（GPT） |
| `docker compose run --rm app mix deps.audit` | **成功**（GPT: No vulnerabilities found。Hex のみ） |

未実行: 実 bitFlyer API 接続、最小ロット Game Day、`Dockerfile.prod` フルビルド、本番長時間稼働。

---

## 前回からの変化（解決済みの要約）

前回まとめ（2026-09-10）の優先課題のうち、コード再読で解決を確認:

- 日次損失・残高の本番認可接続（一括経路）
- 両建て建玉の net 正規化
- live Strategy 既定無効 + FixedOnce 拒否 + Risk env 必須
- Decode 数値の 0 丸め廃止
- baseline import / submission_unknown 回収 / FailureRate・auth / WS stall / InFlight
- metrics 消費者 / source_timestamp・permissions / OrderRate warm / CD↔CI / revision
- paper FillPricing / AuthorizedOrder / Kill switch / 残骸棚卸し

未解決・新たに顕在化:

- **複数回部分約定の増分価格（累積 VWAP 誤用）**
- **既定 FX にスポット残高モデル**
- **Decode の構造 skip（未知 side 等）**
- OrderRate check-then-act / live fill 二重 sync / BalanceCache 全件読 / 外部監視

---

## 優先順位（合意）

1. **部分約定の増分価格**（`filled_notional` 差分、または execution ID 単位取込 + unique）
2. **FX 証拠金モデル**（`getcollateral`）または **live 対象を spot に限定**
3. **private snapshot の未知 side / 識別子欠落を fail-closed**
4. **OrderRate の原子的予約** + live fill 同期の二重呼び出し解消
5. **BalanceCache.load_latest の DISTINCT/limit** + FailureRate 再起動復元
6. Status/ready の Feed 判定統一、含み損ゲート、外部監視・Game Day

戦略アルゴリズムの高度化は、上記の後でよい。

---

## live 解禁の可否（まとめ）

**不可。** 条件が揃うまで `TRADE_MODE=live` での実発注を禁止する（improvement-plan の P0）。

スポット限定・最小ロット・Strategy 無効の観察運転は議論できる水準に近づいたが、**現状の既定（`FX_BTC_JPY`）のまま実発注してはならない。**
