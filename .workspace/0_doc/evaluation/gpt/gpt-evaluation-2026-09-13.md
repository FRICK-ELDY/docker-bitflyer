# docker-bitflyer 第2評価者 総合評価レポート（2026-09-13）

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-13 |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 対象コミット | `cfaf0a526ca94c176997aa176ca30edd69bae307` — Merge pull request #103 |
| 前回起点 | `1cfb413858a6d55aee8423e82cdafa3084b18f31` |
| 基準の正本 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 前回自系統 | [gpt-evaluation-2026-09-12.md](./archive/2026-09-12/gpt-evaluation-2026-09-12.md) |
| 詳細 | [強み](./gpt-specific-strengths-2026-09-13.md) / [弱み](./gpt-specific-weaknesses-2026-09-13.md) / [提案](./gpt-specific-proposals-2026-09-13.md) |

**`.workspace/0_doc/evaluation/opus/` 配下（archive を含む）および Opus の当日文書は参照していない。** 現行コード、テスト、設定、許可された設計文書、自系統前回 archive を直接確認した。

## 総合スコア

| 区分 | 加点 | 減点 | 純点 | 提案数 |
|:---|---:|---:|---:|---:|
| 今回 | **+104** | **-13** | **+91** | **8** |
| 前回 GPT（2026-09-12） | +84 | -19 | +65 | 7 |
| 前回比 | **+20** | **6点改善** | **+26** | +1 |

P0/P1/P2 の実装量と安全側制御は大きく前進した。Feed ACK、Feed 認可、有限 open age、HWM DB 行、execution ページングは宣言どおりである。一方、最重要の live 手数料は単位を取り違えている。コードとハーネスは `commission` を JPY としているが、BTC_JPY の bitFlyer 手数料は BTC 単位である。このため非ゼロ手数料の実約定では BTC 残高と内部 Position がずれ、P0 の残高前進回帰は現実の意味論を証明しない。

## improvement-plan P0–P2 判定

| 優先 | # | 項目 | 判定 | 現行コードによる判断 |
|:---:|:---:|:---|:---:|:---|
| P0 | 1 | live 残高正本の前進 | **部分解決** | explain→advisory lock→append は実装。ただし `commission` を quote に入れ、BTC base fee を説明できない |
| P0 | 2 | 縦貫通回帰 | **部分解決** | 発注→部分約定2回→周期突合→ETS再初期化→Ready は通る。ただしハーネスも fee を JPY から引くため実取引所と同じではない |
| P1 | 3 | HWM 永続化 | **解決** | `DailyEquityPeak` 一意行、単調条件更新、init/reload/reinit、失敗 unsynced を確認 |
| P1 | 4 | live 手数料 | **未解決** | fee 列と net 計算は追加されたが通貨単位が誤り。BTC_JPY commission を JPY と扱う |
| P1 | 5 | spot 在庫突合 | **部分解決** | 認可・突合の不変条件自体は実装。実 BTC fee を Position/base amount に反映しないため fee-bearing 約定後に偽 mismatch |
| P1 | 6 | 認可に Feed 接続 | **解決** | `market_feed_gate` と PID 一致付き `connection_snapshot` を認可前に使用 |
| P2 | 7 | 購読 ACK | **解決** | request id、`result:true`、error/false/timeout 再接続、全 ACK 後 connected |
| P2 | 8 | live 未約定期限 | **解決** | live で有限・7日以下必須、boot/run_now/周期 cancel、終端確認まで hold 維持 |
| P2 | 9 | executions ページング | **解決** | `before`、500件上限、最終満杯の追加確認、超過 fail-closed |
| P2 | 10 | 別ホスト監視の実配備 | **部分解決** | PowerShell 探針と失敗証跡はあるが、同じ物理ホスト上の開発ドリル。VLAN1 向け task は未登録 |
| P2 | 11 | Game Day Stage 2 | **部分解決** | Feed断・halt・resume は実施。建玉は SQL、認可拒否は ready で代替、Discord 未確認 |

集計は **解決 5 / 部分解決 5 / 未解決 1**。改善計画の「実装」記述はファイル存在としては概ね正しいが、P1 #4 の「口座残高と内部 equity が一致」は過大宣言である。P0 #1/#2 も fee-bearing 実約定には成立しない。

## 自系統前回マイナス点の再判定

