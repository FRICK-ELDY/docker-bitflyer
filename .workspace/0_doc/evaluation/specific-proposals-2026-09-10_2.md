# 提案（0点）統合一覧 2026-09-10_2

根拠: [evaluation-2026-09-10_2.md](./evaluation-2026-09-10_2.md) /
[opus-specific-proposals](./opus/opus-specific-proposals-2026-09-10_2.md) /
[gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-10_2.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

マイナス点の修正と一体のものは improvement-plan の P0/P1 に回し、ここでは前向きな次ステップのみ残す。

---

## 資金保全の次段

- **含み損・account equity を含む日次ドローダウンゲート** `0`
  > 実現損のみの次。stale 時は fail-closed か「実現のみ+警告」を明示。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **板 / bid-ask spread・板厚の流動性ゲート** `0`
  > まずは ticker の best_bid/ask から。板 snapshot は後続。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **戦略非依存の損切り・利確レイヤ** `0`
  > halt 中の扱いと二重発注防止を先に設計。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/trading/position.ex`

- **リスク状態機械のモデルベース / プロパティ試験** `0`
  > hold・partial・cancel・unknown・reconcile の不変条件。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/risk/`, `apps/bitflyer/test/bitflyer/order_executor/`

---

## 観測・運用

- **StatusLive に建玉・未約定・当日損益・halt 解消手順** `0`
  > 「今トレードしてよいか」に加え「今いくら持っているか」。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **Prometheus + SLO / 資金保全ダッシュボード（別ホスト監視含む）** `0`
  > ConsoleReporter の次段。ready 率、open age、損失、証拠金。
  > 対象ファイル: `apps/ui/lib/ui_web/telemetry.ex`

- **Discord 日次サマリ（生存確認）と大口約定通知** `0`
  > 無音＝順調と Bot 死の区別。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **resume / baseline / recover の二者承認（任意）** `0`
  > kill は単独即時のまま。高危険操作だけ承認者分離。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **隔離 restore / Game Day の定期自動化** `0`
  > RTO/RPO と手動判断点を計測。
  > 対象ファイル: `bin/backup-db.sh`, `.workspace/0_doc/architecture/env/prod.md`

---

## データ・配布・戦略

- **BalanceSnapshot / Fill / Order の保持・ロールアップ方針** `0`
  > 当面剪定しない判断でも文書化。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **戦略 revision の承認・canary 有効化** `0`
  > immutable 履歴の次。段階適用と上限制限。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`

- **SBOM・署名・検証付き release** `0`
  > digest 固定の次の supply-chain。
  > 対象ファイル: `.github/workflows/cd.yml`

- **実 API read-only contract corpus + 最小ロット段階解禁記録** `0`
  > fixture が誤モデルを固定しないための外付け検証。
  > 対象ファイル: `apps/bitflyer/test/fixtures/exchange/`

---

## 意図的に後回し（非目標寄り）

- 戦略アルゴリズムの高度化・パラメータ UI
- 複数取引所、ML 基盤、裁量向け UI
- SaaS 化
