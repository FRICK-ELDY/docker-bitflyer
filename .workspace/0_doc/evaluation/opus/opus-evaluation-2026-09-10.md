# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-10

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10 |
| 評価者 | Claude Opus 5（第1評価者） |
| 種別 | 再評価（前回 2026-09-09） |
| 対象コミット | `490fb5a`（`Merge pull request #48 from FRICK-ELDY/chore/deps-audit-ci-p19`） |
| 基準 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 詳細 | [strengths](./opus-specific-strengths-2026-09-10.md) / [weaknesses](./opus-specific-weaknesses-2026-09-10.md) / [proposals](./opus-specific-proposals-2026-09-10.md) |
| 前回（自系統） | [opus/archive/2026-09-09](./archive/2026-09-09/opus-evaluation-2026-09-09.md) |
| 前回まとめ | [archive/2026-09-09/evaluation-2026-09-09.md](../archive/2026-09-09/evaluation-2026-09-09.md) |

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。判断はすべて対象ファイルの再読と実行検証に基づく。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
| 加点合計 | **+148** |
| 減点合計 | **-33** |
| **純点** | **+115** |
| 提案（0点） | 12 件 |

前回（自系統）比: **+87 → +115**（加点 +124 → +148、減点 -37 → -33）。

スコアの読み方を先に書く。加点が大きく伸びたのは、前回 P0 として挙げた 5 つの穴が**すべて塞がり、しかも塞ぎ方の質が高い**ためである。減点が -37 から -33 にしか下がっていないのは、既存の穴が埋まったぶん、これまで他の欠落に隠れて見えなかった深い問題（日次損失リミットの空振り、WS サイレントストール、本番の metrics 消費者不在）が表に出てきたためである。**純点の上昇は「live 解禁可」を意味しない。**

---

## 主要結論

1. **improvement-plan の P0（5 項目）はすべてコード上で解決している。** submission 不明の安全化、受注後 ID 永続化失敗時の halt、残高 baseline、`authorize?: false` の廃止、risk limits の 5 種実装。いずれも「実装して終わり」ではなく回帰テストが残っている。P1〜P3 の 14 項目も同様に実装を確認した。

2. **資金保全の骨格は、同種の個人プロジェクトとしては明確に上位にある。** `submission_unknown` を第一級の状態として持つこと、`Exchange.Client` の moduledoc にエラー分類を契約として書くこと、残高 append を advisory lock で直列化しデッドロック順序まで固定すること、`prep_stop` と `stop_grace_period` を数値で整合させること。どれも「動けばよい」を超えた設計判断で、理由がコードに残っている。

3. **最大の問題は、いちばん重要な安全装置が本番で発火しないこと。** `max_daily_loss` は検査経路もテストも設定値も揃っているが、`:daily_loss` を注入する本番コードが存在せず、常に `0` を見る（risk.ex L425-429）。残高検査も `:balances` 未注入で常にスキップされる（L432-438）。README L28 は両方を `implemented` と書いている。**「サイズ・建玉・頻度・価格逸脱は効くが、損失では止まらない」**が現在の実態で、これは Vision の Safety first の中核が空いていることを意味する。

4. **可用性の面で、自己修復できない停止モードが残っている。** WebSocket が接続を保ったまま無言になると、`Feed` は切断イベントを受け取らないため永久に再接続しない（feed.ex L122-130）。安全側には倒れる（risk が stale 拒否、`/health/ready` が 503）が、人が再起動するまで何もしない。24/365 という Vision の第一要件に対する直接の未達。

5. **本番に telemetry の集計先が無い。** 9 種のイベントと 9 本の counter が定義されているのに、reporter は 1 つも起動せず（ui/telemetry.ex L11-18）、LiveDashboard は `dev_routes` 限定（router.ex L42）。本番で観測できるのは構造化ログと Discord 通知だけで、率・推移で見るべき監視項目が全部この穴に落ちる。

6. **秘密情報の分離は現時点で問題を発見できなかった。** allowlist 方式の telemetry、`.dockerignore` の網羅、`.env` / `.env.prod` の gitignore（`git check-ignore` で確認済み、追跡されているのは `.env.example` のみ）、test 環境でのキー強制無効化、prod での必須値欠落時の起動停止。Least privilege（出金権限禁止）も 4 つの文書で一貫して書かれている。

7. **文書とコードの一致度が高く、自己改善サイクルが実際に回っている。** 前回「README が実装を追い越された」と指摘した点はコンポーネント表で解消された。残る不一致は risk-manager の 1 行だけ（結論 3 の過大申告）。評価 → improvement-plan → 1 項目 1 PR → 再評価のループがプロジェクトの資産になっている。

---

## 前回からの変化

### P0（live 解禁の前に塞ぐ穴）— 5/5 解決

