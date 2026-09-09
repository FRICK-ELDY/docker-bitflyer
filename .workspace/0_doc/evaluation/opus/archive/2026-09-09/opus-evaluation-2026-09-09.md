# 第1評価者（Claude Opus 5）総合評価レポート 2026-09-09

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-09 |
| 評価者 | Claude Opus 5（第1評価者） |
| 対象コミット | `e029bd6`（`Merge pull request #26 from FRICK-ELDY/test/capital-preservation-regression`） |
| 基準 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md) |
| 詳細 | [strengths](./opus-specific-strengths-2026-09-09.md) / [weaknesses](./opus-specific-weaknesses-2026-09-09.md) / [proposals](./opus-specific-proposals-2026-09-09.md) |
| 前回（自系統） | [opus/archive/2026-09-08](./archive/2026-09-08/opus-evaluation-2026-09-08.md) |
| 前回（まとめ） | [archive/2026-09-08/evaluation-2026-09-08.md](../../../archive/2026-09-08/evaluation-2026-09-08.md) |

本評価は第2評価者の当日文書（`gpt/` 配下）を一切参照していない。前回の指摘は「解決済みと書く前に対象ファイルを読み直す」方針で、weaknesses に挙げた全項目の対象ファイルを再読して確認した。

---

## 総合スコア

| 区分 | 点数 |
|:---|---:|
| 加点合計 | **+124** |
| 減点合計 | **-37** |
| **純点** | **+87** |

### 大分類別

| 大分類 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 技術評価層 — apps/bitflyer | +64 | -20 | +44 |
| 技術評価層 — apps/ui | +13 | -5 | +8 |
| 技術評価層 — 実行基盤 / 設定 | +25 | -6 | +19 |
| 横断評価層 | +22 | -6 | +16 |
| **合計** | **+124** | **-37** | **+87** |

前回（Opus）は +61 / -60 = **+1**。1 サイクルで加点が倍増し、減点が 4 割に減った。

---

## 現状の一文

**「取引しないが、間違った取引もしない」システムとして、資金保全の骨格はほぼ完成した。残るのは判断（strategy）と、届ける手段（本番 release・通知）である。**

前回「文書でしか説明できない」と書いた Safety first / Recoverable / Idempotent は、いずれも**コードとテストで説明できる**状態になった。一方で、市場データを受け取っても意図を生む主体が無く、本番で起動する手段も無いため、Vision の「24時間365日 自動で売買する」までの距離はまだ残っている。

---

## 合意すべき結論

1. **資金保全の中核（fail-closed risk / 冪等 executor / boot 突合 / 鮮度ゲート / サーキット永続化）は実装され、回帰テストで固定された。**「発注していないこと」を積極的に検証する `CapitalPreservationTest` の存在は、この規模の個人プロジェクトとして突出している。
2. **`live` は三重ゲート（モード + 当日 UTC の `BITFLYER_LIVE_CONFIRM` + Ready）で守られ、既定の取引所クライアントが `Unavailable` のため物理的に発注できない。** 安全側の既定値が徹底されている。
3. **品質ゲートは完全に修復された。** ルート `mix precommit` が副作用ゼロで両アプリを検査し、GitHub Actions が同じ 1 コマンドを回し、テスト DB は開発 DB と分離された。前回の P0 5 項目はすべて解消。
4. **strategy が存在せず、`submit_order/2` を呼ぶ本番コードが 0 件。** 発注経路は 5 ステップ中 4 つが揃い、判断だけが欠けている。
5. **`live` に約定確認と注文取消が無く、経路が片道。** `Exchange.Client` の callback は 2 つだけで、`cancel_order` も約定照会も無い。live 解禁の前提条件を満たしていない。
6. **リスク検査が「サイズ・建玉・鮮度・同期」に限られ、日次損失・発注頻度・価格逸脱が未実装。** prod.md がハードリミットとして要求している 4 項目のうち 2 つが無い。
7. **本番で起動する手段が無い（release / `Dockerfile.prod` / `compose.prod.yaml` いずれも不在）。** engine が動くようになった今、これが Vision 達成の最大のボトルネック。
8. **異常が人に届かない。** halt しても標準出力に残るだけで、無人稼働の前提と噛み合わない。
9. **`BalanceSnapshot` が本番コードから一度も書かれず、残高突合が実質ノーオペ。** Resource はあるが書き込み側が無く、`compare_balances/2` は常に `:ok` を返す。

---

## 前回からの変化

### 解決済み（対象ファイルを再読して確認）

