# マイナス点（統合）2026-09-29

対象コミット: `afc46bb`
基準: [vision.md](../vision.md) / [architecture/overview.md](../architecture/overview.md)
第1評価者: [opus-specific-weaknesses-2026-09-29.md](./opus/opus-specific-weaknesses-2026-09-29.md)
第2評価者: [gpt-specific-weaknesses-2026-09-29.md](./gpt/gpt-specific-weaknesses-2026-09-29.md)

まとめ側で、別ホスト監視・HWM 残窓・銘柄 allowlist・成行の板厚・`halted_at`・PeakWriter の再試行を対象ファイルで再読した。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

**合計: -7 点**

---

## 横断評価層

### 可観測性

- **VLAN1 本番ホストの外形監視が常駐配備されていない** `-2`
  > 両者一致で、外からの常駐監視は未配備である。証跡の最終更新は 2026-09-13 のままで、対象は作業 PC 上の開発 Compose、常駐は未登録である（`watch-ready-evidence.md` の冒頭と「常駐登録」行）。`/health/ready` と Discord heartbeat は取引ホスト上のプロセスが出すため、ホストごと落ちると沈黙と正常を区別できない。
  >
  > 評価時点では常駐が無く `-2` とした。その後、完了の見方を作業PCの常駐へ書き換え、2026-09-29 に `BitflyerWatchReady` が Running であることと、証跡ログの `result=fail http=000` 2 行で P1 #5 を完了にした。専用監視PCは条件にしない。解除は `bin/unregister-watch-ready-task.ps1`。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`

**小計: +0 / -2 = -2点**

---

## 技術評価層 — apps/bitflyer

### risk-manager / HWM

- **ノード強制終了で未着の当日高値が残らない** `-1`
  > 両者は残差の存在で一致し、重みだけが分かれた（Opus `-1`、GPT `-2`）。まとめは `-1`。
  >
  > `PeakWriter` は enqueue の受理までを待ち、DB 完了は待たない。moduledoc は「ノード強制終了でこのプロセスと DailyLoss の両方が消えると、DB 未着の高値は残らない」と明記する（`peak_writer.ex` L13-14, L38-39）。通常停止は `prep_stop` の drain、writer 単独再起動は ETS からの積み直し、DB の peak は `GREATEST` で下がらない。残るのは両メモリが同時に消える強制終了だけである。
  >
  > 前回の `-2` は mark に依存した flush が再起動全般で高値を落とす状態だった。その経路は閉じた。完了条件「認可直後 crash でも DB 高値が残る」は未達なので P1 #3 は部分完了のまま残す。live 解禁そのものを止める重さにはしない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`

- **PeakWriter の再試行が 50ms 固定で、障害中に同じ error ログを出し続ける** `-1`
  > Opus のみ。まとめ側で `@retry_ms 50`（`peak_writer.ex` L24, L232-234）と、失敗のたびに `DailyLoss` が `:error` で `"daily equity peak persist failed; marked unsynced"` を出すこと（`daily_loss.ex` L746-756）を確認した。DB 停止中は約 20 回/秒になる。認可は unsynced で閉じるので資金は守られる。stdout が運用ログの正本であるとき、原因行がこの繰り返しで埋まる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

### order-executor / 手数料

- **一次証跡は BTC_JPY だけなのに、live 認可は spot 8 銘柄を通す** `-1`
  > Opus のみ。`Product` は `ETH_JPY` など他 spot の手数料式を仮定と書いている（`product.ex` L108-110）。`@spot_products` は 8 銘柄（L12-21）。live の認可は `Product.spot?/1` だけを見る（`risk.ex` L270-271）。起動検査も spot 以外を拒否するだけで、証跡のある銘柄には狭めない（`live_safety.ex` L60-72）。既定運用が BTC_JPY であるあいだ実害は出ない。設定を変えると、P0 #1 の前と同じ「未実測の会計で live」に戻れる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/config/live_safety.ex`

- **live 成行買いの拘束が最良 ask の数量超過を覆わない** `-1`
  > GPT のみ。ask 拘束そのものは完了している。残差は実装が自分で書いている。ticker に気配数量が無く、サイズが最上段を超えると平均約定は ask を超え、部分約定後の解放がサイズ比なので超過分だけ利用可能 JPY が甘く残る（`risk.ex` L821-824）。取引所の残高拒否が最終防壁になる。内部の連続認可が実支出より前に進みうるので減点する。P2 #7 の完了（best ask × size）は取り消さない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

### 可観測性

- **周期突合が halted_at を毎回書き換え、最初の停止時刻が残らない** `-1`
  > Opus のみ。`persist_risk_halt/1` は失敗のたびに `DateTime.utc_now()` を `halted_at` に入れて既存行を更新する（`reconciler.ex` L390-414）。停止理由の行は 1 本で履歴が無い。同じ理由の再失敗では起点の時刻が消える。Game Day は停止中の `halted_at` を変えないよう直してある。常駐の周期突合には同じ条件が無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`

**小計: +0 / -5 = -5点**

---

## 採用しなかった減点

次は評価者が挙げ、まとめは減点にしない。提案へ置く。

- **戦略が FixedOnce 1 本**（Opus `-1`）
  > `LiveSafety` は live で FixedOnce を起動拒否する（`live_safety.ex` L93-99）。判定がダミーであることは事実である。Vision は戦略の中身を後続にしており、今の欠如は発注を止める側に倒れている。薄い live 戦略は提案。

- **開発 Dockerfile が root**（Opus `-1`、GPT は提案）
  > 本番 `Dockerfile.prod` は非 root。開発 bind mount の所有権は運用の不便で、資金保全の欠如ではない。

- **websockex の採用理由が architecture に無い**（Opus `-1`）
  > 接続の再接続責務は Feed 側にあり、依存の説明不足は移行判断の材料である。安全性の欠如としては数えない。

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| 横断 — 別ホスト監視 | -2 |
| apps/bitflyer — HWM 残窓と再試行ログ | -2 |
| apps/bitflyer — 手数料の適用範囲と板厚 | -2 |
| apps/bitflyer — 停止時刻 | -1 |
| **合計** | **-7** |