| # | 項目 | 判定 | コード根拠 |
|:---:|:---|:---:|:---|
| 1 | submission 不明の安全化 | **解決** | `Live.handle_place_error/2`（live.ex L130-148）が `@definite_rejection_reasons` 以外を `:submission_unknown` にし `open_circuit_or_log!/2` で halt。`Order.status` に `:submission_unknown` を追加（order.ex L85-87）。テストログに `reason=timeout status=submission_unknown ... [critical]` と `reason=disconnected ...` を確認 |
| 2 | 受注後 ID 永続化失敗時の halt | **解決** | `Live.place/2`（live.ex L53-83）が `:critical` ログ + `open_circuit_or_log!(:persist_failed, ...)` + `{:error, :persist_failed, ...}`。テストログに `[critical] Failed to persist exchange_order_id after successful place_order` |
| 3 | 残高 baseline | **解決** | `Reconcile.ensure_balance_baseline/2`（reconcile.ex L272-280）が必須通貨欠如で `balance_baseline_missing`。既定は `config/config.exs` L23 の `["JPY","BTC"]`。テストログに `kind=balance_baseline_missing currency=JPY [warning] boot reconcile halted` |
| 4 | risk 迂回 `authorize?: false` の廃止 | **解決** | `lib/` 配下に一致 0 件。`submit/2` の `with` に `Risk.authorize` が固定（order_executor.ex L48）。迂回不可を `order_executor_test.exs` L548 と `capital_preservation_test.exs` L363 の 2 本で固定 |
| 5 | risk limits 完成 | **実装は解決 / 実効性は未達** | `Limits.t()` に 5 キー + 鮮度（limits.ex L12-19）、`authorize/2` に 8 段の検査（risk.ex L52-61）。ただし `max_daily_loss` と残高は本番で注入元が無く発火しない（weaknesses `-4` / `-2`） |

### P1〜P3 — 14/14 実装を確認

| # | 項目 | 判定 | コード根拠 |
|:---:|:---|:---:|:---|
| 6 | strategy の骨 | 解決 | `Strategy` behaviour（strategy.ex L20）+ `FixedOnce` + `Runner`。`Feed.put_tick/4` → `Runner.notify_tick/2`（feed.ex L295）で縦貫通 |
| 7 | graceful shutdown | 解決 | `Application.prep_stop/1`（application.ex L52-69）、`@child_shutdown_ms 5_000`、`stop_grace_period: 45s`（compose 双方） |
| 8 | halted 復帰手段 | 解決 | `Startup.Resume`（再突合成功時のみ）+ `mix bitflyer.resume` + prod.md L102-124 の手順 + release 用 rpc 手順 |
| 9 | paper 残高・指値 | 解決 | `Paper.decide_fill/3` の LTP 交差（paper.ex L77-88）、`Balances.apply_fill/2` で BalanceSnapshot を append |
| 10 | Discord 通知 | 解決 | `Observe.Discord`（halt / reconcile_mismatch / disconnect、cooldown、URL 非ログ、未設定でも起動） |
| 11 | StatusLive 発注可否 | 解決 | `orders-gate` セクション（status_live.ex L69-94）+ モード色分け（L285-292） |
| 12 | health の外形 | 解決 | `/health/live`・`/health/ready`・`/health` の 3 分割（health.ex、router.ex L26-28） |
| 13 | telemetry allowlist | 解決 | `:kind` / `:currency` / `:limit` を追加（telemetry.ex L52-54）、Logger メタデータも同期（config.exs L136-138） |
| 14 | README 現状同期 | ほぼ解決 | コンポーネント表（README L23-43）。ただし risk-manager の 1 行が過大申告（weaknesses `-1`） |
| 15 | UI 認証・bind | 解決 | Plug + on_mount の二層 BasicAuth、`PHX_HTTP_IP` allowlist、prod で資格情報必須 |
| 16 | API キー枠 | 解決 | `.env.example` L18-22、`runtime.exs` L128-134（live で欠落なら起動停止）、prod.md L29-35 |
| 17 | 本番 release Compose | 解決 | `Dockerfile.prod`（multi-stage / 非 root / tini）、`compose.prod.yaml`、`bin/deploy-prod.sh` / `bin/backup-db.sh` |
| 18 | private API client | 解決 | `Exchange.Rest`（署名・cancel・照会・約定反映）、`Exchange.Auth`、`Rest.HTTP`（`retry: false`） |
| 19 | deps audit | 解決 | ci.yml L69-109（ゲート外・3 値分類・artifact・「CI 緑 ≠ 脆弱性なし」の警告） |

### 前回の自系統マイナス点 — 解決状況

