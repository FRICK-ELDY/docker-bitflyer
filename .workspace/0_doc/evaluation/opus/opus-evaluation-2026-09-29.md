# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-29

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-29 |
| 種別 | **再評価**（前回 2026-09-16） |
| 評価者 | 第1評価者（Claude Opus 5） |
| 基準ドキュメント | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [.cursor/rules/evaluation.mdc](../../../../.cursor/rules/evaluation.mdc) |
| 対象コミット | `afc46bb`（`Merge pull request #123 from FRICK-ELDY/fix/p2-10-completion-evidence`） |
| 詳細 | [strengths](./opus-specific-strengths-2026-09-29.md) / [weaknesses](./opus-specific-weaknesses-2026-09-29.md) / [proposals](./opus-specific-proposals-2026-09-29.md) |
    10|| 前回（自系統） | [opus/archive/2026-09-16](./archive/2026-09-16/opus-evaluation-2026-09-16.md) |
| 前回まとめ | [archive/2026-09-16/evaluation-2026-09-16.md](../archive/2026-09-16/evaluation-2026-09-16.md) |

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
    20|| 加点合計 | **+52** |
| 減点合計 | **-9** |
| **純点** | **+43** |

前回（自系統）は +31 / -16 = +15。加点が増えた理由は 2 つある。(1) 今サイクルで資金保全の中核が実際に前進した（commission 一次証跡、HWM write-behind、drain halt の外部化、ticker 2 層化、GREATEST upsert、Game Day の停止保護）。(2) 前回は差分寄りの採点だったが、今回は指示どおり**現状のシステム全体**を積み上げ、維持されている長所もコードを読み直して再加点した。

減点が -16 → -9 に下がったのは、前回 13 件のうち 7 件（-11 点分）が実際に閉じたためである。新規 3 件（-3 点分）はいずれも今サイクルで入った実装の周辺にあり、**資金を直接失う経路は見つからなかった**。

### 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
    30|| apps/bitflyer — order-executor / 手数料会計 | +8 | -1 | **+7** |
| apps/bitflyer — risk-manager / HWM | +13 | -2 | **+11** |
| apps/bitflyer — market-data | +3 | 0 | **+3** |
| apps/bitflyer — strategy | 0 | -1 | **-1** |
| apps/bitflyer — 診断タスク / 運用 | +4 | 0 | **+4** |
| apps/bitflyer — datastore / Ash | +3 | 0 | **+3** |
| apps/bitflyer — 可観測性（RiskState） | 0 | -1 | **-1** |
| 実行基盤 / 設定 | +7 | -1 | **+6** |
| CI / CD | +3 | 0 | **+3** |
| 横断（テスト戦略） | +6 | 0 | **+6** |
    40|| 横断（可観測性） | +3 | -2 | **+1** |
| 横断（変更容易性・保守性） | 0 | -1 | **-1** |
| 横断（プロジェクト全体設計・プロセス） | +2 | 0 | **+2** |
| **合計** | **+52** | **-9** | **+43** |

小計の合計は加点 +52 / 減点 -9 で、総合スコア +43 と一致する。

---

## 前回マイナス点の再検証

| # | 前回の指摘 | 前回 | 判定 | 根拠（コード再読） |
    50||:--:|:---|:---:|:---|:---|
| 1 | commission 単位が推定のまま「完了」宣言・売り側未検証 | -2 | **解決** | `commission-unit-evidence.md` L44-62 に 2026-09-28 の買い …6098 / 売り …6123 の実差分。`live_balance.ex` L290-297 が `−(S+C)`。`live_balance_test.exs` L452-518 が実測を固定 |
| 2 | 成行拘束が LTP 基準で `best_ask` を使わない | -1 | **解決** | `risk.ex` L825-834 が ask を返す。paper は L836-845 で LTP のまま |
| 3 | HWM flush の点火が mark price 依存 | -1 | **部分**（残差 -1） | `risk.ex` L660-672 が `write_behind: true`。`peak_writer.ex` L292-317 が mark 非依存。残るのはノード強制終了のみ（L13-14 が明記） |
| 4 | `DailyEquityPeak` の衝突検出が `inspect` 文字列一致 | -1 | **解決** | `daily_equity_peak.ex` L105-118 が `ON CONFLICT ... GREATEST` の 1 文。`inspect` 経路は消滅 |
| 5 | 板が crossed / ゼロで ticker を丸ごと破棄 | -1 | **解決** | `normalize.ex` L43-50, L243-251 が `book: nil` で LTP を残す。L122-137 は層があるとき平坦へ落ちない |
| 6 | `websockex` 依存の記録が無い | -1 | **未解決** | `mix.exs` L38 不変。`architecture/` に 0 件。`ci-cd.md` L69-76 にも無し |
| 7 | 戦略が `FixedOnce` 1 本 | -1 | **未解決** | `strategy/` は 3 ファイル。`live_safety.ex` L93-99 が live での有効化を拒否 |
| 8 | 開発コンテナが root | -1 | **未解決** | `Dockerfile` 全 20 行に `USER` なし |
| 9 | ハーネスが本番と同じ式で反証になっていない | -1 | **解決** | `live_exchange_harness.ex` L127-146 の 2 モデル。`live_balance_advance_test.exs` L404-409 が `:quote_mark` の halt を固定 |
    60|| 10 | 別ホスト監視が未配備 | -2 | **未解決** | `watch-ready-evidence.md` L2 の最終更新が 2026-09-13。L29 / L74-75 が未登録を明記 |
