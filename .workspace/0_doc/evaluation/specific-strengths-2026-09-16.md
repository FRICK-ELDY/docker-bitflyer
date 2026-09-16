# プラス点 統合一覧 2026-09-16

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている |
| +2 | 一般的なベストプラクティス |
| +3 | 同規模・同種の平均を明確に上回る |
| +4 | プロダクション級 |
| +5 | 個人プロジェクトでは稀な卓越 |

根拠: [opus-strengths](./opus/opus-specific-strengths-2026-09-16.md) / [gpt-strengths](./gpt/gpt-specific-strengths-2026-09-16.md)。同一テーマの重複は抑制し、本サイクルで閉じた資金保全部品を優先して加点する。

**採用加点合計: +118**

---

## 技術評価層 — apps/bitflyer

### market-data

- **購読成立を JSON-RPC ACK まで遅延** `+4`
- **再接続・gap-fill・鮮度・時計ずれが発注拒否まで接続** `+4`
- **bid/ask 正規化と成行 spread ゲート（fail-closed）** `+3`

### strategy

- **Strategy → Risk → Executor の一方向と provenance** `+3`
- **再起動重複抑制と残高不足 backoff** `+2`

### risk-manager / live 会計

- **多層 fail-closed 認可ゲート** `+4`
- **commission を Product 起点で Position / LiveBalance / PnL に一貫接続** `+4`
- **HWM の `persisted_peak` + 3 値プロトコル（ホットパス非同期維持）** `+3`
- **BalanceCache.probe と generation/barrier** `+3`
- **live 設定分離（spot 限定・FixedOnce 禁止・上限 env 必須・当日 confirm）** `+4`

### order-executor / recovery

- **AuthorizedOrder + 内部注文 ID 冪等** `+4`
- **残高 tip を説明可能差分だけ前進** `+4`
- **execution 単位記帳・coverage・ページング** `+4`
- **`submission_unknown` と受注後同期失敗の分離** `+4`
- **有限 open age と終端確認後 hold 解放** `+3`
- **突合窓の両向き救済（`fill_sync_retries`）** `+3`

### datastore / cache / OTP

- **Ash を永続状態に限定、価格数量 Decimal、Repo が bitflyer に閉じる** `+3`
- **ETS 鮮度キャッシュと消失時再構築前提（Redis 非導入）** `+2`
- **Endpoint と取引監督の兄弟化・Readiness fail-closed** `+3`

### observe

- **Telemetry allowlist・Discord 非遮断・Contract corpus** `+3`
- **health live/ready 分離と Compose liveness** `+2`

---

## apps/ui / 実行基盤 / CI

- **Status UI が運用閲覧に限定、Ash/System 経由、BasicAuth** `+3`
- **TRADE_MODE 既定 dry_run・秘密の env 注入・prod 非 root** `+3`
- **`mix precommit` 単一ゲート（GPT 実行: 668 tests 緑）・deps.audit** `+3`
- **Game Day Stage 2 の paper 縦経路（Executor 貫通）** `+2`
- **moduledoc に残差・TOCTOU を自己記載** `+2`

---

## 小計メモ

| 出典 | 加点 |
|:---|---:|
| Opus 生 | +31（テーマ圧縮・本サイクル差分寄り） |
| GPT 生 | +110（網羅） |
| **まとめ（重複抑制）** | **+118** |

前回まとめ +114 から、手数料モデル書き換え・HWM flush・probe・fill_sync・spread・Stage2 を反映して微増。基盤加点の二重計上は避けた。
