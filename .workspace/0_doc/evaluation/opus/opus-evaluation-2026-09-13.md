# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-13

## 評価メタ情報

| 項目 | 内容 |
|:---|:---|
| 評価者 | 第1評価者（Claude Opus 5） |
| 評価日 | 2026-09-13 |
| 対象コミット | `cfaf0a526ca94c176997aa176ca30edd69bae307`（`Merge pull request #103 from FRICK-ELDY/ops/p2-game-day-stage-2`） |
| 前回評価コミット | `1cfb413` |
| 前回比の変更量 | 107 ファイル / +8884 行 / -357 行 |
| テスト件数 | **637 件**（bitflyer 599 + 1 doctest / ui 38）— 前回 521 件から +116 |

### 基準文書

- [.workspace/0_doc/vision.md](../../vision.md)
- [.workspace/0_doc/architecture/overview.md](../../architecture/overview.md) および `architecture/` 配下
- [.cursor/rules/evaluation.mdc](../../../../.cursor/rules/evaluation.mdc)（評価ルール正本）

### 検証対象文書

- [.workspace/0_doc/evaluation/improvement-plan.md](../improvement-plan.md)（宣言の真偽を現行コードで判定した。上書きしていない）
- [.workspace/0_doc/evaluation/archive/2026-09-12/evaluation-2026-09-12.md](../archive/2026-09-12/evaluation-2026-09-12.md)（前回まとめ＝起点）

### 自系統の前回詳細

- [opus-specific-weaknesses-2026-09-12.md](./archive/2026-09-12/opus-specific-weaknesses-2026-09-12.md)
- [opus-specific-strengths-2026-09-12.md](./archive/2026-09-12/opus-specific-strengths-2026-09-12.md)
- [opus-specific-proposals-2026-09-12.md](./archive/2026-09-12/opus-specific-proposals-2026-09-12.md)

### 今回の詳細文書

- [opus-specific-weaknesses-2026-09-13.md](./opus-specific-weaknesses-2026-09-13.md)
- [opus-specific-strengths-2026-09-13.md](./opus-specific-strengths-2026-09-13.md)
- [opus-specific-proposals-2026-09-13.md](./opus-specific-proposals-2026-09-13.md)

### 独立性の宣言

> 本評価にあたり、**第2評価者（GPT）の 2026-09-13 文書および `.workspace/0_doc/evaluation/gpt/` 配下（archive を含む）は一切参照していない**。相手評価者の判断を推測して点数を寄せる操作も行っていない。参照したのは上記の基準文書・自系統の前回文書・`improvement-plan.md`・README / CI / config / 現行コードとテストのみである。
>
> また、過去文書の「解決済み」記述を根拠に判定した項目は 1 件も無い。P0–P2 の 11 項目および前回マイナス点 13 件は、すべて該当ファイルを開いて現行コードを読んで判定した。

---

## 総合点

| 区分 | 今回（2026-09-13） | 前回（2026-09-12） | 差分 |
|:---|---:|---:|---:|
| 加点合計 | **+231** | +203 | **+28** |
| 減点合計 | **-15** | -18 | **+3** |
| **純点** | **+216** | +185 | **+31** |
| 提案数 | 11 件（0 点） | 12 件（0 点） | -1 |

1 サイクルで純点 +31 は大きい。内訳としては、加点の伸び（+28）が「P0/P1/P2 の実装で新しく生まれた良い設計」、減点の縮小（+3）が「前回ブロッカー 6 件の解消（-11 点分）と新規 4 件の発生（-6 点分）、プロセス減点 1 件（-1）」の差である。

---

## improvement-plan の判定

`improvement-plan.md`（2026-09-13 更新）は P0 2 件・P1 4 件・P2 5 件の実装完了を主張している。すべて対象ファイルを開いて判定した。

### P0（live 解禁の前提）

