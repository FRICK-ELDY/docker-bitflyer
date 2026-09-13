# docker-bitflyer 総合評価レポート 2026-09-12

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-12 |
| 種別 | **再評価**（前回 2026-09-10_2） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-12.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-12.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-12.md) / [weaknesses](./specific-weaknesses-2026-09-12.md) / [proposals](./specific-proposals-2026-09-12.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-10_2/evaluation-2026-09-10_2.md](./archive/2026-09-10_2/evaluation-2026-09-10_2.md) |
| 対象コミット | `1cfb413`（`Merge pull request #86`） |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。重大指摘（残高 tip 不前進・HWM 揮発）はまとめ側でも対象ファイルを再読した。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +203 | -18 | **+185** |
| 第2（GPT） | +84 | -19 | **+65** |
| **まとめ（採用）** | **+102** | **-24** | **+78** |
| 前回まとめ（参考） | +90 | -44 | **+46** |

まとめの採点方針:

- **実装された資金保全骨格の質**（execution 単位記帳、spot 二重ゲート、Decode 構造 fail-closed、OrderRate 原子予約、AuthorizedOrder、DailyLoss/BalanceCache、LiveSafety）は両評価の合意を加点。同一テーマの重複は抑制
- **live 接続時に顕在化する意味論欠陥**（約定後の残高 tip 不前進、手数料未計上、HWM 非永続）は GPT 寄りに重く減点
- 「P0 が部品として揃った」で Vision の Recoverable / 24/365 を相殺しすぎない

純点は前回 **+46 → +78**。前回の 3 大 live ブロッカー（部分約定 VWAP / FX 残高モデル / Decode 構造 skip）は解決した。ただし **live 解禁可を意味しない**。新しい致命点は「一約定のあと残高正本が進まない」。

---

## 合意した結論

1. **前回まとめの P0（部分約定価格・FX or spot 限定・Decode 構造・OrderRate・fill 同期）はコード再読で解決した。** 両評価者が独立に確認。improvement-plan の「完了」15 件に明確な過大宣言はほぼ無く、残差を本文に書いている（P1 #9 / P2 #12）。例外は P2 #11 の HWM 永続化。
2. **両評価者が独立に同じ新規致命点を見つけた。** live Fill は Order/Fill/Position を更新するが `BalanceSnapshot` は触らない。突合は凍結 baseline との厳密一致。約定後の周期突合または再起動は必ず `balance_mismatch` で halt し、正規の再 baseline 経路が無い。
3. **部品の質は同種個人プロジェクトの上位にある。** execution 単位記帳、AuthorizedOrder、hold 会計、submission_unknown、halt cancel-all、承認付き回収、spot 二重制約。dry_run / paper の縦貫通は厚い。
4. **品質ゲートは緑。** `mix precommit` で bitflyer 1 doctest + 483 / ui 38、0 failures（両評価者）。compose / prod compose / deps.audit も成功。
5. **「部品は揃った」と「系として回る」は別である。** 発注 → 部分約定 → 残高変動 → 定期突合 → Ready 維持、という縦 1 本がコード上に無い。今回の致命点はその欠落から生まれた。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 骨格として +185 | 意味論欠陥で +65 | **+78**。大幅前進だが live 不合格 |
| BalanceSnapshot tip | `-4`（誤検知 halt） | **`-5`**（Recoverable 破壊） | **`-5`**（GPT） |
| live 手数料 | 未計上 | **`-3`** | **採用** |
| HWM 非永続 | **`-2`** | Equity 部分解決に内包 | **採用**（Opus。コード再読で確認） |
| spot 建玉未照合 | **`-2`** | 未計上 | **採用**（Opus） |
| Feed vs 認可 | `-1` | **`-2`** | **`-2`**（実発注ゲート） |
| 未約定期限 infinity | 運用選択 | `-2` | **`-1`**（文書化済みのため緩和） |
| 購読 ACK | 未計上 | `-2` | **採用**（前回から継続） |
| executions ページング | `-1` | 未計上 | **採用** |
| 外部監視 / Game Day | 宣言どおり部分解決 | 各 `-2` | 各 **`-1`**（前進を認める） |
| P3 軽微滞留 | `-1`×複数 | Hex 外 `-1` | **`-3`** に圧縮 |
| 加点の厚さ | +203 | +84 | **重複抑制で +102** |
| 次の一手 | 残高正本の向き反転 + 縦ハーネス | execution・fee・snapshot を一会計へ | **P0 に統合** |

---

## 現状の一文

**止め方・記帳・認可境界の部品はプロダクション候補水準に達した。残る live ブロッカーは「約定で変わった取引所残高を次の永続正本へ安全に進められない」ことである。**

通っている経路は「WS → 鮮度/skew → Strategy（live 既定オフ）→ Risk（DailyLoss/BalanceCache/Equity/spot 限定）→ AuthorizedOrder → モード別 executor → execution 単位 Fill/Position → 突合/halt → Discord/Status → resume/baseline/recover」。欠けているのは live 残高 tip の前進と、それを含む縦 1 本の回帰である。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（bitflyer 1 doctest + 483 / ui 38 / 0 failures）。両評価者 |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（`.env.prod` あり） |
| `docker compose run --rm app mix deps.audit` | **成功**（`No vulnerabilities found.` Hex のみ） |

未実行: 実 bitFlyer private API、最小ロット Game Day Stage 3、`Dockerfile.prod` フルビルド、本番長時間稼働、別ホスト監視の実配備。

---

## 前回からの変化

前回まとめ（2026-09-10_2）の優先課題のうち、コード再読で解決を確認:

- 複数回部分約定の増分価格（execution 単位 + coverage + unique）
- live を spot（`BTC_JPY`）に限定（起動 + 認可の二重）
- Decode の未知 side / 識別子欠落を fail-closed
- OrderRate 原子的予約
- live fill 同期の二重呼び出し解消と post-place halt
- BalanceCache DISTINCT ON、FailureRate warm、Fill 証跡、Status/ready 統一（観測側）、halt cancel-all
- Equity ゲート接続、外部監視手順、Status 情報密度、公開 corpus、deps.audit ゲート

未解決・新たに顕在化:

- **live 約定後の BalanceSnapshot tip 不前進（新規 P0）**
- 当日 HWM の非永続
- live 手数料未計上
- spot 在庫（getbalance base）と内部 Position の未照合
- Risk 認可が Feed 切断を見ない / 購読 ACK なし

---

## 優先順位（合意）

1. **live 残高正本の前進**（説明可能な差分だけ tip append + 承認付き re-baseline）
2. **約定 → 周期突合 → 再起動 → Ready の縦貫通試験**（擬似取引所ハーネス）
3. **HWM 永続化**（読取失敗は unsynced）
4. **live 手数料を Fill / DailyLoss / Equity へ接続**
5. **spot 在庫突合**（`getbalance` base ↔ Position + 未約定売り）
6. Risk に Feed 接続ゲート、購読 ACK、live 有限 open age

戦略アルゴリズムの高度化は、上記の後でよい。

---

## live 解禁の可否（まとめ）

**不可。** 条件が揃うまで `TRADE_MODE=live` での実発注を禁止する（improvement-plan の P0）。

observe-only live、公開/署名 GET contract、paper Stage 2 までは有用である。**一約定のあと必ず halt する状態で Stage 3 に進んではならない。**
