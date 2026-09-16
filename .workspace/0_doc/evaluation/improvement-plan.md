# 改善提案書（improvement-plan）

最終更新: 2026-09-16（再評価まとめ後）
根拠: [evaluation-2026-09-16.md](./evaluation-2026-09-16.md) / [specific-weaknesses-2026-09-16.md](./specific-weaknesses-2026-09-16.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

**完了宣言ルール:** 「完了」と書くときは、右列「完了の見方」を満たした根拠を 1 行必須にする。満たせない項目は取り消し線にせず **部分完了** と残す。

---

## 消化済み（コード確認・再評価で維持）

| # | 項目 | 状態 |
|:---:|:---|:---|
| — | tip 前進骨格・ゼロ手数料ハーネス（旧 P0） | 部品として維持 |
| — | Feed 認可・spot 在庫・ACK・有限 open age・ページング | 維持 |
| P1 #4 | 突合窓の対称化（`fill_sync_retries`） | **完了**（コード再読） |
| P1 #6 | Game Day Stage 2 の paper 縦経路 | **コード経路は完了**。副作用は本計画 P1 #6b |
| P2 #7 | BalanceCache.probe + Runner backoff | **完了** |
| P2 #8 | ticker bid/ask → spread ゲート | **完了**（板異常の切り分け残差は P2） |
| P2 #9 | ash.codegen --check / Sandbox manual / README | **完了** |

**「済」＝ live 解禁ではない。**

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | commission 一次証跡（部分完了に戻す） | **部分完了 (2026-09-16)。** 内部は `Product.fee_currency/1` で BTC 建て一貫。証跡は公式類推＋fixture のみ。Stage 3a: 最小ロット**買い**1 回で `getexecutions.commission` と前後 `getbalance`、`LiveBalance.explain` を匿名化して [commission-unit-evidence.md](../architecture/env/commission-unit-evidence.md) に貼る。一致後に Stage 3b:**売り**1 回で base/quote 帰属を確定 | 売買それぞれの実差分が内部 expected と許容幅で一致し、証跡に日付・execution id（匿名可）がある |
| 2 | ハーネス独立性 | 売り fee を `:base_deduct \| :quote_mark` の両モデルで縦回帰。実観測で片方に固定。現行の「JPY 決め打ち反証」は維持 | 自モデルが誤っていても少なくとも片側モデルの失敗を検出できる、または実観測でモデルが固定されている |

---

## P1 — 停止からの出口と安全装置

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 3 | HWM 認可後 crash 窓 | 認可で peak 上昇したら監督下 write-behind へ単調 upsert、または mark 非依存の flush 点。shutdown drain + 再起動回帰 | 認可直後 crash でも DB 高値が残るテストがある |
| 5 | 別ホスト監視の実配備 | 作業 PC で `register-watch-ready-task.ps1` を VLAN1 の `READY_URL` に向けて登録。証跡を [watch-ready-evidence.md](../architecture/env/watch-ready-evidence.md) に「本番向き常駐」として残す | 取引ホスト停止を外から検知した記録がある |
| 6b | Game Day の停止解除副作用 | `mix bitflyer.game_day_stage2` から無条件 `Risk.clear_circuit()` を撤去。開始時に `RiskState.halted` なら理由を出して中断。`mark_ready` 押し通しをやめ、Reconciler 結果で Ready を要求 | paper ドリルが live 停止理由を消さない。Ready が突合経路でしか付かない |

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 7 | 成行拘束の ask 化 | live 成行買いは `best_ask` 基準で probe/reserve。paper は既存方針を明示 | 薄スプレッドでも過小拘束しない回帰がある |
| 8 | ticker 2 層化 | `{ltp, book}` に分け、板欠落でも LTP 鮮度を残す。spread は book 欠落で拒否 | 板異常が `bid_ask_missing` として止まり、時計検査は LTP で通る |
| 9 | DailyEquityPeak の GREATEST upsert | `inspect` 文字列一致をやめ、単調 upsert 1 文へ | 並行 Fill/enforce で過剰 unsynced にならない |
| 10 | improvement-plan 運用 | 本ファイルの完了宣言に根拠行を必須化（本サイクルから適用） | 次回評価で「完了」と証跡が矛盾しない |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + `sum_realized` の DB aggregate | 24/365 で表肥大の判断基準がある |
| 12 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 13 | Hex 外 scanner | release image / lock の Trivy 等。high の例外期限 | GitHub tag と OS がゲートに入る |
| 14 | 隔離 restore 証跡 | backup hash → 空 DB → migration → boot/reconcile を記録 | Recoverable が手順だけでなく成功記録になる |
| 15 | 残る軽微 | 開発 Dockerfile の USER、websockex 記録または移行 | 複数サイクル連続の `-1` が減る |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ canary・二者承認（解禁後に薄い live 戦略 1 本は例外的に先行可）
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

次回評価では、本計画の **P0** がコードおよび証跡上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live 実発注を進めた場合は重大減点とする。
