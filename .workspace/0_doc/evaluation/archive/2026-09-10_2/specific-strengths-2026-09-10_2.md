# プラス点統合一覧 2026-09-10_2

根拠: [evaluation-2026-09-10_2.md](./evaluation-2026-09-10_2.md) /
[opus-specific-strengths](./opus/opus-specific-strengths-2026-09-10_2.md) /
[gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-10_2.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

採用方針: 同一テーマの重複加点を抑制し、実装品質が実証された項目を残す。Opus の細分化 +185 は統合して **+90**。

**加点合計（採用）: +90**

---

## risk-manager / 認可

- **DailyLoss の Fill 正本 + 世代/barrier（force でも in-flight 尊重）** `+5`
  > invalidate → commit → 同一世代 reload。unsynced fail-closed。競合で過小評価 Ready を先回り防止。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

- **BalanceCache の hold 会計（reserve / 比例 consume / 再適用 fail-closed）** `+5`
  > 絶対残高 put 後に hold 再適用。不足なら unsynced。突合成功時のみ clear_holds。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/balance_cache.ex`

- **AuthorizedOrder（protected ETS・ワンショット・TTL・公開 new! なし）** `+4`
  > Executor は token のみ受理。偽造・再利用拒否の回帰あり。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/authorized_order.ex`

- **fail-closed な認可網（鮮度・skew・量・建玉・頻度・損失・残高・unsynced）** `+4`
  > 未同期を 0/空で通さない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

- **LiveSafety（Strategy 既定無効・FixedOnce 拒否・Risk 上限 env 必須）** `+4`
  > live+confirm だけでは意図も上限も載らない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/config/live_safety.ex`, `config/runtime.exs`

---

## order-executor / 復帰

- **モード別出口・冪等キー・hold 確保を Executor に集約** `+4`
  > dry_run / paper / live は出口だけ切替。Architecture 準拠。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **submission_unknown + 承認付き回収（曖昧は自動確定しない）** `+4`
  > timeout を rejected にせず halt。recover は hash/操作者/候補検査。Ready にしない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/submission_recovery.ex`

- **両建て外部建玉の net 正規化（順序非依存）** `+3`
  > buy−sell。片側上書きによる誤 Ready を解消。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **baseline import（二段階承認・hash・advisory lock・Ready 非変更）** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/baseline.ex`

- **InFlight drain / prep_stop（timeout 時 unknown + halt）** `+3`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/in_flight.ex`

- **paper FillPricing（slip+fee、認可拘束も同価格）** `+2`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper/fill_pricing.ex`

- **FailureRate + auth 即 halt / WS stall watchdog** `+3`
  > 401/403 即停止、連続拒否、無言接続の自己修復。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/failure_rate.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

---

## market-data / strategy

- **鮮度付き Cache・再接続・gap-fill・source_timestamp / skew** `+4`
  > 古い価格では発注しない経路が閉じている。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`

- **Strategy → System → Risk 依存強制 + revision provenance** `+4`
  > API 直叩きなし。Order に revision_id / module / command_hash。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/runner.ex`, `apps/bitflyer/lib/bitflyer/trading/strategy_parameter_revision.ex`

---

## datastore / OTP / UI / 基盤

- **Ash は永続状態限定・Decimal・Repo は bitflyer 閉じ** `+3`
  > ホットパスは ETS/GenServer。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`

- **起動突合 → 不整合 halt → Ready / resume** `+3`
  > permissions・clock・baseline 欠落で Ready にしない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`

- **StatusLive kill/resume/reconcile + BasicAuth / bind 方針** `+3`
  > 運用 UI の責務に留まっている。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **Discord アダプタ独立・秘密情報を本文に出さない** `+2`
  > 失敗しても取引を止めない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **prod ConsoleReporter + `/ops/dashboard`** `+2`
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/router.ex`

- **TRADE_MODE 既定 dry_run・dev/prod Compose 分離・secret 非焼付** `+3`
  > 対象ファイル: `config/runtime.exs`, `compose.yaml`, `compose.prod.yaml`

- **CI = mix precommit 相当 + CD が最新 CI success 必須 + Dockerfile.prod 検証** `+4`
  > 赤のまま配布しない。
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`

- **評価→improvement-plan→PR→再評価の自己改善サイクル** `+2`
  > README の risk `partial` 正直化を含む。
  > 対象ファイル: `.workspace/0_doc/evaluation/`

- **回帰テストの厚み（precommit 緑・352+35）** `+3`
  > モード分岐・halt・突合の再現が多い。

---

## 加点内訳（採用）

| 区分 | 点数 |
|:---|---:|
| DailyLoss / BalanceCache / AuthorizedOrder / 認可網 / LiveSafety | +22 |
| Executor / unknown 回収 / net / baseline / drain / FailureRate·stall / paper | +22 |
| market-data / strategy | +8 |
| datastore / 起動復帰 / UI / Discord / metrics | +13 |
| Docker·config / CI·CD / 自己改善 / テスト厚み | +12 |
| その他（permissions 等の細部、重複抑制後の残余） | +13 |
| **合計** | **+90** |

注: 「その他」は permissions・OrderRate warm・Exchange.Rest・Umbrella 2アプリ方針など、両評価で加点されたが上表で個別見出しにしなかった項目の合算枠。