| 前回の指摘 | 前回 | 現在の状態 | 確認ファイル |
|:---|:---:|:---|:---|
| market-data / risk / order-executor が存在しない | -4 | 4 コンポーネントのうち strategy 以外は実装済み | `market_data/`, `risk.ex`, `order_executor.ex` |
| 起動シーケンス（復元→突合→停止→Ready）が無い | -3 | `Reconciler` + `Reconcile` + `Readiness` で 6 ステップを実装 | `startup/`, `readiness.ex` |
| 永続化が Heartbeat 1 枚 | -3 | `Order` / `Position` / `BalanceSnapshot` / `RiskState` + マイグレーション 3 本 | `trading/`, `priv/repo/migrations/` |
| `TRADE_MODE` の値検証が無い | -1 | `runtime.exs` で起動時 raise、`TradeMode` が正本 | `config/runtime.exs`, `trade_mode.ex` |
| 本番 release が無い | -3 | **未解決**（後述） | — |
| テストが開発 DB を共有 | -2 | `TEST_DATABASE_URL` 優先 + `_dev`→`_test` 自動置換 + パーティション | `config/runtime.exs` |
| healthcheck が `/` の 200 だけ | -2 | `/health` が DB + readiness で 200/503 | `compose.yaml`, `health.ex` |
| `.dockerignore` が無い | -1 | 秘密・成果物・作業文書を除外 | `.dockerignore` |
| `.github/workflows/` が無い | -3 | `ci.yml`（PostgreSQL service + ash.setup + precommit） | `.github/workflows/ci.yml` |
| ルート `precommit` が bitflyer を素通り | -3 | ルート alias に集約、`apps/ui` の重複削除 | `mix.exs`, `apps/ui/mix.exs` |
| `precommit` が `format`（書き換え）を使う | -2 | `format --check-formatted` + `deps.unlock --check-unused` に変更 | `mix.exs` |
| Compose の `MIX_ENV=dev` でゲートが失敗 | -2 | 注入を廃止。理由をコメント・README・`.env.example` に明記 | `compose.yaml` |
| 発注経路・冪等性・モード分岐の回帰が 0 件 | -3 | `CapitalPreservationTest` ほか 86 テスト | `test/bitflyer/` |
| telemetry / 構造化ログが無い | -2 | `Bitflyer.Telemetry`（9 イベント + allowlist）、LiveDashboard 連携 | `telemetry.ex`, `ui_web/telemetry.ex` |
| 「不整合なら Ready にしない」ゲートが無い | -2 | `Readiness` + `Reconciler` で実装、テストで固定 | `readiness.ex`, `reconciler.ex` |
| README が現状と乖離・リンク切れ | -2 | リンクは修正済み（ただし「現状」が今度は古い方向へ乖離） | `README.md` |
| 生成テンプレの記述が正本モジュールに残る | -1 | `Bitflyer` は薄いまま残るが、実体は各モジュールに移った | `bitflyer.ex` |
| モード切替が表示専用 | -2 | `DryRun` / `Paper` / `Live` の 3 出口を実装、非送信をテストで固定 | `order_executor/` |
| 起動→発注→突合の全経路が 0% | -4 | strategy を除き貫通。ただし駆動主体が無い（後述） | — |

### 未解決（前回から変化なし）

| 指摘 | 前回 | 今回 | 状況 |
|:---|:---:|:---:|:---|
| 本番用 Dockerfile / Compose / release が無い | -3 | -3 | ToDo 03 未着手。`Dockerfile` は開発用のまま |
| UI に認証が無く、本番は `0.0.0.0` bind | -2 | -2 | `router.ex` に認証プラグ無し。`runtime.exs` の bind も変わらず |
| Phoenix 生成物の残骸（ヘッダ / PageController / Mailer） | -1 | -1 | `layouts.ex` L48-64 のマーケティングリンクが残る |
| bitFlyer API キーの環境変数名が未定義 | -1 | -2 | `BITFLYER_API_KEY` の grep 一致 0 件。live クライアント不在と表裏で悪化 |
| グレースフルシャットダウンが無い | -1 | -2 | 書き込み対象が増えたため影響が拡大 |
| 依存の脆弱性管理が無い | -1 | -1 | ci-cd.md が非保証と明記しているため据え置き |
| 人に届くアラート経路が無い | -1 | -2 | 自動 halt が実装されたことで重要度が上昇 |
| `test_helper.exs` に Sandbox mode 指定が無い | -2 | -1 | 全 DB テストが DataCase / ConnCase 経由になり実害は縮小 |
| 開発コンテナが root 実行 | -1 | -1 | 変化なし |

