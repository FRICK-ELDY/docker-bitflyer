# 提案（0点）統合一覧 2026-09-08

初回評価。減点ではない「次の一手」。
詳細の正本: [opus-specific-proposals](./opus/opus-specific-proposals-2026-09-08.md) / [gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

マイナス点に既に挙げた必須欠如（risk / executor / CI 本体など）はここへ重複させない。実装すれば前進するが、欠如そのものは弱点側で扱ったものは除外または「枠の先行定義」に限定する。

---

## apps/bitflyer

- **`Bitflyer.TradeMode` でモードを型化し、live 二重確認** `0`
  > atom 正規化と述語を 1 箇所に集約。`BITFLYER_LIVE_CONFIRM` 等の二重フラグ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

- **telemetry イベント語彙を engine より先に確定** `0`
  > tick / risk rejected / order submitted / reconcile mismatch / circuit opened。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/ui/lib/ui_web/telemetry.ex`

- **鮮度付き ETS の型（`{value, received_at}` + `fresh?/2`）を先に決める** `0`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

- **起動突合と定期突合を同一 `reconcile/1` に載せる** `0`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

- **注文ライフサイクルの相関 ID と診断スナップショット** `0`
  > intent / internal / exchange / risk decision を秘密除外でまとめる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/`

---

## apps/ui

- **`GET /health` 専用エンドポイント（200/503）** `0`
  > compose healthcheck・force_ssl 除外・外部監視の共通入口。
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `compose.yaml`

- **モードバッジ色分けと発注可否の単一行表示** `0`
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **Status のポーリングを PubSub プッシュへ** `0`
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

---

## 実行基盤 / DX

- **`.dockerignore` を本番 Dockerfile より先に置く** `0`
  > 対象ファイル: リポジトリルート

- **テスト専用 DB URL の分離** `0`
  > 対象ファイル: `config/runtime.exs`, `.env.example`

- **実弾なしで `mix release` + 本番相当 Compose を一度通す** `0`
  > 対象ファイル: `mix.exs`, `.workspace/2_todo/03-cd-prod-host.md`

- **stop_grace_period と Application shutdown を揃える** `0`
  > 対象ファイル: `compose.yaml`, `apps/bitflyer/lib/bitflyer/application.ex`

- **安全要件 ↔ テスト ↔ メトリクスの traceability matrix** `0`
  > live 解禁レビューで「文書のみ」を機械的に発見する。
  > 対象ファイル: `.workspace/0_doc/architecture/`

---

## テスト・運用（後続で価値が跳ねるもの）

- **Decimal / 冪等キーのプロパティベーステスト** `0`
  > 対象ファイル: `apps/bitflyer/test/`

- **起動シーケンスのモデルベーステスト** `0`
  > 対象ファイル: `apps/bitflyer/test/`

- **bitFlyer fixture の契約テストと記録再生** `0`
  > 対象ファイル: `apps/bitflyer/test/fixtures/`

- **paper 環境での定期 Game Day（障害注入）** `0`
  > 対象ファイル: `.workspace/0_doc/architecture/env/dev.md`

- **バックアップ restore の自動検証** `0`
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **SLO / アラート予算の明文化** `0`
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **release の SBOM・署名・digest 固定** `0`
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`

---

**提案件数: 19（0点）**
