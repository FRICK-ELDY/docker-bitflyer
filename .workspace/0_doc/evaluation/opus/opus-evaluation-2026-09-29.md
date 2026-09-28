# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-29

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-29 |
| 種別 | **同日の上書き再評価**（同日の朝に書いた自系統の下書きを、P1 #3 の実装と P1 #5 の完了宣言の後で採点し直した。新しい日付のファイルは作らない） |
| 評価者 | 第1評価者（Claude Opus 5） |
| 基準ドキュメント | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [.cursor/rules/evaluation.mdc](../../../../.cursor/rules/evaluation.mdc) |
| 対象コミット | `80c486f`（`docs: 作業PCの ready 常駐で監視条件を閉じ、解除手順を残す`） |
| 詳細 | [strengths](./opus-specific-strengths-2026-09-29.md) / [weaknesses](./opus-specific-weaknesses-2026-09-29.md) / [proposals](./opus-specific-proposals-2026-09-29.md) |
| 前回（自系統） | [opus/archive/2026-09-16](./archive/2026-09-16/opus-evaluation-2026-09-16.md) |

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。すべての判定は当該コードの再読に基づく。
行番号は本サイクルで実際に読んだ箇所だけを記した。
`mix precommit` は**本再評価では未再実行**。親が P1 #3 実装後に実行して成功（bitflyer doctest 1 + テスト 668、ui 38、失敗 0）を確認済みという情報は受け取っているが、本評価者は再実行していない。したがって本評価にテスト結果へ依拠した判定は含めない。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
| 加点合計 | **+54** |
| 減点合計 | **-8** |
| **純点** | **+46** |

現状システム全体の積み上げである（差分採点ではない）。同日の朝の下書きは +52 / -9 = +43 だった。

上書きの理由は 2 件の状態変化である。

1. **P1 #3（HWM 認可後の crash 窓）が実装で閉じた。** `PeakWriter.enqueue/4` が非 suspend で DB upsert 成功と ack まで待って `:ok` を返すようになった。下書きの `-1`（残差）を消し、加点を `+4` → `+5` に上げた。
2. **P1 #5（別ホスト監視）の「完了の見方」が所有者によって書き換えられ、完了が宣言された。** 書き換え後の見方はスクリプトと証跡で満たされているので完了を採用し、下書きの `-2`（専用監視PCの欠如）を消した。常駐と解除手順に `+1`。ただし証跡文書が自分の冒頭の完了条件と矛盾したままなので、そこに `-1` を新規計上した。

あわせて、認可経路が同期 DB 往復になったのに `risk.ex` の moduledoc が「往復しない / cast する」と述べたままである点を `-1` として新規に計上した。

### 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| apps/bitflyer — order-executor / 手数料会計 | +8 | -1 | **+7** |
| apps/bitflyer — risk-manager / HWM | +14 | -2 | **+12** |
| apps/bitflyer — market-data | +3 | 0 | **+3** |
| apps/bitflyer — strategy | 0 | -1 | **-1** |
| apps/bitflyer — 診断タスク / 運用 | +4 | 0 | **+4** |
| apps/bitflyer — datastore / Ash | +3 | 0 | **+3** |
| apps/bitflyer — 可観測性（RiskState） | 0 | -1 | **-1** |
| 実行基盤 / 設定 | +7 | -1 | **+6** |
| CI / CD | +3 | 0 | **+3** |
| 横断（テスト戦略） | +6 | 0 | **+6** |
| 横断（可観測性） | +4 | 0 | **+4** |
| 横断（変更容易性・保守性） | 0 | -1 | **-1** |
| 横断（プロジェクト全体設計・プロセス） | +2 | -1 | **+1** |
| **合計** | **+54** | **-8** | **+46** |