| 11 | Game Day が `RiskState` / `Readiness` を無条件に書き換える | -2 | **解決** | `game_day_stage2.ex` L66-76, L122-139 が Repo だけで読み中断。`clear_circuit` / `mark_ready` の直接呼び出しは全段から消滅 |
| 12 | improvement-plan が完了条件を満たさない項目を消している | -2 | **解決** | `improvement-plan.md` L7 のルールと `.cursor/rules/evaluation.mdc` L299-307。消化済み 11 件に観測 1 行 |

**解決 7 件（-11 点分）/ 部分 1 件 / 未解決 4 件（-5 点分）。**

### 新規のマイナス点（3 件 / -3 点）

| 指摘 | 点数 | 根拠 |
|:---|:---:|:---|
| `PeakWriter` の再試行が 50ms 固定で、DB 障害中に毎秒 20 本の `:error` ログ | -1 | `peak_writer.ex` L23, L232-235 / `daily_loss.ex` L752-757 |
| 一次証跡は `BTC_JPY` だけなのに live 認可は spot allowlist 8 銘柄を通す | -1 | `product.ex` L12-21, L108-119 / `risk.ex` L270-271 / `live_safety.ex` L60-72 |
    70|| `halted_at` が周期突合のたびに上書きされ、最初の停止時刻が残らない | -1 | `reconciler.ex` L390-397, L411-414 / `game_day_stage2_test.exs` L122-125 |

---

## improvement-plan の「完了」再読と採否

`.cursor/rules/evaluation.mdc` L299-307 の手順に従い、各「完了」の根拠行が右列「完了の見方」と矛盾しないかを、対象のコードまたは証跡で読み直した。**矛盾により採用を却下した項目は 0 件である。**

### 完了主張（11 件）— すべて採用

| # | 項目 | 完了の見方 | 再読で確認した観測 | 採否 |
|:--|:---|:---|:---|:--:|
    80|| P0 #1 | commission 一次証跡 | 売買それぞれの実差分が内部 expected と許容幅で一致し、証跡に日付・execution id がある | `commission-unit-evidence.md` L44-62 に 2026-09-28 UTC・execution 末尾 …6098 / …6123・size / price / commission・JPY と BTC の実差分・許容内判定。`live_balance_test.exs` L452-518 が同じ数値で `explain` を通す | **採用** |
