# docker-bitflyer 総合評価レポート 2026-09-10

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10 |
| 種別 | **再評価**（前回 2026-09-09） |
| 第1評価者 | Claude Opus 5 → [opus-evaluation](./opus/opus-evaluation-2026-09-10.md) |
| 第2評価者 | GPT-5.6 Sol → [gpt-evaluation](./gpt/gpt-evaluation-2026-09-10.md) |
| 基準 | [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md) |
| 統合詳細 | [strengths](./specific-strengths-2026-09-10.md) / [weaknesses](./specific-weaknesses-2026-09-10.md) / [proposals](./specific-proposals-2026-09-10.md) |
| 改善計画 | [improvement-plan.md](./improvement-plan.md) |
| 前回まとめ | [archive/2026-09-09/evaluation-2026-09-09.md](./archive/2026-09-09/evaluation-2026-09-09.md) |

両評価者は相手の当日文書を参照せず、コードを直接検証した。まとめは合意・相違・採用判断を明示する。

---

## 総合スコア

| 評価者 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 第1（Opus） | +148 | -33 | **+115** |
| 第2（GPT） | +49 | -45 | **+4** |
| **まとめ（採用）** | **+73** | **-37** | **+36** |
| 前回まとめ（参考） | +62 | -55 | **+7** |

まとめの採点方針:

- **実装された資金保全骨格の質**（submission_unknown、persist_failed halt、baseline、authorize 強制、Rest、縦貫通、release/CD）は Opus 寄りに加点（同一テーマの重複は抑制）
- **live 接続時に顕在化する欠陥**（損失・残高の不発、両建て突合の上書き、FixedOnce の live 既定、Decode の 0 丸め）は GPT 寄りに重く減点
- 骨格の美しさで Vision 未達（実弾の資金保全）を相殺しすぎない

純点は前回 **+7 → +36**。P0 #1–#4 と P1–P3 の大半が解け、回帰も厚い。ただし **live 解禁可を意味しない**。

---

## 合意した結論

1. **P0 #1〜#4 は解決した。** submission_unknown、persist_failed halt、残高 baseline、risk 迂回廃止はコードと回帰で確認できる。
2. **P0 #5 は未解決。** `max_daily_loss` / 残高の比較関数はあるが、本番経路で注入されず損失は常に 0・残高はスキップ。README の implemented は過大。
3. **live 建玉突合に両建て上書きの穴がある。** REST は `{product_code, side}` 集約、突合は `product_code` キーのみ（`reconcile.ex` L191-194）。誤 Ready になりうる。
4. **FixedOnce が全環境で既定有効。** live Ready 直後に固定成行買い意図が出うる。開発用の骨としては正しいが、live client 同居後は危険既定。
5. **運用候補までの前進は大きい。** strategy 縦貫通、Rest、paper、shutdown/resume、Discord、Status、認証、release/CD、deps audit が揃った。
6. **品質ゲートは緑。** `mix precommit` で bitflyer 187+doctest / ui 23、0 failures。

---

## 主な相違と採用判断

| 論点 | Opus | GPT | まとめ |
|:---|:---|:---|:---|
| 純点の意味 | 土台として +115 | live 欠陥で +4 | **+36**。大幅前進だが live 不合格 |
| P0 #5 | 実装は解決 / 実効性未達（分割減点） | **未解決 `-5`** | **未解決 `-5`**（GPT） |
| 両建て突合 | 未計上 | `-4` | **採用**（コード再読で確認） |
| FixedOnce live 既定 | 縦貫通として加点 | `-4` | **減点採用**（live 同居後） |
| 加点の厚さ | +148 | +49 | **重複抑制で +73** |
| 次の一手 | 日次損失正本 → 残高 → 連続障害 → unknown 回収 | P0 #5 接続 → 両建て → FixedOnce 無効化 | **両方を P0 に統合** |

---

## 現状の一文

**本番形と実 API まで到達した高品質な安全基盤だが、日次損失が実運用で常に 0 扱い・両建て突合の見落とし・戦略の危険既定が残り、live 解禁は不可。**

通っている経路は「購読 → 鮮度 → Strategy → Risk（一部空振り）→ モード別 executor → 永続化 → 突合/halt → Discord/Status → resume」。dry_run / paper の縦貫通は実在する。欠けているのは「損失で本当に止まること」と「実弾形状での突合正しさ」と「live 既定の安全側」。

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（bitflyer 1 doctest + 187 tests / ui 23 tests / 0 failures） |
| `docker compose config --quiet` | **成功**（両評価者） |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（両評価者） |
| `docker compose run --rm app mix deps.audit` | **成功**（GPT: No vulnerabilities found。Hex のみ） |

未実行: 実 bitFlyer API 接続、`Dockerfile.prod` のフルビルド、本番 Compose 起動。

---

## 前回からの変化（解決済みの要約）

前回まとめの優先課題のうち、コード再読で解決を確認:

- submission_unknown + halt / persist_failed halt / 残高 baseline / authorize 迂回廃止
- strategy 縦貫通 / graceful 受付停止 / resume / paper 残高・指値
- Discord / StatusLive 発注可否 / health 分離 / telemetry allowlist / README 表
- UI 認証・bind / API キー枠 / 本番 release・CD / Exchange.Rest / deps audit

未解決・新たに顕在化:

- **risk limits の実データ接続（P0 #5）**
- **両建て建玉の突合上書き**
- **FixedOnce の live 既定有効**
- Decode の 0 丸め / unknown 回収 / baseline import / WS サイレントストール / 連続障害サーキット / 本番 metrics 消費者

---

## 優先順位（合意）

1. **日次損失・残高を本番認可へ必須接続**（未計測は `:unsynced`。README を partial に）
2. **建玉突合の両建て正規化** + 順序反転 fixture
3. **live / prod で Strategy 既定無効** + live 専用上限の明示必須化
4. **Decode strict 化**（不正数値で snapshot 失敗）
5. **baseline import / submission_unknown 回収** の承認付き command
6. **連続障害・auth 失敗サーキット** + WS ストール watchdog
7. **本番 metrics 消費者** + CD↔CI 結合強化

戦略アルゴリズムの高度化は、上記の後でよい。

---

## live 解禁の可否（まとめ）

**不可。** 条件が揃うまで `TRADE_MODE=live` での実発注を禁止する（improvement-plan の P0）。
