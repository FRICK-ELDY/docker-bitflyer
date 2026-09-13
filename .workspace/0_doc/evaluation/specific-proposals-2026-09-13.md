# 提案（0点）統合一覧 2026-09-13

根拠: [evaluation-2026-09-13.md](./evaluation-2026-09-13.md) /
[opus-specific-proposals](./opus/opus-specific-proposals-2026-09-13.md) /
[gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-13.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

マイナス点の修正と一体のものは improvement-plan の P0/P1 に回し、ここでは前向きな次ステップのみ残す。前回提案の「擬似取引所ハーネス」は実装済みのため削除。

---

## 資金保全の次段

- **live 起動時に `getpositions` を 1 回呼び、FX/CFD 建玉が空であることを機械で確認する** `0`
  > 同一キーの手動 FX 建玉は監視外と文書化済み。空でなければ `unsafe_account_state` で halt。周期では呼ばない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **板 / bid-ask spread・板厚・`getboardstate` の流動性ゲート** `0`
  > ticker の `best_bid` / `best_ask` から先に作れる。板 snapshot は後続。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **資金状態機械のモデルベース / プロパティ試験（fee 通貨を含む）** `0`
  > 任意 Fill 列で explain 成功、入金は必ず mismatch、advance の冪等、誤った fee 通貨は必ず失敗。今回のハーネス誤一致を減らす。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/startup/live_balance_test.exs`

- **`Exchange.Rest` に Private API のレート予算と 429 backoff を持たせる** `0`
  > ページングで 1 突合が最大 20 リクエストまで伸びうる。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **private execution WS を同期トリガーに併用する** `0`
  > REST `getexecutions` を正本のまま、イベントで遅延を短くする。欠落時は周期 REST。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live_fills.ex`

---

## 観測・運用

- **Prometheus + SLO** `0`
  > ready 率、Feed 再接続、reconcile mismatch、損失 headroom。高カーディナリティラベルは出さない。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`

- **Discord 到達の自己検査と重要通知の有限 retry** `0`
  > `last_discord_ok_at` を Status に出す。halt 欠落は spool または別経路。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **`mix bitflyer.preflight`（live 解禁条件の機械可読化）** `0`
  > CONFIRM 日付、出金権限、spot 限定、上限 env、open age、tip、halt、直近 Game Day。発注 REST は呼ばない。
  >
  > 対象ファイル: `apps/bitflyer/lib/mix/tasks/`

- **過去 ticker の paper リプレイ（`mix bitflyer.simulate`）** `0`
  > 戦略と Risk を実 API なしで通す。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/cache.ex`

- **隔離環境への定期 restore Game Day** `0`
  > ダンプの存在を復旧成功の実測へ進める。
  >
  > 対象ファイル: `bin/backup-db.sh`

- **Fill の日次ロールアップ** `0`
  > `sum_realized` の全行読みを当日分に限定し、剪定しても損益履歴を残す。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`

---

## 戦略・供給網

- **戦略 revision の canary と二者承認** `0`
  > Baseline と同じ `--confirm` + hash。適用後は件数・時間で上限を絞り、自動ロールバック。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/revision.ex`

- **SBOM・コンテナ署名・デプロイ時検証** `0`
  > Hex advisory の次段。GitHub tag 依存と OS を覆う。
  >
  > 対象ファイル: `.github/workflows/ci.yml`, `.github/workflows/cd.yml`
