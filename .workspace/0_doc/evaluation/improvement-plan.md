# 改善提案書（improvement-plan）

最終更新: 2026-09-13
根拠: [evaluation-2026-09-13.md](./evaluation-2026-09-13.md) / [specific-weaknesses-2026-09-13.md](./specific-weaknesses-2026-09-13.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

---

## 消化済み（2026-09-12 計画 → コード確認）

前回計画の P0 #1–#2（tip 前進骨格・ゼロ手数料ハーネス）、P1 #3–#6 の主要部（HWM 行、fee 列、spot 在庫、Feed 認可）、P2 #7–#9（ACK、有限 open age、ページング）は**部品として**両評価者がコード再読で確認した。P2 #10/#11 は証跡・部分実施まで。再掲しない。

**ただし「済」＝ live 解禁ではない。** 今回の評価で、BTC_JPY `commission` の通貨決め打ちが新たに P0 へ上がった。HWM は行があるが周期 flush が残差。突合窓の片側救済も新規 P1。

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | commission 単位の確定と会計 | 非ゼロ `commission` の private `getexecutions` を秘密なしで証跡化。公式「単位は通貨ペアで異なる」に合わせ、BTC_JPY が BTC なら `Fill.fee` の通貨を product ごとに持ち、base amount・Position・JPY mark 損益へ同じ単位で載せる。Decode 欠落・負は現状どおり fail-closed | 実応答（または公式が単位を明記した fixture）で口座 BTC/JPY の変化と内部 expected が許容幅で一致する |
| 2 | ハーネスと反証回帰 | `LiveExchangeHarness` を実単位に直す。非ゼロ fee の買い・売り・部分約定・周期突合・再起動を通す。誤って quote だけから引く実装は必ず失敗するケースを足す | fixture だけで「JPY 決め打ち」を再現・防止できる |

---

## P1 — 停止からの出口と突合の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 3 | HWM flush | persist 点（Fill 後 / 突合 / resume）で `peak > persisted_peak` なら `DailyEquityPeak` へ書く。認可は ETS のみでよい。回帰: 認可で peak 上昇 → equity 低下 → 再起動しても drawdown が残る | 実現益後の含み損で、周期をまたいだ peak が再起動後も消えない |
| 4 | 突合窓の対称化 | `balance_mismatch` の直前に fill 再同期を 1 回入れるか、`getbalance` を fill 同期の前に取り向きを片側へ固定する | 同期〜残高取得のあいだに入った約定で即 halt しない。説明不能だけ halt |
| 5 | 別ホスト監視の実配備 | 作業 PC で `register-watch-ready-task.ps1` を VLAN1 の `READY_URL` に向けて登録。証跡を [watch-ready-evidence.md](../architecture/env/watch-ready-evidence.md) に「本番向き常駐」として残す | 取引ホスト停止を外から検知した記録がある |
| 6 | Game Day Stage 2 の縦経路 | paper Executor で建玉を作り、Feed 断中の `System.submit_order/2` 拒否と resume 後の再認可を記録。Discord 到達を目視または `last_ok` で閉じる | SQL 直投入と ready 503 だけの代替を卒業する |

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 7 | 残高 probe | `BalanceCache.probe/4` を認可から呼び、判定と reserve を 1 本にする。当面なら Risk moduledoc に近似と書き、`:insufficient_balance` 再試行にバックオフ | 認可通過→予約失敗の Tight loop が消える |
| 8 | ticker bid/ask → spread ゲート | `Normalize.from_ticker/1` に best bid/ask。異常 spread で成行を拒否 | 薄商いの market を認可で止められる |
| 9 | 軽微負債をこのサイクルで 3 件消す | **必ず 3 件**: `ash.codegen --check`、両 `test_helper` の Sandbox mode、`apps/bitflyer/README.md`。残り（Dockerfile USER、websockex 記録、保持方針）は次 | 「必ず」を守った記録がある。守らないなら宣言から「必ず」を消す |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 10 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + `sum_realized` の aggregate | 24/365 で表肥大の判断基準がある |
| 11 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 12 | Hex 外 scanner | release image / lock の Trivy 等。high の例外期限 | GitHub tag と OS がゲートに入る |
| 13 | 残る軽微 | 開発 Dockerfile の USER、websockex 記録または移行 | 5 サイクル連続の `-1` が減る |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ canary・二者承認
- 板の本格購読・プロパティ / モデルベース試験の本格導入
- private execution WS、API レート予算、起動時 `getpositions` 空検査
- SBOM / 署名、裁量向け UI、複数取引所、ML 基盤、FX 証拠金（backlog）

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |
| FX 証拠金 | `.workspace/1_backlog/fx-collateral-adapter.md`（live は spot 限定で先行済み） |
| 本番 CD | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |
| Game Day | [game-day.md](../architecture/env/game-day.md) |

次回評価では、本計画の **P0** がコード上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live 実発注を進めた場合は重大減点とする。