項目合計（加点 +54 / 減点 -8）と総合スコア +46 は一致する。同じ設計を 2 つの観点で数えていないことを確認した（`PeakWriter` の耐久経路は risk-manager / HWM の 1 件、`DrainHalt` の fsync 印は同観点の別件、`GREATEST` upsert は SQL 仲裁の別件として、根拠の重複が無いように分けている）。

---

## P1 #3 の採否

**採用（完了）。**

| 項目 | 内容 |
|:---|:---|
| 完了の見方 | 認可が返った時点で、上がった当日高値が DB にある（プロセスが強制終了しても戻らない） |
| 再読で確認した観測 | `peak_writer.ex` L163-175 が非 suspend 節で `persist_attempt/5`（upsert + ack）を**返答より前に**実行し、成功時だけ `{:reply, :ok}`。失敗は `{:reply, {:error, :unsynced}}`。`enqueue/4` の doc（L43-44）も同じ契約。`daily_loss.ex` L393-403 が 5 秒タイムアウトの `call` で待ち、`risk.ex` L660-671 → L690-691 が `:unsynced` を発注拒否へ変換する |
| テスト | `peak_writer_test.exs` L139-157 `write-behind success leaves the DB peak after both processes are discarded`。`:ok` の直後に `pending_count() == 0` を確認し、`Process.exit(pid, :kill)` → `DailyLoss.reinit()` で peak 160000 の復元を assert。失敗側も `:ok` 期待から `{:error, :unsynced}` 期待へ書き換わっている |
| 判定 | 下書きで `-1` としていた「認可後の強制終了で高値が戻る」窓は**存在しない**。減点を削除し、strengths を `+5` に引き上げた |

代償は明示されている（新高値ごとに DB 1 往復、失敗・5 秒超は発注拒否）。**この代償を選んだこと自体は Safety first に沿うので加点対象とした**が、`risk.ex` の moduledoc が旧設計の記述（「ホットパスでは DB 往復しない」「`PeakWriter` へ cast する」）のまま残っているため、そこだけ `-1` とした。

## P1 #5 の採否

**採用（完了）。ただし証跡文書の矛盾に `-1`。**

| 項目 | 内容 |
|:---|:---|
| 書き換え後の完了の見方 | 作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残り、解除手順がある |
| 証拠（常駐） | `watch-ready-evidence.md` L97-108。監視ホスト `FRICK`、タスク `BitflyerWatchReady` の State は Running |
| 証拠（探針の失敗） | 同 L107。`%LOCALAPPDATA%\bitflyer\watch-ready.log` に `2026-09-28T17:28:41Z result=fail http=000` と `…17:29:43Z result=fail http=000` |
| 証拠（登録） | `bin/register-watch-ready-task.ps1` L19-41（`READY_URL` を含む wrapper は `%LOCALAPPDATA%` に置きリポジトリには残さない）、L43-54（`-AtLogOn`、`RestartCount 3`、`Register-ScheduledTask -TaskName "BitflyerWatchReady"`） |
| 証拠（解除） | `bin/unregister-watch-ready-task.ps1` L18-32（停止 → `Unregister-ScheduledTask` → `READY_URL` 入り wrapper を削除、証跡ログは残す）。`prod.md` L150 と証跡 L73-79 にも手順がある |
| 判定 | 見方を満たす証拠は文書とスクリプトの両方にある。**専用監視PCの不在は減点しない。** |
| 残した減点 | 証跡文書 L6-7 が「同一ホストの Compose healthcheck や localhost cron では閉じない」と書いたまま、L97-105 が `127.0.0.1:4000` の常駐で完了を宣言している。**同一ファイル内で 2 つの基準が同居**しており、次サイクルの再検証を壊すので `-1`（weaknesses / 横断・プロセス） |

矛盾の所在は「見方 ↔ 根拠」ではなく「証跡文書の冒頭 ↔ 証跡文書の末尾」である。improvement-plan 側の見方は書き換え済みで根拠と整合するため、**完了そのものは却下しない**。文書の 2 行を移せば閉じる。

---