### 今回あらたに検出

| 指摘 | 点数 | 概要 |
|:---|:---:|:---|
| strategy が存在せず `submit_order/2` の本番呼び出しが 0 件 | -3 | tick を受けても意図が生まれない |
| `live` に約定確認・注文取消が無い | -3 | `Exchange.Client` の callback が 2 つだけ |
| リスク検査に日次損失・発注頻度・価格逸脱が無い | -3 | `Limits` は 3 キーのみ |
| `BalanceSnapshot` が本番コードから書かれない | -2 | 残高突合が常に `:ok` |
| halted からの復帰手段が UI / mix タスクに無い | -2 | remote console 以外の再開経路が無い |
| 時計ずれを拒否理由にできない | -1 | WSL2 のリスクを Vision 自身が明記 |
| market-data が ticker のみ | -1 | paper の約定モデルが本番と乖離 |
| telemetry allowlist が `:kind` / `:currency` を落とす | -1 | 突合不整合の種類がログに残らない |
| パラメータ適用履歴 Resource が無い | -1 | 永続化最低限 6 項目のうち 1 つ |
| `Heartbeat` が用途を失ったまま残る | -1 | 棚卸し漏れ |
| `read_latest_balances/1` だけ生 Ecto + 広い rescue | -1 | 抽象レベルの不統一 |
| README の「現状」が実装より古い | -1 | 実装が README を追い越した |

**改善計画（improvement-plan.md）の消化状況: P0（#1-5）完了 / P1（#6-10）完了 / P2（#11-17）完了 / P3（#18-22）0-1 項目。** P3 #18（StatusLive の発注可否表示）は readiness 表示のみ部分達成、#19-22 は未着手。

---

## 実行検証結果

すべて Windows ホストから Docker Compose 経由で実行した。

| コマンド | 結果 | 備考 |
|:---|:---|:---|
| `docker compose config --quiet` | **成功**（exit 0） | Docker Engine 28.0.4 |
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**（exit 0、6.9 秒） | bitflyer: 1 doctest + 85 tests / ui: 10 tests、いずれも 0 failures |
| `docker compose run --rm app mix precommit`（`MIX_ENV` 明示なし） | **成功**（exit 0、6.8 秒） | 前回失敗していた「文書どおりのコマンド」が通るようになった |
| `.github/workflows/` の有無 | **存在**（`ci.yml`） | `pull_request` と `push: main` がトリガー |
| テストの実行安定性 | **安定** | シード `114459` / `8150` の 2 回で同一結果。順序依存なし |

precommit のログには `[warning] live order rejected` / `[warning] boot reconcile halted` が意図的に出ており、**安全側に倒れた事実がテスト実行中に観測できる**状態になっている。ログ行に `trade_mode=` / `reason=` / `internal_order_id=` の構造化メタデータが乗っていることも確認した。

未検証:

- `docker compose up -d` での常駐起動と `/health` の実応答（bitFlyer への実接続を伴うため実施せず。`config/test.exs` が実ネットを禁止しているのはテスト環境のみで、dev は `MarketData.enabled: true`）
- 本番相当の起動（実行手段が存在しないため検証不能）

---

## 観点別の要約

### 技術評価層 — apps/bitflyer（+64 / -20 = +44）

market-data / risk-manager / order-executor / datastore / cache / observe / OTP の 7 論理コンポーネントのうち 6 が実装され、いずれも fail-closed で書かれている。特に評価するのは、`Circuit` の開閉順序（開く: メモリ → DB、閉じる: DB → メモリ）、`gap_fill` の時刻比較による上書き防止、`create_pending` の unique 衝突フォールバック、`Positions.apply_fill` の `FOR UPDATE` + トランザクション + コミット後通知 — いずれも「知っていないと書けない」手当てである。

減点は「無いもの」に集中している。strategy、live の約定確認・取消、日次損失・頻度・価格逸脱のリスク検査、残高スナップショットの書き込み。いずれも既存の枠に足す形で実装でき、設計をやり直す必要は無い。

### 技術評価層 — apps/ui（+13 / -5 = +8）

`/health` の分離と DB エラー本文の非公開、Ready 状態と halt 理由の表示、Bitflyer ファサード経由のみの依存という点で、責務の限定は守られている。一方、`Bitflyer.System` が公開している運用情報（発注可否ゲート、市場データ鮮度、Feed 接続状態）を UI が使っていないため、prod.md が監視項目に挙げた 6 つのうち画面に出ているものが 0 という状態。認証と Phoenix 生成物の残骸も前回から動いていない。

