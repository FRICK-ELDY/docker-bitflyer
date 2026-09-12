# 提案（0点）統合一覧 2026-09-12

根拠: [evaluation-2026-09-12.md](./evaluation-2026-09-12.md) /
[opus-specific-proposals](./opus/opus-specific-proposals-2026-09-12.md) /
[gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-12.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

マイナス点の修正と一体のものは improvement-plan の P0/P1 に回し、ここでは前向きな次ステップのみ残す。

---

## 資金保全の次段

- **live 縦貫通の擬似取引所ハーネス** `0`
  > `Exchange.Client` behaviour 上に、約定列と残高変動を台本で与えるスタブを置く。「発注 → 部分約定 → 残高変動 → 周期突合 → Ready 維持 → 再起動」をコードで再現する。今回の tip 不前進は、これがあれば実装前に赤くなっていた。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`

- **板 / bid-ask spread・板厚の流動性ゲート** `0`
  > ticker の `best_bid` / `best_ask` から先に作れる。板 snapshot は後続。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **資金状態機械のモデルベース / プロパティ試験** `0`
  > hold・partial・fee・cancel・unknown・reconcile・再起動の不変条件。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/risk/`, `apps/bitflyer/test/bitflyer/order_executor/`

- **`Exchange.Rest` に Private API のレート予算を持たせる** `0`
  > fill 同期・突合・cancel-all の合算が制限に触れないようにする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

---

## 観測・運用

- **Prometheus + SLO / 資金保全ダッシュボード** `0`
  > ready 率、Feed 再接続、reconcile mismatch、submission_unknown、損失 headroom、通知成功率。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`, `apps/ui/lib/ui_web/telemetry.ex`

- **Status に直近突合結果と skew 余裕を出す** `0`
  > 定期突合の成功は今は画面に現れない。halt 前の予兆にする。
  >
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **resume / live 戦略有効化 / re-baseline の二者承認または理由コード確認** `0`
  > kill は単独即時のまま。反射的な再開だけを防ぐ。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/resume.ex`

- **隔離環境への定期 restore Game Day** `0`
  > ダンプの存在を復旧可能性の実測へ進める。
  >
  > 対象ファイル: `bin/backup-db.sh`, `.workspace/0_doc/architecture/env/prod.md`

---

## 戦略・供給網

- **戦略 revision の canary（件数・時間・自動ロールバック）** `0`
  > immutable revision と Order provenance は揃っている。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`

- **SBOM・コンテナ署名・デプロイ時検証** `0`
  > Hex advisory ゲートの次段。GitHub tag 依存と OS を覆う。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`

- **`Credo` / `Dialyzer` を precommit の別段に** `0`
  > `ci-cd.md` が非保証としている項目。`@spec` は主要モジュールに揃っている。
  >
  > 対象ファイル: `mix.exs`