| P0 #2 | ハーネス独立性 | 自モデルが誤っていても少なくとも片側モデルの失敗を検出できる | `live_exchange_harness.ex` L131-146 の `set_sell_fee_model/1`、L195-212 / L300-352 で残高を独立に動かす。`live_balance_advance_test.exs` L363-409 が `:quote_mark` の売りで `Reconciler.run_now` → `{:halted, :reconcile_mismatch}` | **採用** |
| P1 #4 | 突合窓の対称化 | — | `reconcile.ex` L290-354 に `fill_sync_retries`（既定 1）。再試行時に注入 `:fills` を削除（L345）。`reconcile_test.exs` L1168 / L1219 / L1267 に exchange-ahead の 3 ケース（前進・注入破棄・入金は依然 halt） | **採用** |
| P1 #6 | Game Day Stage 2 paper 縦経路 | — | `game_day_stage2.ex` L282-423 が paper `System.submit_order/2` で建玉を作り、Feed 断で `feed_disconnected`、復帰後に再発注 | **採用** |
| P1 #6b | Game Day が永続停止を消さない | — | `persisted_start_block/0`（L218-224）を `with_repo/1`（L146-157）で Repo だけ起動して読む。halted / unsynced は中断（L122-139）。`disarm_startup!/0`（L161-195）。`order_gate/0`（L244-259）が発注前に再読。`game_day_stage2_test.exs` L53-74 が `halted_at` 不変を assert | **採用** |
| P2 #7（09-16） | BalanceCache.probe + Runner backoff | 認可通過→予約失敗の Tight loop が消える | `risk.ex` L717-745 が本番経路で `BalanceCache.probe/4`。`runner.ex` L284-321 が銘柄単位 5s バックオフ、L264-272 が同一 tick 内の後続 command を止める | **採用** |
| P2 #8（09-16） | ticker bid/ask → spread ゲート | — | `risk.ex` L569-597 が成行のみ mid 基準で `max_spread_pct`。板欠落は `bid_ask_missing` | **採用** |
| P2 #9（ash.codegen） | ash.codegen --check / Sandbox manual / README | — | `mix.exs` L52 に `ash.codegen --check --domains Bitflyer.Trading`。`apps/bitflyer/test/test_helper.exs` は 2 行で `Sandbox.mode(Bitflyer.Repo, :manual)` | **採用** |
| P2 #7（09-28） | 成行拘束の ask 化 | — | `risk.ex` L825-834（live 成行買いは ask）、L836-845（paper は LTP）、L830-833（欠落は `bid_ask_missing`）。moduledoc L38-41 が板厚超過を拘束しないことを明記 | **採用** |
| P2 #8（09-28） | ticker 2 層化 | — | `normalize.ex` L43-50（`book: nil` で LTP を残す）、L122-137 / L146-158（層があるとき平坦へ落ちない）。`health.ex` L174-191 が `book` / `all_books` を JSON に出す | **採用** |
    90|| P2 #9（09-29） | DailyEquityPeak の GREATEST upsert | — | `daily_equity_peak.ex` L102-132 が `INSERT ... ON CONFLICT DO UPDATE SET peak = GREATEST(...)` の 1 文。`inspect` 再試行は消滅。`daily_equity_peak_upsert_test.exs` L17-30 が `sandbox: false` の別接続 3 本（`pg_backend_pid` が 3 つ）で 120000 / 150000 / 90000 を同時に投げ、保存 peak 150000 | **採用** |

### 部分完了主張（2 件）— 部分完了のまま維持（昇格させない）

| # | 項目 | 主張された残差 | 再読で確認した残差 | 判定 |
|:--|:---|:---|:---|:--:|
| P1 #3 | HWM 認可後 crash 窓 | ノード強制終了で DailyLoss と PeakWriter の両メモリが消える窓 | `daily_loss.ex` L392-408 は writer への `call` が返れば `:ok`、`peak_writer.ex` L149-161 は pending に入れて即 reply。DB 完了を待たない。残差は主張どおり存在する（`peak_writer.ex` L13-14 が自ら明記） | **部分完了を維持**（weaknesses に `-1`） |
| P2 #10 | improvement-plan 運用 | 次回評価が根拠行と見方の矛盾を落とすまでは完了にしない | 今回の再読がその検査に当たる。消化済み 11 件すべてで見方との矛盾は見つからなかった。ただし「次回評価」は本評価が初回の検査であり、継続性はまだ 1 回分 | **部分完了を維持**（strengths に `+2`） |

### 未完了として計画に残っているもの

| # | 項目 | 再読結果 |
|:--|:---|:---|
   100|| P1 #5 | 別ホスト監視の実配備 | **未達を確認**。`watch-ready-evidence.md` は最終更新 2026-09-13 のまま。L29「常駐登録: 未登録」、L74-75「VLAN1 本番 PC を `READY_URL` にした常駐は未登録」。常駐配備の記録は無い。weaknesses に `-2` |
| P3 #11〜#15 | 厚み | 資金保全を実際に損なうものは無いため原則提案。例外として #15 の 2 件（開発 Dockerfile の `USER`、`websockex` の記録）は **7 サイクル連続の滞留**なので `-1` ずつ計上した（過去サイクルと同じ扱い） |

### 前回まとめ（2026-09-16）が未解決とした 6 項目の再検証

| 項目 | 判定 | 根拠 |
|:---|:---|:---|
| commission 一次証跡 | **解決** | 証跡 L44-62 に実測。旧売り式が実差分と合わなかったことまで記録（L61） |
| 別ホスト監視 | **未解決** | 証跡が 2026-09-13 のまま |
| HWM crash 窓 | **部分** | 残差はノード強制終了のみ |
| Game Day `clear_circuit` | **解決** | `game_day_stage2.ex` から `Risk.clear_circuit()` と `Readiness.mark_ready()` の直接呼び出しが消滅。テストが `halted_at` 不変を固定 |
   110|| 完了宣言プロセス | **解決** | ルールが improvement-plan と evaluation.mdc の両方に入り、消化済み全件に観測が付いた |
| ハーネス共有モデル | **解決** | `:base_deduct` / `:quote_mark` の 2 モデルと、誤モデルでの halt 固定 |

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `mix precommit` | **本評価者は未実行**（親プロセスが品質ゲート実行中のため `_build` を奪わない） |
| `docker compose ...` | **未実行**（同上） |
| `git log` / `git diff --stat` | 実行。`a387746..afc46bb` で 55 ファイル・+3300 / -549 行 |