| # | 項目 | 宣言 | 判定 | 根拠 |
|:---:|:---|:---|:---|:---|
| 1 | live 残高正本の前進 | 完了 | **解決** | `LiveBalance`（547 行）の `explain/4` が 内部 tip + Fill デルタ + 手数料許容で取引所 `getbalance` を説明し、`advance/2` が `BalanceSnapshot` tip を前進させる。`Reconcile.compare_with_exchange` は explain → `LiveInventory` → open_orders → advance の順（reconcile.ex L320-341）。`Baseline` は初期化専用に据え置かれ、rebaseline は `--confirm` + `expected_hash` + `operator` の別経路（baseline.ex L169-184, L379-399）。宣言は過大ではない |
| 2 | 縦貫通回帰 | 完了 | **解決** | `LiveExchangeHarness`（341 行）が `Exchange.Behaviour` の全関数をダブル化し、`getbalance` を約定と手数料に応じて実際に動かす。`regression/live_balance_advance_test.exs`（432 行、`async: false`）が 発注 → 約定 → 突合 → tip 前進 → 再起動 → 再突合（変化なし）を実経路で通す。手数料あり／なし、部分約定、入金混入（= halt）まで網羅 |

**P0 は 2 件とも解決。宣言に過大は無い。**

### P1

| # | 項目 | 宣言 | 判定 | 根拠 |
|:---:|:---|:---|:---|:---|
| 3 | HWM 永続化 | 完了 | **部分解決** | `DailyEquityPeak` Resource と `load_peaks/2`（daily_loss.ex L599-608）で init / reload / reinit が当日ピークを DB から復元する。単調増加の条件付き更新、並行 upsert の衝突処理も入っている。**ただし認可ホットパスで ETS だけに上がったピークを DB へ流す経路が無い**（`prepare_peak` は「ETS peak より高いか」しか見ず、認可は `persist: false`）。周期 enforce のあいだに伸びたピークは、その後 equity が下がると恒久的に DB へ書かれず、再起動で drawdown 基準が緩む。完了条件の「実現益後の含み損状態で再起動しても drawdown が消えない」は、周期をまたぐピークについて未達 → weaknesses に `-2` |
| 4 | live 手数料 | 完了 | **解決** | `Fill.fee` 属性 + マイグレーション（`20260912220000_add_fills_fee.exs`）、`Decode` が `commission` を取り出し、`Positions.apply_fill` が realized_pnl から手数料を差し引く。`LiveBalance` は quote / base で非対称な許容幅（`fee_explained?`）を持ち、手数料ぶんの目減りだけを許して入金方向は拒否する。ハーネス側も約定時に commission を引いて `getbalance` を動かすので、回帰が手数料込みで閉じている |
| 5 | spot 在庫突合 | 完了 | **解決** | `SpotInventory`（認可・突合共用の集計）＋ `LiveInventory.compare/4`（152 行）。取引所 base amount と内部 買い `Position.size` を通貨ごとに比較し、売建玉は `spot_short_position`、超過は `spot_inventory_inflated` で halt（live_inventory.ex L37-97）。認可側は `check_spot_sell_cover`（risk.ex L485-502）が同じ `SpotInventory.sell_covered?/4` を呼ぶので、判定ロジックが 1 本に寄っている |
| 6 | 認可に Feed 接続 | 完了 | **解決** | `check_market_feed/2` が `check_freshness` の前に入った（risk.ex L101）。入力は `Feed.connection_snapshot/0` で、`:persistent_term` に置いた `{pid, connected?}` の pid 一致を検査するため、死んだ Feed の古いスナップショットを connected と誤読しない（feed.ex L54-68）。`operational_status.ex` にあった「Risk は Feed を見ない」旨の残差記述も削除済み |

**P1 は 3 件解決・1 件部分解決。#3 の宣言は過大（完了条件を満たしていない）。**

### P2

