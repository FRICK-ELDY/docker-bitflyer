# 改善提案書（improvement-plan）

最終更新: 2026-09-29（同日上書き再評価が P1 #3 と #5 の完了を採用。純点 +66。live の監視条件は閉じた）
根拠: [evaluation-2026-09-29.md](./evaluation-2026-09-29.md) / [specific-weaknesses-2026-09-29.md](./specific-weaknesses-2026-09-29.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** P1 の未完了は無い。戦略の高度化は P2 の後でもよい。

**完了宣言ルール:** 「完了」と書くときは、右列「完了の見方」を満たした根拠を 1 行必須にする。根拠は日付と、見方が真だと分かる観測（テスト名、証跡の差分、実行結果）を含む。「コード再読」だけでは根拠にしない。満たせない項目は取り消し線にせず **部分完了** と残す。見方を下げるときは、先に右列を書き換える。次回評価は根拠行と見方の矛盾を、コードまたは証跡の再読で落とす（手順は `.cursor/rules/evaluation.mdc` の「improvement-plan の完了宣言」）。

---

## 消化済み（2026-09-29 の再読で維持）

| # | 項目 | 状態 |
|:---:|:---|:---|
| — | tip 前進骨格・ゼロ手数料ハーネス（旧 P0） | 部品として維持 |
| — | Feed 認可・spot 在庫・ACK・有限 open age・ページング | 維持 |
| P1 #4 | 突合窓の対称化（`fill_sync_retries`） | **完了**（2026-09-16。`reconcile_test` の exchange-ahead は fill 再同期 1 回で `{:ok}` と tip 前進。再同期後も説明できない入金は `balance_mismatch`。2026-09-29 再読で見方との矛盾なし） |
| P1 #6 | Game Day Stage 2 の paper 縦経路 | **コード経路は完了**（2026-09-16。`bitflyer.game_day_stage2` は paper の `System.submit_order/2` で建玉を作り、Feed 断は `feed_disconnected`。2026-09-29 再読で見方との矛盾なし） |
| P1 #6b | Game Day の停止解除副作用 | **完了**（2026-09-28。paper の中断は Repo だけで読み、監督木は起動しない。既存停止の `halted_at` は変えない。2026-09-29 再読で見方との矛盾なし。同日 P2 #17 で、同一 reason の起動突合も `halted_at` を残す） |
| P2 #7（2026-09-16） | BalanceCache.probe + Runner backoff | **完了**（2026-09-16。`runner_test` は `insufficient_balance` のあと、throttle 0 の再 tick でも `last_evaluated` を進めず注文を作らない。2026-09-29 再読で見方との矛盾なし） |
| P2 #8 | ticker bid/ask → spread ゲート | **完了**（2026-09-16。`risk_test` は spread 4%・上限 0.5% の成行を `max_spread_pct` で拒否する。2026-09-29 再読で見方との矛盾なし） |
| P2 #9（ash.codegen） | ash.codegen --check / Sandbox manual / README | **完了**（2026-09-16。precommit に `ash.codegen --check --domains Bitflyer.Trading`。両 `test_helper.exs` は Sandbox `:manual`。2026-09-29 再読で見方との矛盾なし） |
| P2 #10 | improvement-plan 運用 | **完了**（2026-09-29。完了主張 11 件をコードまたは証跡と突き合わせ、見方と矛盾して却下した項目は 0。記録は [evaluation-2026-09-29.md](./evaluation-2026-09-29.md) の採否表） |
| P0 #1 | commission 一次証跡 | **完了**（2026-09-28。買い …6098 / 売り …6123 の実差分が更新後 expected と JPY 1 円・BTC 1 satoshi 以内。2026-09-29 再読で見方との矛盾なし。適用範囲は BTC_JPY。他銘柄の live 通過は P2 #16 で証跡集合に閉じた） |
| P0 #2 | ハーネス独立性 | **完了**（2026-09-28。`:quote_mark` の売りは発注→約定同期→Reconciler で `balance_mismatch` halt。既定の縦回帰は Ready。2026-09-29 再読で見方との矛盾なし） |
| P2 #7（2026-09-28） | 成行拘束の ask 化 | **完了**（2026-09-28。live 成行買いの probe/reserve は `best_ask × size` ちょうど。ask 欠落は `bid_ask_missing`。最上段以内は ask ちょうどのまま。超過分は P2 #19） |
| P2 #8 | ticker 2 層化 | **完了**（2026-09-28。crossed / 欠落 / ゼロの板は `book: nil` のまま LTP を Cache に載せる。成行認可は `bid_ask_missing`。2026-09-29 再読で見方との矛盾なし） |
| P2 #9（2026-09-29） | DailyEquityPeak の GREATEST upsert | **完了**（2026-09-29。`upsert/3` は `INSERT ... ON CONFLICT DO UPDATE SET peak = GREATEST(...)` の 1 文。別接続 3 本で保存 peak は最高値。2026-09-29 再読で見方との矛盾なし） |
| P1 #3 | HWM 認可後 crash 窓 | **完了**（2026-09-29。`peak_writer_test` の `write-behind success leaves the DB peak after both processes are discarded` は `record_peak` が `160000` を返したあと PeakWriter を kill し `DailyLoss.reinit` してもその peak が残る。upsert 失敗の enqueue は `{:error, :unsynced}`） |
| P1 #5 | 作業PCでの ready 常駐 | **完了**（2026-09-29。見方を先に「作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残り、解除手順がある」へ書き換えた。`Get-ScheduledTask -TaskName BitflyerWatchReady` の State は Running。`%LOCALAPPDATA%\bitflyer\watch-ready.log` に `2026-09-28T17:28:41Z result=fail http=000` と `2026-09-28T17:29:43Z result=fail http=000`。解除は `bin/unregister-watch-ready-task.ps1`） |
| P2 #16 | live 銘柄を一次証跡へ合わせる | **完了**（2026-09-29。`live_safety_test` の `apply_live_overrides! rejects ETH_JPY alone or mixed with BTC_JPY` は `["ETH_JPY"]` と `["BTC_JPY", "ETH_JPY"]` の両方で `ArgumentError`。`risk_test` の `live rejects ETH_JPY because commission evidence is BTC_JPY only` は live 認可が `unsupported_product_for_live`。82 tests, 0 failures） |
| P2 #17 | `halted_at` を起点のまま残す | **完了**（2026-09-29。`halted_at` はその reason で最初に止まった時刻。`game_day_stage2_test` の `application reconciler child boots only when env boot? is true` は `boot?: true` の起動後に `:periodic_reconcile` しても `manual_halt` の時刻を残す。`reconcile_test` の同一 reason の周期 2 回目も残す。`legacy_unmapped_halt` は `risk_halted` へ変わり時刻が進む） |
| P2 #18 | PeakWriter の再試行間隔 | **完了**（2026-09-29。`repeated db failures back off and do not repeat the same error` は `retry_timer_left` が 50ms 以下から 4 秒超へ延び、同じ error は続かず live は unsynced のまま。`a failed lower enqueue keeps the higher pending peak` は失敗した 100000 のあとも pending と DB が 200000。paper の成功後も live の `retry_ms` は 200 のまま、待ちタイマーが残る） |
| P2 #19 | 成行買いの板厚超過 | **完了**（2026-09-29。余白では支出の上限にならないため、最上段を超える live 成行買いは拒否する。`live market buy rejects a size that walks past the top` は size 0.02・最上段 0.01 で `ask_depth`。数量の無い板は `ask_size_missing`。最上段以内は ask×size） |

**「済」＝ live 解禁ではない。**

---

## P0 — live 解禁の前に塞ぐ穴

P0 に未完了は無い。前回まで P0 だった commission とハーネスは上表のとおり完了。

---

## P1 — 停止からの出口と安全装置

未完了は無い。#3 と #5 は上の消化済み表にある。

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 20 | ready 証跡の冒頭を見方に合わせる | `watch-ready-evidence.md` 冒頭の「外の監視ホストが無いと閉じない」を、作業PC常駐を完了とする現行の見方へ書き換える。完了の事実は取り消さない | 冒頭と 2026-09-29 の常駐記録が同じ完了条件を述べる |
| 21 | Risk の説明を実装に合わせる | `risk.ex` の「HWM のために DB 往復しない / cast する」を、enqueue が upsert 完了まで `:ok` を返さない実装へ合わせる | moduledoc を読んだ人が、認可の戻り前に DB へ書くと分かる |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + `sum_realized` の DB aggregate | 24/365 で表肥大の判断基準がある |
| 12 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 13 | Hex 外 scanner | release image / lock の Trivy 等。high の例外期限 | GitHub tag と OS がゲートに入る |
| 14 | 隔離 restore 証跡 | backup hash → 空 DB → migration → boot/reconcile を記録 | Recoverable が手順だけでなく成功記録になる |
| 15 | 残る軽微 | 開発 Dockerfile の USER、websockex の採用理由 1 行 | 開発生成物が root 所有にならない、または採用理由が architecture にある |

HWM の認可経路は upsert 完了後に `:ok` を返す。P1 #3 は上表のとおり完了。

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ canary（live で FixedOnce は拒否済み。解禁後に薄い 1 本）
- 板の本格購読・プロパティテストの本格導入
- private execution WS、API レート予算、起動時 `getpositions` 空検査
- SBOM / 署名、裁量向け UI、複数取引所、ML 基盤、FX 証拠金（backlog）

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |
| FX 証拠金 | `.workspace/1_backlog/fx-collateral-adapter.md`（live は spot 限定で先行済み） |
| 本番 CD | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |
| Game Day | [game-day.md](../architecture/env/game-day.md) |

次回評価では、P1 #5 の根拠（タスク `BitflyerWatchReady` が残り、証跡ログに探針結果があること）が見方とまだ合うかを確認する。専用監視PCを完了条件に戻さない。