## 主要な減点（8 件 / -8 点）

| 指摘 | 点数 | 根拠 |
|:---|:---:|:---|
| 認可が DB 往復するのに `Risk` の moduledoc と overview が「往復しない」のまま | -1 | `risk.ex` L27, L30-31 / `peak_writer.ex` L163-175 / overview L97 |
| `PeakWriter` の再試行が 50ms 固定で、DB 障害中に毎秒 20 本の `:error` ログ | -1 | `peak_writer.ex` L26, L242-245 / `daily_loss.ex` L751-755 |
| 一次証跡は `BTC_JPY` だけなのに live 認可は spot allowlist 8 銘柄を通す | -1 | `product.ex` L12-21, L108-119 / `risk.ex` L262 / `live_safety.ex` L60-72 |
| 戦略が `FixedOnce` 1 本で、live で有効化できる戦略がゼロ | -1 | `strategy/` 3 ファイル / `live_safety.ex` L93-98 |
| `halted_at` が周期突合のたびに上書きされ、最初の停止時刻が残らない | -1 | `reconciler.ex` L390-398, L411-414（成功側 L380-383 は正しく触らない） |
| 開発 `Dockerfile` が root で実行される | -1 | `Dockerfile` L1-20 に `USER` なし / `Dockerfile.prod` L61-67 は非 root |
| `watch-ready-evidence.md` が自分の完了条件と矛盾したまま完了を宣言 | -1 | 証跡 L6-7 と L97-105 |
| `websockex` 依存の記録が `architecture/` に無く、制約と lock がずれたまま | -1 | `mix.exs` L38（`~> 0.4`）/ `mix.lock` L56（0.5.1） |

**8 件すべて fail-closed 側で、資金を直接失う経路は本サイクルでも見つからなかった。**

新規 2 件（`risk.ex` の記述、証跡文書の矛盾）は同じ形をしている。**コードと運用が 1 歩進み、その正本の記述が追いついていない。**

---

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `mix precommit` | **本評価者は未再実行**（本再評価では実行していない。親が #3 実装後に成功を確認済みという情報のみ受領） |
| `docker compose ...` | **未実行** |
| `git log` / `git diff --stat` | 実行。`afc46bb..80c486f` で 33 ファイル・+1946 / -108 行。うちコード変更は `daily_loss.ex` / `equity.ex` / `peak_writer.ex` / `peak_writer_test.exs` / `bin/*.ps1` |

静的に確認した品質ゲート:

