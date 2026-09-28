# マイナス点（統合）2026-09-29

対象コミット: `80c486f`（同日上書き。朝の下書きは `afc46bb` 時点）
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)
第1評価者: [opus-specific-weaknesses-2026-09-29.md](./opus/opus-specific-weaknesses-2026-09-29.md)
第2評価者: [gpt-specific-weaknesses-2026-09-29.md](./gpt/gpt-specific-weaknesses-2026-09-29.md)

P1 #3 と P1 #5 は、書き換えたあとの見方をコードと証跡で満たすので減点に残さない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -6 点**

---

## 技術評価層 — apps/bitflyer

### risk / 手数料 / 停止

- **live 成行買いの拘束が最良 ask の数量超過を覆わない** `-1`
  > GPT。実装コメントどおり、ticker に気配数量が無く、最上段を超えると平均約定は ask を超えうる（`risk.ex` L821-824）。取引所の残高拒否が最終防壁になる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **周期突合が halted_at を毎回書き換え、最初の停止時刻が残らない** `-1`
  > Opus。`persist_risk_halt/1` は失敗のたびに現在時刻で既存行を更新する（`reconciler.ex` L390-414）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

- **PeakWriter の再試行が 50ms 固定で、同じ error ログを出し続ける** `-1`
  > Opus。`@retry_ms 50`（`peak_writer.ex` L24, L171-174）。失敗のたびに `DailyLoss` が `:error` を出す（`daily_loss.ex` L746-756）。認可は unsynced で閉じる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **一次証跡は BTC_JPY だけなのに、live 認可は spot 8 銘柄を通す** `-1`
  > Opus。`product.ex` L108-110 は他 spot の手数料式を仮定と書く。認可は `Product.spot?/1` のみ（`risk.ex` L270-271）。既定が BTC_JPY のあいだは実害が出ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **認可は DB 往復するのに、Risk の説明は往復しないと書いたまま** `-1`
  > Opus。`risk.ex` L27-31 は「HWM 永続化のために DB 往復しない」「cast する」と書く。現行の enqueue は upsert が終わるまで `:ok` を返さない（`peak_writer.ex` L153-170）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`

**小計: +0 / -5 = -5点**

---

## 横断評価層

### 証跡

- **watch-ready の証跡が、冒頭の完了条件と今回の常駐記録で食い違う** `-1`
  > Opus。冒頭は「取引ホストが死んでも、外の監視ホストが残す。同一ホストの localhost では閉じない」と書く（`watch-ready-evidence.md` L6-7）。同じファイルの常駐記録は、作業PCから `127.0.0.1:4000` を引く常駐を P1 #5 の完了としている。完了の見方（作業PCの常駐・失敗ログ・解除手順）自体は満たすので、#5 の完了は取り消さない。文書の自己矛盾だけを減点する。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

**小計: +0 / -1 = -1点**

---

## 採用しなかった減点

次は Opus が減点し、まとめは提案へ置く。

- **戦略が FixedOnce のみ** `-1` を不採用
  > live では FixedOnce を起動拒否する。Vision は戦略の中身を後続にしている。

- **開発 Dockerfile が root** `-1` を不採用
  > 本番イメージは非 root。開発生成物の所有権は資金保全の欠如ではない。

- **websockex の採用理由が architecture に無い** `-1` を不採用
  > 再接続の責務は Feed 側にある。説明の不足は提案。

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer | -5 |
| 証跡の自己矛盾 | -1 |
| **合計** | **-6** |