| # | 項目 | 宣言 | 判定 | 根拠 |
|:---:|:---|:---|:---|:---|
| 7 | 購読 ACK | 完了 | **解決** | `Feed` が JSON-RPC の request id を採番して `pending_subscriptions` で追跡し、`Normalize.from_response/1` が `{:ack, id}` / `{:error, id, reason}` を返す。ACK 未達はタイムアウトで再購読、error は再接続。`Readiness` へ流れるのは ACK 済みチャネルのみ |
| 8 | live 未約定期限 | 完了 | **解決** | `LiveSafety` が live で `BITFLYER_MAX_OPEN_AGE_MS` を必須化（有限値の検査つき）、`OpenOrderPolicy.cancel_aged_opens/1` が期限超過を cancel、`HaltCancelGate` で halt 時の cancel-all を 1 本化。`runtime.exs` が live での欠落を起動時に落とす。テストは `open_order_policy_test.exs` 598 行 |
| 9 | executions ページング | 完了 | **解決** | `fetch_execution_pages/6` が `before` で降順に取り切り、最終満杯ページは次ページが空／短いときだけ確定、上限到達で `:execution_pages_exhausted` を返して fail-closed（rest.ex L113-199）。`execution_page_size: 500` / `execution_max_pages: 20`（config.exs L17-18） |
| 10 | 別ホスト監視の実配備 | 完了 | **部分解決** | `bin/watch-ready.ps1`（122 行）と `bin/register-watch-ready-task.ps1`（54 行）は実装され、`watch-ready-evidence.md` に非 ready（HTTP 500）と到達不能（`http=000` × 3 → alert）の実走ログがある。**ただし監視と取引が同一物理ホストに乗っており（evidence L17-19 が自認）、常駐登録は未実施**。overview.md L167 が掲げる「同一ホスト死の検知は取引ホストの外」は未成立 → weaknesses に `-1` |
| 11 | Game Day Stage 2 | 完了 | **解決** | `game-day.md` に paper モードでの Stage 2 実走記録がある。WS URL 制約（`BITFLYER_WS_URL` の許可先を絞る）、Feed 切断 → not_ready → 復帰、halt → Resume までを実測値つきで記録し、**閉じなかった項目（Discord 到達の目視）を正直に残している**。報告の透明性は加点対象にした |

**P2 は 4 件解決・1 件部分解決。**

### 判定サマリ

| 区分 | 解決 | 部分解決 | 未解決 |
|:---|---:|---:|---:|
| P0 | 2 | 0 | 0 |
| P1 | 3 | 1 | 0 |
| P2 | 4 | 1 | 0 |
| **合計** | **9** | **2** | **0** |

宣言と実装の一致度は高い。過大宣言は P1 #3（HWM）と P2 #10（別ホスト監視）の 2 件で、いずれも「主要部は実装済み、完了条件の最後の一段が未達」という性質である。虚偽ではなく、完了条件の詰めが甘い。

---

## 自系統前回マイナス点の解決状況

| 前回の指摘 | 前回 | 判定 | 今回 |
|:---|:---:|:---|:---:|
| live 残高突合が固定 baseline との厳密一致（tip 不前進） | -4 | **解決** | 0 |
| live spot で建玉突合が無効 | -2 | **解決** | 0 |
| 当日 equity ピーク（HWM）が非永続 | -2 | **部分解決** | -2（性質変化） |
| `Risk.authorize/2` が Feed 接続を見ない | -1 | **解決** | 0 |
| 残高検査と reserve のねじれ | -1 | **未解決** | -1 |
| `getexecutions` のページングなし | -1 | **解決** | 0 |
| ticker 一本（板・約定なし、spread ゲートなし） | -1 | **未解決** | -1 |
| `websockex` 0.4 依存（記録も移行もなし） | -1 | **未解決** | -1 |
| 永続データの保持・剪定方針なし | -1 | **未解決** | -1 |
| `precommit` に `ash.codegen --check` なし | -1 | **未解決** | -1 |
| 開発 Dockerfile が root | -1 | **未解決** | -1 |
| `test_helper.exs` に Sandbox mode なし | -1 | **未解決** | -1 |
| `apps/bitflyer/README.md` が TODO テンプレ | -1 | **未解決** | -1 |

**解決 6 件（-11 点分を解消）/ 部分解決 1 件 / 未解決 6 件（-6 点分が残存）。**

前回 live ブロッカーに指定した 3 件（残高 tip 不前進 -4、spot 建玉未照合 -2、HWM 非永続 -2）のうち、上 2 件はコード上で完全に閉じた。HWM は骨格が入り、残差は「周期間のピーク flush」という細い経路に縮んだ。

未解決 6 件のうち 5 件（`ash.codegen --check`、開発 Dockerfile root、Sandbox mode、`websockex`、保持方針）は **5 サイクル連続で残置**。いずれも 1〜2 行で終わる。

### 今回の新規マイナス点