静的に確認した CI 定義:

   120|- `mix.exs` L47-55 の `precommit` は `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `ash.codegen --check --domains Bitflyer.Trading` / `test --warnings-as-errors` の 5 本
- `.github/workflows/ci.yml` L71-72 が同じ `mix precommit` を PostgreSQL 16 サービス上で実行（`TRADE_MODE: dry_run`、L41）
- `deps-audit` は別ジョブで、`bin/classify-deps-audit.sh` が advisory 検出とツール障害を分けて artifact に残す（L108-132）
- `docker-prod` ジョブが `Dockerfile.prod` を push なしでビルド（L137-154）
- Actions はすべて commit SHA ピン（L45, L49, L55 等）。本番シークレットは置かない方針が `ci-cd.md` L78-83

テスト規模は静的に数えて **705 件**（`apps/bitflyer/test` + `apps/ui/test` の `test` / `property` 宣言）。合否は実行していないので、本評価にテスト結果へ依拠した判定は含めていない。

未実行のまま残るもの: 実 bitFlyer private の再往復、VLAN1 監視常駐、隔離 restore、`Dockerfile.prod` フルビルド、本番長時間稼働。

---

   130|## 現状の一文

**資金会計は「公式からの類推」ではなく「実口座の実測」に乗り換わり、停止の記録は Postgres が書けないときでもディスクに残るようになった。残る live 解禁の障害は、コードではなく取引ホストの外から死活を見る監視が配備されていないことだけである。**

通っている経路は「WS ACK → Feed ゲート → Strategy（live 既定オフ）→ Risk（DailyLoss / BalanceCache / Equity / spot 在庫 / spread / ask 拘束 / 有限 open age）→ AuthorizedOrder → モード別 executor → execution 単位 Fill（`fee_currency`）→ explain 成功時の tip append → halt / resume」。HWM は認可のホットパスから外れて `PeakWriter` が書き、その drain が失敗したときは fsync した印が次回起動を止める。

欠けているのは、取引ホストの外からの Ready 常駐監視と、`BTC_JPY` 以外の spot に対する一次証跡である。

---

## live 解禁可否

**不可。**

   140|**資金保全の結論: 内部の会計・認可・停止・復帰はコード上で説明でき、実測で反証もされている。したがって残る不可の理由は資金モデルではなく「止まったことに誰も気付けない」という一点であり、VLAN1 本番 PC の `/health/ready` を別ホストから常駐監視し、取引ホスト停止を外から検知した記録が残るまで live 実発注は禁止する。**

解禁の最低条件:

1. **P1 #5 の完了。** 作業用 PC1 で `register-watch-ready-task.ps1` を VLAN1 の `READY_URL` に向けて登録し、取引ホストを実際に止めて alert が出た記録を `watch-ready-evidence.md` に残す
2. live 対象を `BTC_JPY` に固定する（または本 weaknesses の `-1` に対する evidence allowlist を入れる）

上記 2 件が閉じれば、残る `-1` 群（HWM の強制終了残差、`halted_at` 上書き、`PeakWriter` のログ増幅、開発 Dockerfile root、`websockex` 記録、戦略 1 本）はいずれも**解禁後に直しても資金を失わない**種類である。ただし解禁後は「戦略が 1 本も無い」ため、実際に連続運用へ入るには薄い live 戦略が別途要る。

---

## 優先して直す順

   150|1. **VLAN1 本番 PC の `/health/ready` 常駐監視を登録し、停止検知を実証する**（P1 #5。live 解禁の単一残条件。1 回の作業で閉じる）
2. **live 認可を一次証跡のある銘柄に狭める**（`Product` の evidence allowlist。P0 #1 で作った規律を認可側へ引き継ぐ）
3. **`halted_at` を条件付き更新にする**（同一理由の再失敗では書き換えない。停止の起点を残す。5 行）
4. **`PeakWriter` の再試行を指数バックオフにし、`peak_persist_failed` のログを抑制する**（DB 障害中に原因行が埋まらないようにする）
5. **`prod.md` に強制終了時の HWM 残差と運用対策を明記する**（P1 #3 の部分完了を、コードを増やさずに確定させる）
6. **7 サイクル連続の軽微 2 件を消す**（開発 `Dockerfile` の `USER`、`websockex` の記録または `~> 0.5` への更新）。「必ず消す」を 2 サイクル連続で守れれば、P3 滞留という構造問題そのものが閉じる
7. **live で有効化できる薄い戦略 1 本**（解禁条件が揃ってから。判定段がダミーである限り縦経路は本物にならない）
