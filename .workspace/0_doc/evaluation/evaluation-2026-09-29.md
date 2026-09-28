# docker-bitflyer 総合評価レポート 2026-09-29

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-29 |
| 種別 | **再評価**（前回 2026-09-16） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-29.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-29.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-29.md) / [weaknesses](./specific-weaknesses-2026-09-29.md) / [proposals](./specific-proposals-2026-09-29.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-16/evaluation-2026-09-16.md](./archive/2026-09-16/evaluation-2026-09-16.md) |
| 対象コミット | `afc46bb`（`Merge pull request #123`） |

両評価者は相手の当日文書を参照せず、コードを直接検証した。重大な相違はまとめ側でも対象ファイルを再読した。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +52 | -9 | **+43** |
| 第2（GPT） | +62 | -5 | **+57** |
| **まとめ（採用）** | **+69** | **-7** | **+62** |
| 前回まとめ（2026-09-16） | +118 | -15 | **+103** |

採点方針:

- 同一の設計は 1 回だけ加点する。前回の細目積み上げ（+118）とは粒が違う。純点が +103 から +62 へ動いても、後退ではない
- 前進の証拠は点数差ではなく、前回未解決が閉じたかである
- HWM の強制終了窓は残すが、通常停止と SIGTERM の経路が閉じたので重みを `-2` から `-1` へ下げる
- 開発 root、websockex の説明、FixedOnce のみは資金保全の欠如ではないので提案（0）

---

## 合意した結論

1. **前回の live ブロッカーのうち、コードと一次証跡は閉じた。** commission の売買別実測、ハーネスの独立、Game Day が永続停止を消さないこと、突合の両向き、ask 拘束、ticker の 2 層、GREATEST upsert は、両方の再読が完了主張を採用した。まとめの再読でも見方と矛盾する「完了」は無かった。
2. **監視の完了条件は、評価のあと作業PCの常駐に書き換えて閉じた。** `BitflyerWatchReady` が Running で、到達不能の2行が `%LOCALAPPDATA%\bitflyer\watch-ready.log` にある。専用監視PCは条件にしない。P1 #5 は [improvement-plan.md](./improvement-plan.md) で完了。
3. **品質ゲートは緑。** `docker compose run --rm -e MIX_ENV=test app mix precommit` が成功。bitflyer は doctest 1 とテスト 667、ui は 38、失敗 0。両評価者は `_build` 競合を避けるため未実行。
4. **HWM は部分完了のまま。** write-behind、drain、fsync 印、GREATEST は入った。ノード強制終了で DailyLoss と PeakWriter が同時に消えると、未着の高値は残らない。実装がそう書いている。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点 | +43 | +57 | **+62**。重複を除いた全体積み上げ |
| live 解禁 | 不可（監視が単一条件） | 不可（監視・HWM・板厚） | **評価時点は不可。** その後、監視の見方を作業PC常駐に書き換え P1 #5 を完了。専用監視PCは条件にしない |
| HWM 強制終了窓 | `-1` | `-2` | **`-1`**。`peak_writer.ex` L13-14 を再読。通常停止は覆った。完了条件は未達 |
| 銘柄と一次証跡のずれ | `-1`（新規） | 未計上 | **採用 `-1`**。`product.ex` L108-110 と `risk.ex` L270-271 を再読。BTC_JPY 以外を live にする前に塞ぐ |
| 成行の板厚超過 | 完了の残差として明記、減点せず | `-1` | **採用 `-1`**。`risk.ex` L821-824 を再読。best ask 拘束の完了は維持 |
| halted_at の上書き | `-1` | 未計上 | **採用 `-1`**。`reconciler.ex` L390-414 を再読 |
| PeakWriter の 50ms 再試行 | `-1` | 未計上 | **採用 `-1`**。`@retry_ms` と error ログを再読 |
| FixedOnce のみ | `-1` | 提案 | **提案**。live では起動拒否済み |
| 開発 Dockerfile root | `-1` | 提案 | **提案**。本番は非 root |
| websockex 未記録 | `-1` | 提案 | **提案** |
| 完了宣言 11 件 | 全採用 | 全採用 | **全採用**。却下 0 |
| P2 #10 | 部分完了を維持 | 部分完了を維持 | **完了へ上げる。** 見方は「次回評価で矛盾しない」。本評価がそれであり、却下 0 を根拠にした |

---

## 現状の一文

**会計・突合・認可・停止の記録は実測とテストで説明できる。ready の常駐は作業PCの `BitflyerWatchReady` で閉じた。**

通っている経路は、WS ACK から Feed、Risk、認可トークン、モード別の executor、execution 単位の Fill、説明できたときだけ tip を進め、不一致なら halt する、までである。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（まとめ側）。bitflyer 1 doctest + 667、ui 38、失敗 0。exit 0。約 14 秒 |
| 両評価者の `mix precommit` | 未実行（上記と `_build` を競合させないため） |

未実行: 実口座の再往復、VLAN1 監視の常駐、隔離 restore、本番イメージの手元フルビルド、長時間稼働。

---

## 前回からの変化

コードと証跡の再読で**解決**:

- commission の売買別一次証跡（2026-09-28）
- ハーネスが誤った売り手数料で halt すること
- Game Day の停止解除
- HWM の mark 依存 flush（残窓は強制終了のみ）
- DailyEquityPeak の `inspect` 再試行
- 板異常で ticker 全体を捨てること
- 成行拘束の LTP 基準
- 完了宣言に根拠行が無い運用

未解決、または今回見えたもの:

- 別ホスト監視の本番常駐は、作業PCの `BitflyerWatchReady` をもって完了（専用監視PCは採らない）
- HWM の強制終了窓（重みは下がった）
- BTC_JPY 以外の spot を live 認可できること
- 成行買いの板厚超過
- `halted_at` の上書き
- PeakWriter の固定間隔再試行

---

## live 解禁可否

**監視条件は完了。** 専用監視PCは採らない。作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残っている。解除は `bin/unregister-watch-ready-task.ps1`。

BTC_JPY 以外を live の対象にする前に、その銘柄の売買実測を証跡へ足すか、認可を BTC_JPY に固定する。既定が BTC_JPY のままなら、これは次のゲートではない。

---

## 優先して直す順

1. live の銘柄検査を、一次証跡のある集合に合わせる
2. 同じ理由の再突合では `halted_at` を書き換えない
3. PeakWriter の再試行を間隔を広げ、同じ失敗ログを間引く
4. 成行買いの板厚超過を、深さか保守的な余白で拘束する
