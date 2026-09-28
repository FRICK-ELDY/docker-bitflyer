# docker-bitflyer 第2評価者 マイナス点（2026-09-29）

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地はあるが、現時点の影響は限定的 |
| -2 | 重要な機能・設計の欠如 |
| -3 | 損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | 根幹を揺るがす致命的欠陥 |

## 技術評価層 — apps/bitflyer

### risk-manager / 資金保全

- **HWM は認可復帰前の DB 同期を保証せず、ノード強制終了窓が残る** `-2`
  > `PeakWriter.enqueue/4` は GenServer の受理までは待つが DB 完了を待たず（`peak_writer.ex:38-51`）、モジュール自身も DailyLoss と PeakWriter が同時に消える強制終了では未着ピークが残らないと明記する（同 `:3-15`）。通常停止は `prep_stop` の drain（`application.ex:59-66,110-143`）、writer 単独再起動は ETS からの積み直し（`peak_writer_test.exs:115-136`）で大きく改善したが、Vision の Recoverable と「認可直後 crash でも DB 高値が残る」という完了条件は未達である。認可が返る前に単調 upsert の commit を確認するか、ノード外の durable queue / WAL に受理を確定させる必要がある。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/peak_writer.ex`, `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/test/bitflyer/risk/peak_writer_test.exs`

- **live 成行買いの拘束が最良 ask の数量超過を覆わない** `-1`
  > live 成行買いは best ask × size へ改善されているが、実装コメントどおり ticker に気配数量がなく、板を歩いた平均約定価格が ask を超える分は拘束しない（`risk.ex:821-825`）。取引所側の残高拒否は最終防壁になるものの、内部 BalanceCache が実支出より甘くなり、直後の別注文を過大認可しうる。live では深さ付き板または保守的な slippage buffer を拘束額へ加え、約定同期まで同額を hold すべきである。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`

**小計: +0 / -3 = -3点**

## 横断評価層 — 可観測性・運用

### 別ホスト監視

- **VLAN1 本番ホストの外形監視が常駐配備されていない** `-2`
  > 証跡は監視対象が同一物理 PC 上の開発 Compose で、Scheduled Task も未登録と記す（`watch-ready-evidence.md:10-29`）。さらに VLAN1 本番 URL 向け常駐、host exporter、Discord heartbeat 欠落検知を未完と明記する（同 `:73-78`）。`prod.md:420-429` の live チェックリストでも本番 ready pull と exporter は未チェックであり、取引ホストごと停止した際に「人が張り付かなくても」検知する保証がない。VLAN3 側へ常駐登録し、本番ホスト停止・監視 PC 再起動・通知到達を日時付きで実証するまで live は解禁できない。
  > 対象ファイル: `.workspace/0_doc/architecture/env/watch-ready-evidence.md`, `.workspace/0_doc/architecture/env/prod.md`

**小計: +0 / -2 = -2点**

## 合計

**減点合計: -5点**