| 前回指摘 | 前回点 | 判定 | 根拠・残差 |
|:---|---:|:---:|:---|
| live 残高 tip 不前進 | -5 | **部分解決** | ゼロ手数料なら append と再起動復帰が成立。実 BTC fee は説明不能 |
| live 手数料未計上 | -3 | **未解決** | fee 列はあるが BTC を JPY として控除し、損失額・残高とも誤る |
| Feed 切断直後も Risk 認可 | -2 | **解決** | `market_feed_gate` を鮮度前に接続 |
| 購読 ACK なし | -2 | **解決** | request id と timeout、全 ACK 条件を実装 |
| 未約定期限 infinity | -2 | **解決** | live は有限値必須、無効時は認可拒否＋全 open 取消 |
| 外部監視は手順まで | -2 | **部分解決** | 探針実行証跡は追加。本番別ホスト常駐は未 |
| Game Day は Stage 0 のみ | -2 | **部分解決** | Stage 1/2 の一部を実施したが Executor/認可/Discord は未貫通 |
| Hex 以外の脆弱性はゲート外 | -1 | **未解決** | GitHub tag/lock/container OS scanner なし |

前回 8 件は **解決 3 / 部分解決 3 / 未解決 2**。

## live 会計の縦検証

現行コード上の流れは次である。

1. `LiveFills` が execution ごとの `commission` を `Positions.apply_fill/3` へ渡す（`live_fills.ex:460-489`）。
2. `Positions` は `realized_pnl = gross - fee` とし、Position size は execution size 全量で増やす（`positions.ex:32-168`）。
3. `LiveBalance` は買いで JPY を `price*size + fee` 減らし、BTC を size 増やす（`live_balance.ex:260-286`）。
4. ハーネスも JPY amount から commission を引き、BTC は size 全量増やす（`live_exchange_harness.ex:192-224`）。
5. そのため回帰は緑になるが、bitFlyer 公式の BTC 手数料単位（BTC）とは一致しない。

現実には BTC amount が fee 分だけ内部 expected/Position より少なくなる。通常の 0.01%〜0.15% は BTC 絶対床 1 sat を超えるため、安全側には halt するが、一約定後の継続運転・再起動復帰は成立しない。これは前回の「tip が全く進まない」欠陥から改善したものの、live 解禁条件を満たす解決ではない。

## 実行検証

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**。bitflyer: 1 doctest + 599 tests、ui: 38 tests、計 637 tests、0 failures |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功** |
| `docker compose run --rm app mix deps.audit` | **成功**。`No vulnerabilities found.`（Hex advisory のみ） |

実行しなかったもの: 実 bitFlyer live 発注・取消、実 fee-bearing execution、長時間 soak、VLAN1 本番向け監視 task 登録、隔離 DB restore。禁止事項に従い private API と実発注は実行していない。

precommit の warning/critical ログは故障注入ケースであり、終了コード 0。`halt_trading` の RiskState persist failure を意図的に発生させる runtime warning が 1 件あった。

## 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| market-data | +8 | 0 | +8 |
| strategy | +6 | 0 | +6 |
| risk-manager | +21 | -6 | +15 |
| order-executor / recovery | +24 | 0 | +24 |
| datastore / cache / OTP | +8 | -1 | +7 |
| observe | +7 | -2 | +5 |
| apps/ui / 運用操作性 | +5 | 0 | +5 |
| Docker / config | +7 | -1 | +6 |
| CI / CD / security | +7 | -1 | +6 |
| テスト / 文書 / 取引完成度 / 全体設計 | +11 | -2 | +9 |
| **合計** | **+104** | **-13** | **+91** |

## live 解禁の可否

**不可。**

P0 #1/#2 は fee-bearing 実約定に対して部分解決であり、P1 #4 は未解決である。安全側に halt するため直ちに二重発注する欠陥ではないが、「一度の実約定後も残高を説明して Ready を維持し、再起動後に復帰する」という P0 完了条件を満たさない。

最低限の解除条件:

1. BTC_JPY の `commission` を BTC 単位として base amount・Position・JPY換算損益へ一貫して反映する。
2. ハーネスを実 fee 単位に直し、非ゼロ fee の買い・売り・部分約定・周期突合・再起動を通す。
3. 実 API の fee-bearing response 形を、秘密を残さない contract/Game Day で確認する。
4. P0 回帰に「誤った fee 通貨なら必ず失敗する」反証ケースを加える。

observe-only live、署名 GET、paper Game Day の完遂は継続可能だが、Stage 3 の実発注へ進んではならない。

## 忌憚ない総括

今回の改善は、単なるファイル追加ではない。購読 ACK、Feed 直結認可、有限 open age、HWM 永続行、execution ページング、残高 tip の transaction append は相互接続され、637 tests が緑である。資金保全の「止める部品」と並行競合への配慮は、個人プロジェクトの水準を明確に超えている。

しかし最重要の縦回帰は、ハーネスまで同じ誤った fee 単位を採用したため緑になっている。これは「部品が揃った」と「取引所の事実に対して系が回る」を混同した典型例である。スコアは前回より上がるが、live 判定は変わらない。次に直すべきは新機能ではなく、commission の通貨・残高・Position・equity を一つの実取引所準拠会計へ閉じることである。