| 前回の指摘 | 判定 |
|:---|:---|
| strategy が 1 行も無い `-3` | **解決**（`Strategy` / `Runner` / `FixedOnce`） |
| live に約定確認と取消が無い `-3` | **解決**（`Client` に 5 callback、`OrderExecutor.cancel/2`、`LiveFills`） |
| risk 検査が 5 種中 2 種 `-3` | **部分解決**（実装は 5 種揃ったが損失・残高が本番で不発 → 新規 `-4` / `-2`） |
| BalanceSnapshot が本番から書かれない `-2` | **解決**（`Balances.apply_fill/2` + baseline 強制） |
| 戦略パラメータ履歴 Resource が無い `-1` | **未解決**（`Trading` は 4 Resource のまま） |
| halted 復帰手段が無い `-2` | **解決**（`Resume` + mix タスク + prod.md） |
| graceful shutdown が無い `-2` | **解決**（`prep_stop` + shutdown + grace period） |
| 時計ずれを拒否理由にできない `-1` | **未解決**（`skew` の一致 0 件） |
| market-data が ticker のみ `-1` | **未解決**（`Normalize` は ltp のみ。paper の約定モデル乖離が残る） |
| telemetry allowlist に `:kind` / `:currency` が無い `-1` | **解決** |
| `Heartbeat` の残骸 `-1` | **未解決** |
| 「今トレードしてよいか」が分からない `-2` | **解決**（発注可否バッジ・Feed・鮮度） |
| UI に認証が無い / 本番が全 IF bind `-2` | **解決**（BasicAuth 二層 + `PHX_HTTP_IP` allowlist） |
| Phoenix 生成テンプレの残骸 `-1` | **未解決**（`Layouts.app/1` のヘッダは Website / GitHub / Get Started のまま） |
| 本番 Dockerfile / Compose / release が無い `-3` | **解決** |
| API キーの環境変数名が未定義 `-2` | **解決** |
| 開発コンテナが root `-1` | **未解決** |
| 人に届くアラート経路が無い `-2` | **解決**（Discord アダプタ） |
| `test_helper.exs` に Sandbox モード指定が無い `-1` | **未解決** |
| 依存の脆弱性管理が無い `-1` | **解決**（`mix_audit` + CI ステップ + artifact） |
| `read_latest_balances/1` だけ生 Ecto `-1` | **未解決**（reconcile.ex L369-382 は 1 文字も変わっていない。理由コメントも未追加） |
| README が実装より古い `-1` | **解決**（コンポーネント表。ただし 1 行だけ逆方向にずれた） |

解決 14 / 部分解決 1 / 未解決 7。未解決 7 件はいずれも `-1` 級の残骸・軽微な設計負債で、資金保全に直結するものは無い。

---

## 実行検証

すべて Docker 経由（`d:\Work\FRICK-ELDY\docker-bitflyer`）で実行した。

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（exit 0、所要 6.4 秒） |
| └ `bitflyer` | **1 doctest, 187 tests, 0 failures** |
| └ `ui` | **23 tests, 0 failures** |
| `docker compose config --quiet` | **成功**（exit 0） |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（exit 0） |
| `git check-ignore -v .env .env.prod` | 両方 `.gitignore` に一致（`.env` / `.env.*`）。`git ls-files` に含まれる env 系は `.env.example` のみ |
| `.github/workflows/` | `ci.yml` / `cd.yml` の 2 本を確認 |
| TODO / FIXME 一致 | `apps/` 配下は `apps/bitflyer/README.md` の 1 件のみ（生成物の定型文） |

`precommit` の中身は `deps.unlock --check-unused` / `format --check-formatted` / `compile --warnings-as-errors` / `test --warnings-as-errors`（mix.exs L47-53）で、親エージェントの実行結果（bitflyer 1 doctest + 187 tests / ui 23 tests / exit 0）と一致した。

実行ログから、安全装置が実際に動作していることも確認できた（抜粋）。

```
[critical] live order submission_unknown            reason=timeout       internal_order_id=unknown-1
[critical] live order submission_unknown            reason=disconnected  internal_order_id=live-disc-1
[critical] Failed to persist exchange_order_id after successful place_order: :forced_persist_failure
[warning]  boot reconcile halted   kind=balance_baseline_missing currency=JPY   trade_mode=live
[warning]  boot reconcile halted   kind=position_missing_internal product_code=FX_BTC_JPY
[warning]  live cancel accepted; order remains open until terminal state is observed
```

**未実行**: 実 bitFlyer API への接続（`TRADE_MODE=dry_run` を維持したため）、`Dockerfile.prod` のビルド、本番 Compose の起動。したがって release の起動可否と `assets.deploy` の成否は今回の検証範囲外である（weaknesses の「本番イメージのビルドが CI で検証されない」も参照）。

---

## 現状の一文

