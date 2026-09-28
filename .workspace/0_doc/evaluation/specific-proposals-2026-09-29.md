# 提案（統合）2026-09-29

対象コミット: `afc46bb`
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)

点数はすべて 0。減点の最小修正は [specific-weaknesses-2026-09-29.md](./specific-weaknesses-2026-09-29.md) に改善方針として書いた。ここには、その先と、Vision 上あとでよい厚みだけを置く。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

**件数 10。点数は 0。**

---

## 技術評価層 — apps/bitflyer

### 停止履歴と戦略

- **停止の追記テーブル** `0`
  > `halted_at` の条件付き更新（減点の最小修正）の先。開閉の履歴があれば、同じ理由が何回・どれだけ止めたかを後から説明できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`

- **承認済み live 戦略の canary** `0`
  > FixedOnce の live 拒否は維持する。revision、最大 1 注文、時間帯、shadow、戻し条件を持つ 1 本が無いと、縦経路の判定段はダミーのままである。解禁条件が揃ってからでよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **金額・数量・冪等キーの property テスト** `0`
  > 「残高を増やさない」「二重 REST しない」「HWM は下がらない」を生成列で見る。例示回帰の外側。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`

- **private execution の早期通知とレート予算** `0`
  > REST の fill 同期を正本のまま、private WS を通知に足す。ページングと残高取得の上限を文書化する。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

**小計: 4件 / 0点**

---

## 横断評価層

### 長期運用

- **Fill と snapshot の保持方針** `0`
  > 生データの期間、日次 aggregate、容量の判断基準。現行の正しさは壊していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/fill.ex`

- **隔離環境での restore ドリル** `0`
  > backup hash、空 DB、migration、boot と reconcile の成功記録。手順は prod.md にある。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

- **Prometheus と SLO** `0`
  > Ready 率、再接続、拒否、突合失敗をホスト外の時系列にする。別ホスト監視の常駐とは別の厚み。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

### 依存と開発環境

- **release image と OS 依存の scanner** `0`
  > Hex の `deps.audit` と本番イメージビルドはある。高の例外に期限を付ける scanner は供給網の厚み。
  > 対象ファイル: `.github/workflows/ci.yml`, `Dockerfile.prod`

- **開発コンテナの非 root** `0`
  > 本番 runner は uid 1000。開発 Dockerfile には `USER` が無く、bind mount の生成物が root 所有になる。
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **WebSocket クライアントの採用理由** `0`
  > 再接続は Feed に委譲済み。`websockex` を残す条件と、移る条件を architecture に 1 行で足りる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/socket.ex`

**小計: 6件 / 0点**

---

## 合計

**提案 10 件 / 0 点**
