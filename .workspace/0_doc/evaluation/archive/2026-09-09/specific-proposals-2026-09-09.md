# 提案（0点）の統合一覧 2026-09-09

根拠: [opus-specific-proposals](./opus/opus-specific-proposals-2026-09-09.md) / [gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-09.md)  
方針: 必須欠如は weaknesses 側。ここは実装すれば価値が上がる前向きな次手のみ。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

---

## 取引ドメインの厚み

- **認可済み command を型で表現する（AuthorizedOrder）** `0`
  > Risk 成功時のみ opaque 型を返し、executor はそれ以外を受けない。`authorize?: false` 問題の根本対策にもなる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `order_executor.ex`
  > 出典: GPT

- **Transactional outbox / submission 状態機械** `0`
  > `prepared → submitting → acknowledged / unknown / rejected`。timeout と persist 失敗の決定的回復に効く。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`
  > 出典: GPT

- **Fill / Execution 履歴 Resource** `0`
  > 部分約定・手数料・日次損益の根拠を後から再構成できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`
  > 出典: Opus

- **`Bitflyer.Strategy` ビヘイビア（純関数）を先に置く** `0`
  > API 直叩き禁止と単体テスト容易性を型で固定。アルゴリズムの中身は後でよい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`
  > 出典: Opus（欠如自体は weaknesses）

- **paper にスリッページ・手数料モデル** `0`
  > LTP ± bps + 手数料率で本番楽観バイアスを減らす。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`
  > 出典: Opus

---

## 運用・可視化

- **OperationalStatus 単一スナップショット API** `0`
  > gate / freshness / Feed / 突合 / 未確定を一括。StatusLive と `/ready` の判定ずれ防止。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`, `apps/ui/lib/ui_web/live/status_live.ex`
  > 出典: GPT（Opus も StatusLive 強化を weaknesses で要求）

- **`/live` と `/ready` の分離** `0`
  > 起動中 200 を保ちつつ、外形 readiness に stale / Feed を載せる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`
  > 出典: GPT / Opus

- **PubSub による状態即時反映** `0`
  > halt / disconnect を polling より早く画面へ。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`
  > 出典: GPT

- **運用操作の監査ログ** `0`
  > halt 解除・手動サーキットの実行者・理由を残す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`
  > 出典: Opus

- **アラート閾値と心拍の数値化** `0`
  > 通知実装と同時に prod.md へ N 秒切断・M 分滞留・心拍欠落を書く。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`
  > 出典: Opus

---

## テスト・検証

- **プロパティベーステスト（冪等・建玉マージ・Decimal）** `0`
  > `stream_data` は既に lock にある。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/`
  > 出典: 双方

- **状態機械のモデルベース障害試験** `0`
  > 送信中・ID 永続化前などで process/DB を落とし二重発注なしを証明。
  > 対象ファイル: `apps/bitflyer/test/bitflyer/regression/`
  > 出典: GPT

- **ticker fixture 再生による契約テスト** `0`
  > 実ネットなしで schema 変更・欠損・極端値を継続検証。
  > 対象ファイル: `apps/bitflyer/test/fixtures/`
  > 出典: GPT

---

## 本番・セキュリティ（必須欠如の先）

- **SBOM / イメージ署名 / Dependabot** `0`
  > release 後の供給鎖。最初は可視化のみでよい。
  > 出典: GPT / Opus deps audit の延長

- **paper Game Day スクリプト** `0`
  > 切断・halt・再開を手順化した定期演習。
  > 出典: 前回提案の継続
