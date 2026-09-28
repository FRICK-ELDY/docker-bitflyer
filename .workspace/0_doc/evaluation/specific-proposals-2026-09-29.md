# 提案（統合）2026-09-29

対象コミット: `80c486f`（同日上書き）
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)

点数はすべて 0。減点の最小修正は [specific-weaknesses-2026-09-29.md](./specific-weaknesses-2026-09-29.md) にある。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

**件数 11。点数は 0。**

---

## 技術評価層 — apps/bitflyer

- **停止の追記テーブル** `0`
  > `halted_at` を条件付き更新した先。開閉の履歴があれば、同じ理由がどれだけ止めたかを説明できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

- **承認済み live 戦略の canary** `0`
  > FixedOnce の live 拒否は維持する。revision と最大 1 注文を持つ 1 本が無いと、判定段はダミーのままである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **金額・数量・冪等キーの property テスト** `0`
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`

- **private execution の早期通知とレート予算** `0`
  > REST の fill 同期を正本のままにする。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

**小計: 4件 / 0点**

---

## 横断評価層

- **Fill と snapshot の保持方針** `0`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **隔離環境での restore ドリル** `0`
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **Prometheus と SLO** `0`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

- **release image と OS 依存の scanner** `0`
  > 対象ファイル: `.github/workflows/ci.yml`, `Dockerfile.prod`

- **開発コンテナの非 root** `0`
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **WebSocket クライアントの採用理由** `0`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/socket.ex`

- **作業PCが落ちたときの ready 検知** `0`
  > GPT。現行の見方は作業PCの常駐で満たしている。同じ PC ではその PC の死は残らない。条件に戻さない。将来もう一台を置くなら、解除手順のあとで `READY_URL` を差し替える。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

**小計: 7件 / 0点**

---

## 合計

**提案 11 件 / 0 点**