### 技術評価層 — 実行基盤 / 設定（+25 / -6 = +19）

品質ゲート・CI・テスト DB 分離・`.dockerignore`・entrypoint・healthcheck の 6 点はすべて前回の指摘を正面から潰しており、しかも「なぜそうしたか」がファイル内のコメントに残っている。減点はほぼ本番構成の不在に集約される。

### 横断評価層（+22 / -6 = +16）

テスト戦略が最大の加点源。`config/test.exs` で実ネット接続を環境レベルで禁止し、`CapitalPreservationTest` が「REST を呼んでいないこと」と「注文行が作られていないこと」の両方を検証する構造は、取引システムのテストとして正しい形をしている。文書とコードの一致度も高く、Architecture が仕様書として機能している。

減点は「人に届く経路が無い」「README が古い」「静的解析が無い」といった、周辺の整備に関するもの。

---

## 優先順位（第1評価者としての推奨）

資金保全 → 復帰 → 観測 の順に重み付けした。

| 順位 | 項目 | 根拠 |
|:---:|:---|:---|
| 1 | **strategy の骨（ビヘイビア + 固定ルール 1 本）で `dry_run` の縦貫通** | risk / executor / 突合の品質が高いのに一度も本番経路で駆動されていない。アルゴリズムは要らない。経路を閉じることが目的 |
| 2 | **日次損失・発注頻度・価格逸脱のリミット追加** | prod.md がハードリミットとして要求。#1 で意図が生まれた瞬間に必要になる |
| 3 | **グレースフルシャットダウン（`prepare_stop` で発注ゲートを閉じる + `stop_grace_period`）** | #1 が動き出すと、デプロイのたびに未確定注文を作る構造になる。CD より先 |
| 4 | **通知アダプタ（halt / disconnect / mismatch の 3 イベント）** | 自動 halt する仕組みが完成した以上、止まったことが届かないのは片手落ち |
| 5 | **halted からの復帰手段（`mix bitflyer.resume`）と手順の文書化** | prod.md の稼働要件。remote console しか無い現状は無人運用と噛み合わない |
| 6 | **`live` の約定確認・注文取消（`Exchange.Client` の callback 追加）** | live 解禁の前提。ただし解禁自体を急がないなら #5 の後でよい |
| 7 | **本番 release / `compose.prod.yaml` / ロールバック（ToDo 03 手順 2-3, 5-6）** | Vision の 24/365 に到達する唯一の道。#3 が入ってから着手すると手戻りが少ない |
| 8 | **UI の発注可否バッジ + BasicAuth、`BITFLYER_API_KEY` の名前確定** | #7 で公開面が実在するようになる直前に必須 |
| 9 | **`BalanceSnapshot` の書き込み、telemetry allowlist への `:kind` / `:currency` 追加、README の現状同期** | いずれも小さいが、放置すると「あるように見えて無い」が固定される |
| 10 | **deps audit / Dialyzer / プロパティテスト / Game Day スクリプト** | ci-cd.md が後続と明記。#1-9 の後でよい |

戦略の収益性、板・約定の購読、裁量向け UI は、上記の後でよい。

---

## 評価者としての総評

前回「土台の方向は正しいが、まだ何も取引せず、資金を守るコードも無い」と書いた。1 サイクルで、**資金を守るコードは実在するようになった**。しかもその作り方は「動くものを先に作って後から安全装置を足す」ではなく、「安全装置を先に作り、その内側でしか動けないようにする」という順序で、これは取引システムとして正しい順序である。`Exchange.Unavailable` を既定にする、`BITFLYER_LIVE_CONFIRM` に当日日付を要求する、建玉が読めなければ拒否する — いずれも「安全側の既定値」に対する一貫した態度の表れで、設計思想が実装の細部まで届いている。

残っている課題は性質が変わった。前回は「作られていないものが多すぎる」だったが、今回は「作られたものが繋がっていない・届いていない・出せていない」である。strategy（繋ぐ）、通知（届ける）、本番 release（出す）の 3 つが揃うと、Vision の達成度は一気に上がる。逆に、この 3 つが揃わない限り、どれだけ内部の品質を上げても Vision の「人が張り付かなくても資金を守れる」は測定できないままである。

純点 **+87**。ただしこの数字は「取引システムとして完成に近い」ことを意味しない。**「壊さない土台としては非常に良い」ことを意味する**。Vision 達成度で言えば、まだ道半ばである。