**「止め方」と「壊さない止まり方」は、この規模のプロジェクトとしては完成度が高い。残る欠落は「止まったあと自分で戻れないこと」と、「いちばん重要な上限（日次損失）が設定値だけで実体を持たないこと」に集約される。**

通っている経路は「WS 購読 → 鮮度付き ETS → Strategy.Runner → Risk 8 段 → モード別 executor → 単一トランザクション永続化 → 突合 / halt → Discord / Status UI → `mix bitflyer.resume`」で、端から端まで繋がっている。dry_run で `docker compose up` すれば、意図が生まれ、リスクを通り、記録される。前回「一度も本番経路で駆動していない」と書いた状態はもう当てはまらない。

---

## 優先改善リスト

live 解禁の前に必要なものを上に置いた。番号は改善の順序であって、weaknesses の点数順ではない。

1. **日次損失の正本を作り、`max_daily_loss` を実効化する** — `Bitflyer.Trading.Fill`（`exchange_execution_id` unique）を足し、`LiveFills` / `Paper` から同一トランザクションで書く。そこから当日実現損益を集計し、`Risk.authorize/2` に注入する。正本が揃うまでの暫定として、live のときは「未計測」を `:unsynced` に倒す（静かに 0 を使わない）。**これが live 解禁の第一条件。**

2. **残高検査を実効化する** — `Risk.OrderRate` と同型の ETS キャッシュを置き、live は突合ごと、paper は擬似約定ごとに書き込む。live でキャッシュが空なら `:unsynced`。

3. **連続障害・署名エラーでサーキットを開く** — 401/403 は 1 回で `open_circuit(:auth_failed)`、その他の取引所エラーは窓内 N 回で `open_circuit(:consecutive_exchange_errors)`。あわせて `Decode.map_error/2` を数値エラーコード基準に直し、429 を `:rate_limited` として分離する。

4. **`submission_unknown` からの回収経路を用意する** — 発注直後の `getchildorders` 突き合わせによる自動回収と、一意に決まらない場合のオペレータ手順（`mix bitflyer.orphan` 相当 + prod.md への追記）。現状はこの状態に落ちると halt から抜けられない。

5. **WS サイレントストール watchdog** — 最終 tick からの経過を `Feed` が監視し、閾値超過で socket を落として再接続する。30 行程度で 24/365 の自己修復性が一段上がる。

6. **本番の metrics 消費者を用意する** — まず `Telemetry.Metrics.ConsoleReporter` を prod で有効化、次に Prometheus エクスポートか BasicAuth 配下の LiveDashboard。どちらを採るかを `prod.md` に書く。

7. **`mix precommit` に `ash.codegen --check` を足す** — マイグレーションのドリフトを 1 行で塞ぐ。同時に CI で `Dockerfile.prod` をビルド検証する（`push: false`）。

8. **README の risk-manager 行を `partial` に直す** — 1 と 2 が終わるまでは過大申告のまま置かない。

9. **時計ずれの計測と `:clock_skew`** — `Date` ヘッダとの差を telemetry に出し、閾値でサーキット。WSL2 前提なので優先度は見た目より高い。

10. **残骸と負債の棚卸し** — `Heartbeat` 削除、`Layouts.app/1` のヘッダ差し替え、`PageController` / `Ui.Mailer` / `:swoosh` 削除、`test_helper.exs` の Sandbox `:manual`、開発 Dockerfile の非 root 化、`read_latest_balances/1` の理由コメントと `rescue` の絞り込み。まとめて 1 PR で片付く。

11. **`lightning_executions_*` の購読と paper の手数料・スリッページ** — paper の損益が本番より楽観であることを解消する。1 と組み合わせて初めて「paper で損失シナリオを検証できる」状態になる。

12. **戦略パラメータ適用履歴 Resource** — 稼働中の実効上限を DB から確認できるようにする。

戦略アルゴリズムの高度化・板の本格購読・裁量 UI は、引き続きこれらの後でよい。

---

## live 解禁の可否（第1評価者の判断）

**不可。** 理由は 2 点に絞られる。

- **日次損失で止まらない**（優先改善 1）。サイズ・建玉・頻度・価格逸脱は効くので「一撃で大きく損をする」経路は塞がっているが、「小さく負け続けても止まらない」経路が開いている。無人稼働を前提にする以上、これは許容できない。
- **`submission_unknown` に落ちると人が復帰させられない**（優先改善 4）。安全に止まる設計は完成しているが、止まったあとの出口が塞がっているため、実弾を入れると「1 回のタイムアウトで無期限停止」になる。

逆に言えば、この 2 点と優先改善 2・3 を片付ければ、残りは可用性と観測性の改善であり、最小ロット + 厳しい上限での段階的解禁を検討できる水準に到達する。骨格そのものは既にその段階にある。