- `mix.exs` L47-54 の `precommit` は `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `ash.codegen --check --domains Bitflyer.Trading` / `test --warnings-as-errors` の 5 本。`preferred_envs: [precommit: :test]`（L27）
- `.github/workflows/ci.yml` L18, L72 が同じ `mix precommit` を 1 ステップで実行
- `deps-audit` は別ジョブで、`bin/classify-deps-audit.sh`（ci.yml L120）が advisory 検出とツール障害を分ける
- `docker-prod` ジョブが `Dockerfile.prod` を push なしでビルド（ci.yml L134-150）

テスト規模は静的に数えて **706 件**（`apps/bitflyer/test` + `apps/ui/test` の `test` / `property` 宣言）。本サイクルで +1（`peak_writer_test.exs` の強制終了テスト）。

未実行のまま残るもの: 実 bitFlyer private の再往復、VLAN1 本番 PC を対象にした監視常駐、隔離 restore、`Dockerfile.prod` フルビルド、本番長時間稼働。

---

## 現状の一文

**資金会計は実口座の実測に乗り、ドローダウンの基準点は認可が返る前に DB へ落ちきるようになった。残る弱点はすべて「コードが正しくなったのに、その正本の記述と適用範囲が追いついていない」種類であり、資金を直接失う経路ではない。**

通っている経路は「WS ACK → Feed ゲート → Strategy（live 既定オフ）→ Risk（DailyLoss / BalanceCache probe / Equity / spot 在庫 / spread / ask 拘束 / 有限 open age）→ AuthorizedOrder → モード別 executor → execution 単位 Fill（`fee_currency`）→ explain 成功時の tip append → halt / resume」。HWM の上昇だけは `PeakWriter` 経由で DB upsert 完了まで待ち、書けなければ発注しない。drain が失敗したときは fsync した印が次回起動を Ready にしない。

欠けているのは、取引ホストの**外**からの Ready 常駐監視（現在の常駐は同一ホストの開発 Compose 向き）、`BTC_JPY` 以外の spot に対する一次証跡、そして live で有効化できる戦略である。

---

## live 解禁可否

**不可。**

**資金保全の結論: 内部の会計・認可・停止・復帰はコード上で説明でき、実測で反証もされている。ドローダウン基準点の耐久性も今サイクルで閉じた。それでも実発注を解禁しない理由は 3 つある。**

1. **解禁しても動かせる戦略が無い。** `FixedOnce` は `LiveSafety` が live での有効化を拒否し（live_safety.ex L93-98）、他の戦略は存在しない。解禁の意味が「observe-only の live 接続」に留まる
2. **live 認可が一次証跡のない 7 銘柄を通す。** `MarketData.product_codes` を変えるだけで推定の会計モデルに戻る（product.ex L12-21, L108-119 / risk.ex L262）。live 対象を `BTC_JPY` に固定するか、evidence allowlist を入れる
3. **取引ホスト死の検知がまだ無い。** P1 #5 は書き換え後の見方で完了を採用したが、常駐の `READY_URL` は同一ホストの開発 Compose（証跡 L105）である。**これは減点していない**（見方の書き換えを尊重する）が、解禁条件としては別問題として残る。Vision L122 の「Windows Update による予期しない再起動」と overview L169 の「同一ホスト死の検知は取引ホストの外」に対して、現状は沈黙と正常を区別できない

解禁の最低条件:

1. live 対象を `BTC_JPY` に固定する（または evidence allowlist を入れる）
2. `READY_URL` を VLAN1 本番 PC へ向けた常駐を登録し、取引ホストを止めて alert が出た記録を証跡に残す
3. live で有効化できる薄い戦略 1 本（これが無いと解禁の実益が無い）

上記が閉じれば、残る `-1` 群（`PeakWriter` のログ増幅、`halted_at` 上書き、開発 Dockerfile root、`websockex` 記録、正本記述の遅れ）はいずれも**解禁後に直しても資金を失わない**種類である。

---

## 優先して直す順

1. **`risk.ex` の moduledoc と overview L97 を現在の設計に合わせる**（認可は HWM の upsert 完了まで待つ、という例外を明文化する。3 行。誤った前提での次の変更を防ぐ）
2. **live 認可を一次証跡のある銘柄に狭める**（`Product` の evidence allowlist。P0 #1 で作った規律を認可側へ引き継ぐ）
3. **`watch-ready-evidence.md` L6-7 を現在の見方へ書き換え、旧基準を「まだ閉じないこと」へ移す**（2 行。完了宣言の再検証可能性を戻す）
4. **`READY_URL` を VLAN1 本番 PC へ向けて常駐を張り直し、ホスト死検知を記録する**（減点ではないが live 解禁条件）
5. **`halted_at` を条件付き更新にする**（同一理由の再失敗では書き換えない。停止の起点を残す。5 行）
6. **`PeakWriter` の再試行を指数バックオフにし、`peak_persist_failed` のログを抑制する**（DB 障害中に原因行が埋まらないようにする。あわせて `:write_behind` を改名し、往復レイテンシを telemetry に出す）
7. **軽微 2 件を消す**（開発 `Dockerfile` の `USER`、`websockex` の記録または `~> 0.5` への更新）
8. **live で有効化できる薄い戦略 1 本**（解禁条件が揃ってから。判定段がダミーである限り縦経路は本物にならない）