| 指摘 | 点 | 性質 |
|:---|:---:|:---|
| 認可ホットパスで上がった HWM が永続化されず、再起動で drawdown 基準が緩む | -2 | P1 #3 の残差 |
| 突合窓に入った約定が「取引所が内部より先」の向きだけ再同期されず即 halt する | -2 | P0 #1 の境界条件（安全側だが誤検知） |
| `DailyEquityPeak` の一意制約衝突検出が `inspect(error)` の文字列一致依存 | -1 | 実装細部の脆さ |
| improvement-plan P3 #15「毎サイクル 3 件必ず消す」が 0 件 | -1 | プロセス |

---

## 実行検証結果

Windows PowerShell / Docker 経由で実行。実 bitFlyer private API・実 live 発注・本番長時間稼働は行っていない。

| コマンド | 結果 | 詳細 |
|:---|:---:|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功** | `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `test --warnings-as-errors` すべて通過 |
| `docker compose config --quiet` | **成功** | exit 0（警告なし） |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功** | exit 0（警告なし） |
| `docker compose run --rm app mix deps.audit` | **成功** | `No vulnerabilities found.` |

### テスト結果の詳細

```
==> bitflyer
Finished in 6.0 seconds (3.1s async, 2.9s sync)
1 doctest, 599 tests, 0 failures

