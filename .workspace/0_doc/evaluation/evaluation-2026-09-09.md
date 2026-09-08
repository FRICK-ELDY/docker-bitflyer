# docker-bitflyer 総合評価レポート 2026-09-09

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-09 |
| 種別 | **再評価**（前回 2026-09-08） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-09.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-09.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-09.md) / [weaknesses](./specific-weaknesses-2026-09-09.md) / [proposals](./specific-proposals-2026-09-09.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/evaluation-2026-09-08.md](./archive/evaluation-2026-09-08.md) |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +124 | -37 | **+87** |
| 第2（GPT） | +41 | -49 | **-8** |
| **まとめ（採用）** | **+62** | **-55** | **+7** |
| 前回まとめ（参考） | +40 | -74 | **-34** |

まとめの採点方針:

- **実装された資金保全骨格の質**（三重ゲート、Readiness、サーキット順序、冪等、突合 halt、回帰テスト、CI）は Opus 寄りに加点する（ただし同一テーマの重複加点は抑制）
- **live 接続時に顕在化する欠陥**（結果不明の rejected 確定、残高空でも Ready、risk 迂回オプション、取消・約定欠如、不完全な limits）は GPT 寄りに重く減点する
- 骨格の美しさで Vision 未達（24/365・実弾）を相殺しすぎない

純点は前回 **-34 → +7**。改善は明確だが、「取引システムとして完成」を意味しない。

---

## 合意した結論

1. **前回の「骨格だけ」はもう当てはまらない。** market-data / ETS 鮮度 / Readiness / 永続状態 / 起動突合 / risk / モード別 executor / telemetry / health / CI / 資金保全回帰がコードとテストにある。
2. **それでも live 運用は不可。** 実 API client・取消・約定追跡・結果不明の安全化・完全な risk limits・graceful shutdown・本番 release・外部アラートが欠ける。
3. **現時点の安全性は「実弾を出せないこと」に強く依存する。** `Unavailable` 既定と三重ゲートは正しいが、価値命題の完成ではない。
4. **improvement-plan の P0 / P1 / P2 は消化済み。** 残課題の重心は P3（運用・本番）と、live 解禁前の致命的穴（submission unknown・残高 baseline・risk 完成）。
5. **strategy が無く縦貫通の駆動主体が無い。** 安全装置は揃ったが、本番経路で一度も意図が生まれない。
6. **品質ゲートは修復済み。** `docker compose run --rm app mix precommit` と `-e MIX_ENV=test` の両方が成功（bitflyer 85+doctest / ui 10、0 failures）。`.github/workflows/ci.yml` 存在。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 土台として +87 | paper 可・live 不可で -8 | **+7**。大幅前進だが Vision 達成度は道半ば |
| live 欠如 | 取消欠如 -3 中心 | クライアント全体 -5 + 結果不明 -4 | **分割して重く減点**（GPT） |
| 残高突合 | 書き込み無し -2 | 空なら Ready -4 | **-4**（Ready 経路の穴として GPT） |
| risk 不完全 | -3 | -4 + authorize? bypass -3 | **limits -4 + bypass -3** |
| 加点の厚さ | 細部まで +124 | 厳選 +41 | **重複抑制で +58** |
| 次の一手 | strategy 縦貫通 → limits → shutdown → 通知 | submission 安全化 → risk 完成 → API 契約 | **live 穴を先、その後 dry_run 縦貫通と運用** |

---

## 現状の一文

**安全側に倒れる paper 対応取引基盤の初期実装になった。資金を守るコードは実在する。live で実資金を扱う基準ではまだ不合格。**

通っている経路は「購読 → 鮮度付き cache →（手動/テストの）risk → モード別 executor → 永続化 → 突合/halt」。欠けているのは strategy 駆動と live ライフサイクルと本番配布と人への到達。

---

## 実行検証（両評価者で一致）

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（0 failures） |
| `docker compose run --rm app mix precommit`（MIX_ENV 明示なし） | **成功**（Opus 確認。前回失敗していた文書どおりコマンド） |
| `docker compose config --quiet` | **成功** |
| `.github/workflows/ci.yml` | **存在** |

---

## 前回からの変化（解決済みの要約）

P0–P2 相当は対象ファイル再読で解決を確認:

- ルート precommit / Compose MIX_ENV / CI / README リンク修正 / テスト DB 分離
- TradeMode 検証・live 確認・Readiness・`/health`・telemetry 語彙・`.dockerignore`
- 永続 Resource・boot/定期突合・ETS 鮮度・market-data・risk 骨・モード別 executor・資金保全回帰

未解決の重心: live lifecycle / submission unknown / 残高 baseline / 完全な risk / strategy / shutdown / 本番 release / 認証 / 外部通知 / README 現状同期。

---

## 優先順位（合意）

1. **live submission の不明状態を安全化**（`submission_unknown`・即 halt・照会まで再送しない）— 実 client より先
2. **残高 baseline**（空なら Ready にしない）と **risk limits 完成**（損失・頻度・価格逸脱）+ **`authorize?` 迂回の廃止**
3. **strategy の骨で dry_run 縦貫通**（アルゴリズムは固定ルール 1 本でよい）
4. **グレースフルシャットダウン** と **halt 復帰手段**（`mix bitflyer.resume`）
5. **通知アダプタ**（halt / mismatch / disconnect）
6. **StatusLive の発注可否表示** + UI 認証
7. **本番 release / compose.prod / backup・rollback**（ToDo 03）
8. **実 private API client・取消・約定**（上記の安全枠の後）
9. README 同期・telemetry allowlist・deps audit・Sandbox 明示

戦略の収益性・板の本格購読・裁量 UI は、上記の後でよい。

詳細な改善項目は [improvement-plan.md](./improvement-plan.md) を正とする。
