# docker-bitflyer 総合評価レポート 2026-09-08

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-08 |
| 種別 | **初回評価** |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-08.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-08.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-08.md) / [weaknesses](./specific-weaknesses-2026-09-08.md) / [proposals](./specific-proposals-2026-09-08.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +61 | -60 | **+1** |
| 第2（GPT） | +20 | -57 | **-37** |
| **まとめ（採用）** | **+40** | **-74** | **-34** |

まとめの採点方針:

- **資金保全に直結する未実装**（risk / 冪等 executor / 永続状態 / 起動突合 / 鮮度）は GPT 寄りに重く減点する
- **既にコードにある骨格の質**（Compose・entrypoint・LF 固定・DOM ID・依存方向）は Opus の加点を採用する
- 文書の優秀さは認めるが、未実装を加点で相殺しすぎない（GPT の警戒を採用）

---

## 合意した結論

両評価者が一致した核心は次のとおり。

1. **現状は自動売買システムではなく、Phoenix / Ash / PostgreSQL が Compose で起動する骨格である**
2. **設計文書とアプリ境界（ui → bitflyer、Repo 所有、dry_run 既定、秘密分離）の質は高い**
3. **Safety / Recoverable / Idempotent の中核実装はほぼゼロ**で、live はもちろん paper 運用にも進めない
4. **`docker compose run --rm app mix precommit` は失敗**し、ルート共通ゲートと CI が未整備
5. **healthcheck は readiness ではない**（DB 断でも `/` は 200）
6. **README が完成済みアーカイブと矛盾**している

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 設計と欠如が拮抗し +1 | 価値命題未実装で -37 | **-34**。骨格は良いが Vision 達成度は低い |
| engine 未実装 | 一括 -4 中心 | risk/executor 各 -5 | **分割して重く減点**（GPT） |
| TRADE_MODE 無検証 | -1 | -3 | **-3**（文字列だけが先にある危険） |
| Compose / gitattributes 等 | 厚く加点 | 薄い | **加点を採用**（Opus） |
| 次の一手 | ゲート修正 → Readiness → dry_run 縦貫通 | precommit/CI → 永続+boot → risk → executor | **ほぼ同順。ゲートを engine より先に直す** |

---

## 現状の一文

**土台の方向は正しい。取引システムとしてはまだ何も取引せず、資金を守るコードもまだ無い。**

通っている経路は「起動 → Repo → UI が `SELECT 1`」。Architecture が定めた market-data / strategy / risk / executor / 突合は未着手。永続化の正本は `heartbeats` のみ。

---

## 実行検証（両評価者 + 親で一致）

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm app mix precommit` | **失敗**（`MIX_ENV=dev` → `UiWeb.ConnCase` 未ロード） |
| `MIX_ENV=test` 明示の `mix test` / `mix precommit` | テスト本体は緑（7〜8 件）。ただしルート precommit は bitflyer を十分に覆わない |
| `docker compose config --quiet` | 成功 |
| `.github/workflows/` | **不在** |

---

## 優先順位（合意）

1. ルート `mix precommit`（副作用なし）と GitHub Actions CI
2. README / リンクの現状同期、テスト DB 分離
3. Readiness / `/health`、telemetry 語彙の枠
4. 永続注文状態 + boot halt / reconciliation の骨
5. market-data 鮮度 + fail-closed risk
6. 冪等 executor と dry_run / paper 非送信テスト
7. その後に戦略の中身・Discord・本番 release

戦略の収益性や高機能 UI は、上記の後でよい。

詳細な改善項目は [improvement-plan.md](./improvement-plan.md) を正とする。