==> ui
Finished in 0.5 seconds (0.1s async, 0.3s sync)
38 tests, 0 failures
```

**合計 637 テスト（+ 1 doctest）、0 failures、警告ゼロ。** 前回の 521 件から 116 件増（+22%）。増分の中心は `regression/live_balance_advance_test.exs`（432 行）、`open_order_policy_test.exs`（598 行）、`live_inventory_test.exs`、`live_balance_test.exs`、`daily_equity_peak` 関連である。P0–P2 の実装がテストを伴っていることは実行結果で確認できた。

ホスト側 `mix precommit` へのフォールバックは不要だった（Docker 経路がすべて成功したため）。

---

## live 解禁の可否

### 判定: **段階的 live（Stage 3 = 最小ロット単発・人が張り付く）は可。連続稼働（Stage 4 以降）は不可。**

#### 可とする根拠

- **P0 が 2 件とも解決している。** 前回「これが閉じない限り live 不可」と断じた残高正本の前進（`LiveBalance`）と縦貫通回帰（`LiveExchangeHarness` + 回帰テスト）は、コードを読んだ限り宣言どおり実装されている。とくに「発注 → 約定 → 突合 → tip 前進 → 再起動 → 再突合で変化なし」を実経路で通す回帰があることが大きい。これは「live の残高が説明できる」ことを機械が保証する最初の一本である。
- **live 特有の安全弁が揃った。** `LiveSafety` が live でリスク上限 6 種と `BITFLYER_MAX_OPEN_AGE_MS` を必須化、`runtime.exs` が `BITFLYER_LIVE_CONFIRM` の日付一致を要求、`getpermissions` で出金権限を検査、`FixedOnce` 戦略は live で拒否、未約定は期限で自動 cancel。どれも「うっかり live」を機械で止める。
- **止まり方が安全側に統一されている。** 突合の全 mismatch、リスク ETS の `unsynced`、Feed 切断、ページング上限到達のいずれも fail-closed（発注拒否 / halt）で、復帰には人の Resume を要求する。資金を減らす方向に倒れる経路を探したが、見つからなかった。
- **手数料が会計に入った。** live の実現損益が手数料込みになり、残高突合も手数料ぶんの目減りを非対称に許容する。これが無い状態で live に出すと「毎回わずかに説明できない」ことになり、突合が実質無意味になる。P1 #4 は実質的に P0 相当だった。

#### 連続稼働を不可とする根拠

1. **HWM の周期間 flush 欠落（weaknesses -2）。** 認可ホットパスで ETS に上がったピークが DB へ流れない経路がある。`max_daily_drawdown` は「本番 PC の予期しない再起動」（vision.md L119-122）という現実的なシナリオで基準が緩む。**資金保全の最後のブレーキが再起動で効かなくなる可能性がある**ため、これを抱えたまま無人連続稼働に入るのは Vision の優先順位に反する。1 列追加 + 3 値化で閉じる規模なので、次サイクルで塞ぐべき最優先項目とする。
2. **突合窓の非対称による誤検知 halt（weaknesses -2）。** 「取引所が内部より先」の向きだけ再同期が無く、`balance_mismatch` で即 halt する。窓は数百 ms と狭いが、周期突合は 60 秒ごとに永久に回る。`reconcile_mismatch` は `cancel_on_halt: false` なので未約定が板に残り、復帰には人の操作が必要。**「人が張り付かなくても回る」が成立しない**。安全側の停止なので資金は減らないが、24/365 要件を満たさない。
3. **同一ホスト死を誰も検知できない（weaknesses -1）。** `watch-ready.ps1` は実装され動作記録もあるが、常駐は取引ホストと同一 PC 上の手動実行に留まる。ホストごと落ちたとき（Windows Update、WSL2 ハング）に気付く手段が無い。無人運転の前提が欠けている。

#### 推奨する解禁手順

| 段階 | 条件 | 可否 |
|:---|:---|:---:|
| Stage 3a: live 最小ロット 1 発、人が画面を見ている、直後に手動突合 | 現状で可 | **可** |
| Stage 3b: live 最小ロットを数回、当日中に停止、日次で残高突合 | 現状で可 | **可** |
| Stage 4: live で戦略を数時間連続稼働 | 上記 2（突合窓の対称化）を塞ぐ | 不可 |
| Stage 5: live 無人連続稼働 | 上記 1・2・3 すべてを塞ぐ | 不可 |

Stage 3 を許可する理由は、「単発 + 直後の手動突合」であれば HWM flush 欠落も突合窓の誤検知も人が吸収できるためである。逆に言えば、**Stage 3 で得られる情報（実約定の手数料の実値、`getbalance` の反映遅延の実測、`getexecutions` の実レスポンス）は机上では得られない**ので、ここを飛ばす理由も無い。Stage 3 の実測値が無いまま Stage 4 の設計を詰めるほうが危険である。

---

## 観点別小計

| 評価観点 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| **apps/bitflyer — market-data** | +20 | -2 | +18 |
| **apps/bitflyer — strategy** | +9 | 0 | +9 |
| **apps/bitflyer — risk-manager** | +32 | -4 | +28 |
| **apps/bitflyer — order-executor** | +28 | 0 | +28 |
| **apps/bitflyer — 起動・突合（live の意味論）** | ※ risk / order-executor に分散計上 | -2 | -2 |
| **apps/bitflyer — datastore / Ash** | +17 | -1 | +16 |
| **apps/bitflyer — cache / ETS** | +8 | 0 | +8 |
| **apps/bitflyer — observe** | +18 | 0 | +18 |
| **apps/bitflyer — OTP / Application** | +17 | 0 | +17 |
| **apps/ui（Phoenix/LiveView・運用操作性）** | +19 | 0 | +19 |
| **実行基盤（Docker / config / CI/CD）** | +28 | -2 | +26 |
| **横断 — テスト戦略** | +15 | -1 | +14 |
| **横断 — 可観測性・エラーハンドリング・プロセス** | +20 | -3 | +17 |
| **合計** | **+231** | **-15** | **+216** |

### 観点別の所見

- **risk-manager（+28）** — 最も点が集まった層。認可の検査列が 10 段以上に整理され、`market_feed_gate`、`check_spot_sell_cover`、`check_live_open_age` が今サイクルで追加された。すべての risk ETS が `unsynced` で fail-closed に倒れ、`OrderRate` の枠取りが原子的で、テスト注入経路が本番設定でゲートされている。減点 -4 はすべて「正しい骨格に残った境界条件」であって設計方針の誤りではない。
- **order-executor（+28）** — 冪等な submit、出口 1 点での `TRADE_MODE` 分岐、execution 単位の Fill 記録、`ensure_execution_coverage` による取りこぼし検出、`submission_unknown` という「分からない」状態の明示。減点ゼロ。個人プロジェクトでこの水準の発注経路は見たことがない。
- **起動・突合（-2）** — 加点ぶんは `LiveBalance` / `LiveInventory` / `Baseline` として risk・datastore 側に計上した。純粋な減点として残るのが突合窓の非対称である。
- **実行基盤（+26）** — CI/CD は SHA ピン留め、CI 成功を CD のゲートに、`deps.audit` の分離、Docker イメージのビルド検証まで含めてプロダクション級。`Dockerfile.prod` の非 root 化・`--chown` も含めて完成度が高い。減点は開発 Dockerfile の root（-1）と `ash.codegen --check` の欠落（-1）で、どちらも 1 行。
- **横断 — テスト戦略（+14）** — 637 件・0 failures・警告ゼロ。`LiveExchangeHarness` で「実経路にダブルを差す」形が確立され、live の意味論が回帰で守られるようになった。減点は Sandbox mode 1 行の欠落のみ。
- **横断 — プロセス（-1 を含む）** — 自己改善サイクルそのものは機能している（P0–P2 を 11 件完走、8884 行追加）。一方で自分が「必ず」と書いた P3 #15 が 0 件。計画の宣言と実行の整合に穴がある。

---

## 忌憚ない総括

### 1 サイクルで何が変わったか

前回、私はこのプロジェクトを「設計思想は個人プロジェクトの水準を明らかに超えているが、live の残高が説明できないので live 不可」と評価した。その 1 点が今サイクルで閉じた。

`LiveBalance.explain/4` は、内部の残高 tip に Fill デルタと手数料許容を足して取引所 `getbalance` を「説明する」関数である。説明できれば tip を前進させ、できなければ halt する。これが正しい設計であることは、書いてみれば当たり前に見える。しかし前回の実装は「固定 baseline との厳密一致」で、約定が 1 件でも入れば永久に一致しなくなる構造だった。方針を変えるのではなく、**残高という概念の扱い方そのものを作り直した**のが今サイクルの本質的な成果である。

そしてそれを `LiveExchangeHarness` + `live_balance_advance_test.exs` で縦に貫いて検証している。発注 → 約定 → 突合 → tip 前進 → 再起動 → 再突合（変化なし）。手数料あり／なし、部分約定、入金混入で halt するところまで。**回帰テストが「live の意味論」を守る番人になった**ので、今後この層を触っても静かに壊れない。この 2 件（P0 #1 / #2）が今回の加点 +28 のうち最も重い部分である。

P1 #4 の手数料も見逃せない。手数料が会計に入っていないまま live に出ると、約定ごとにわずかな説明不能差分が積もり、突合が「常に少し合わない」状態になって実質無意味になる。これは P1 に置かれていたが、実質 P0 だった。`LiveBalance.fee_explained?/2` が quote / base で非対称に許容幅を持ち、「手数料ぶん目減りする方向だけ許して、増える方向（= 入金・誤記帳）は拒否する」形になっているのは、金額の符号の意味を理解して書かれている。

### いま残っている本当の問題

残り 4 件の新規マイナスのうち、性質が違うのは 2 件である。

**HWM の周期間 flush 欠落（-2）** は、P1 #3 を「完了」と宣言したことの問題である。`DailyEquityPeak` Resource、単調増加の条件付き更新、並行 upsert の衝突処理、init/reload/reinit からの復元、どれも正しい。にもかかわらず、認可ホットパスで ETS だけに上がったピークを DB へ流す経路が無いので、「周期 enforce のあいだに伸びて、その後下がったピーク」は永久に DB に載らない。再起動すると drawdown 基準が緩む。

これは実装の抜けというより、**完了条件の書き方の問題**である。improvement-plan の完了条件は「実現益後の含み損状態で再起動・突合 reload しても drawdown が消えない」だった。この文は「周期 enforce が書いた値からの再起動」なら満たす。しかし「認可が上げたピークからの再起動」では満たさない。テスト（`risk_test.exs` L259 の `authorize raises HWM in ETS without persisting`）は後者の挙動を**意図として固定**している。つまり実装者はこの挙動を認識していて、それでも完了と判断した。完了条件が現実のシナリオを網羅していなかった、ということである。

**突合窓の非対称（-2）** は、P0 #1 を作った副産物である。内部 Fill が先行するケース（`balance_exchange_lag`）には 1 回だけ `getbalance` を再取得する救済があるのに、逆向き（取引所が先行）には無い。窓は数百 ms と狭いが、60 秒周期で永久に回るので、live で戦略が動いていれば遠からず踏む。止まり方は安全側だが、止まると人の Resume が要る。**「人が張り付かなくても回し続ける」という Vision の中心要件に対する構造的な誤検知**なので、連続稼働の前に閉じる必要がある。処方は単純で、対称の救済を 1 段入れるか、`getbalance` の取得順を fill 同期の前に移して向きを片側に固定するだけである。

残り 2 件（`inspect(error)` 依存 -1、残高検査と reserve のねじれ -1）は実装細部で、どちらも「fail-closed なので資金は減らないが、止まる理由が分かりにくい」種類である。

### 5 サイクル残置の 5 件について

`ash.codegen --check` 1 行、Dockerfile の `USER` 1 行、Sandbox mode 1 行、`websockex` の記録 1 行、`apps/bitflyer/README.md` 10 行。合計 -5 点。前回もその前も同じことを書いた。

今サイクルで improvement-plan は P3 #15 に「**毎サイクル 3 件まで必ず消す**」と自ら書いた。消えたのは 0 件である。一方で P0 2 件・P1 4 件・P2 5 件は完走し、8884 行を追加した。**実行力の問題ではない。優先度づけの構造の問題である。** 「重要な項目を先に」という判断は個々には正しいが、その判断を毎サイクル繰り返すと 1 行の項目は永久に選ばれない。しかも今サイクルは `DailyEquityPeak` の新設と `Fill.fee` の追加という**まさに `ash.codegen --check` が守るべき変更**を 2 本入れており、整合していたのは人が気を付けた結果である。

この構造を壊すには、優先度で選ばないようにするしかない。P0 のブランチに 1 件、P1 に 1 件、P2 に 1 件を相乗りさせる。どれも 1〜2 行なのでレビュー負荷は増えない。それができないなら、P3 #15 から「必ず」を消すべきである。守られない宣言が計画に残ると、次に「P0 は必ず塞ぐ」と書いたときの信頼度も落ちる。計画文書の価値は、書かれた内容が実行されるという期待の上にしか成り立たない。

### このプロジェクトの現在地

純点 +216。前回 +185 から +31。加点 231 点の内訳を見ると、`+4`（プロダクション級）以上が 20 項目以上ある。とくに以下は個人プロジェクトの範疇を超えている。

- `Application.prep_stop` が `submission_unknown` の発注を抱えたまま落ちないよう子プロセスの停止に予算を持たせている（+5）
- CI が SHA ピン留め・CI 成功ゲート・`deps.audit` 分離・Docker ビルド検証まで揃っている（+5）
- 発注の冪等キー設計と `submission_unknown` という「分からない」状態の明示（+4 × 複数）
- `Feed` が `:persistent_term` のスナップショットに pid を含め、死んだ Feed を connected と誤読しない（+4）
- `LiveExchangeHarness` による縦貫通回帰（+5）

Vision の 3 本柱で言えば、**資金保全**は「fail-closed の徹底」という点で極めて強い。探しても資金を減らす方向に倒れる経路が見つからない。**復帰**は P0 #1 で決定的に前進した。ETS を全部捨てて再起動しても DB から状態を組み直せる。残る穴は HWM の周期間 flush だけである。**観測可能性**は「いまの状態」（Status UI / `/health/ready` / LiveDashboard）と「起きたこと」（構造化ログ / Discord）が揃っている一方、**率と推移がホスト外に残らない**のと、**ホストごと死んだときに誰も気付かない**のが穴である。前者は提案（Prometheus + SLO）、後者は減点（-1）に振り分けた。

次サイクルの優先順位は明確である。(1) HWM の flush 経路（1 列 + 3 値化）、(2) 突合窓の対称化（救済 1 段または取得順の入れ替え）、(3) 別ホスト常駐の実配備、(4) 5 サイクル残置の 5 件。**(1) と (2) が閉じれば live 連続稼働の技術的障害は無くなる**。(3) が閉じれば無人運転に入れる。どれも規模は小さい。

最後に、このプロジェクトの最大の強みは個々の実装ではなく、**自己改善サイクルが実際に回っていること**だと考えている。前回の指摘 13 件のうち 6 件が 1 サイクルで閉じ、その 6 件は「指摘が正しかったから閉じた」だけでなく「閉じたことが回帰テストで固定された」。Game Day の記録が閉じなかった項目を正直に残しているのも同じ性質である。**評価を受け入れて実装に変換する能力が、コードそのものより価値が高い。** 残置 5 件への対処も、その能力が「1 行の項目」にも及ぶかどうかの試験だと受け取ってほしい。
