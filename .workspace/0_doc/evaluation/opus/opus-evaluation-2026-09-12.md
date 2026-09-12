# 第1評価者（Claude Opus 5）— 総合評価レポート 2026-09-12

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-12 |
| 評価者 | 第1評価者（Claude Opus 5） |
| 対象コミット | `1cfb413`（`Merge pull request #86 from FRICK-ELDY/fix/p2-deps-audit-gate`） |
| 基準文書 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 前回（自系統） | [opus/archive/2026-09-10_2/opus-evaluation-2026-09-10_2.md](./archive/2026-09-10_2/opus-evaluation-2026-09-10_2.md) |
| 詳細 | [マイナス点](./opus-specific-weaknesses-2026-09-12.md) / [プラス点](./opus-specific-strengths-2026-09-12.md) / [改善提案](./opus-specific-proposals-2026-09-12.md) |

**第2評価者（GPT）の当日文書および `.workspace/0_doc/evaluation/gpt/` 配下（archive を含む）は、本評価の判断材料として参照していない。** 参照した既存文書は、自系統の前回アーカイブ（2026-09-10_2）、`improvement-plan.md`（検証対象として）、`.cursor/rules/evaluation.mdc`、Vision / Architecture / README / CI 設定 / config、および現行コードとテストである。改善計画が「完了」と宣言した項目は、すべて対象ファイルを開いて現在のコードで真偽を判定した。

---

## 1. 総合スコア

| 区分 | 点数 | 件数 |
|:---|---:|---:|
| 加点 | **+203** | 65 件 |
| 減点 | **-18** | 13 件 |
| **純点** | **+185** | |
| 改善提案 | 0 | 17 件 |

### 前回比

| 区分 | 前回（2026-09-10_2） | 今回（2026-09-12） | 差分 |
|:---|---:|---:|---:|
| 加点 | +185 | +203 | +18 |
| 減点 | -24 | -18 | +6 |
| **純点** | **+161** | **+185** | **+24** |

2 日で純点 +24。前回の 19 件のマイナス点のうち **11 件（-16 点分）が解決**し、未解決は 8 件（-8 点分）。新規に 5 件（-10 点分）を検出した。加点側は order-executor（+40）と risk-manager（+35）が中心で、特に execution 単位の約定記帳（`+5`）は、このクラスのプロジェクトで初めて満点を付けた項目である。

---

## 2. improvement-plan の「完了」宣言の判定

`improvement-plan.md`（2026-09-12 更新）は P0 #3–#5 / P1 #6–#10 / P2 #11–#15 を完了と宣言している。P0 #1 / #2 は完了表記なしだが実装されているため併せて判定した。**すべて対象ファイルを現在のコードで再読して判定している。**

| # | 項目 | 宣言 | 判定 | コード上の根拠 |
|:---:|:---|:---:|:---:|:---|
| P0 #1 | 部分約定の増分価格 | （表記なし） | **解決** | `live_fills.ex` `apply_one_execution/3` が `exec.price` で 1 明細ずつ記帳し、`filled_notional` を対で進める。`ensure_execution_coverage/4` が明細欠落・合計不一致・差分不一致の 3 条件で fail-closed。回帰 `successive partial fills use incremental prices` ほか 3 本 |
| P0 #2 | live を spot / FX のどちらかに限定 | （表記なし） | **解決** | `Product.market_type/1` の spot allowlist（未登録は `:unsupported`）、`LiveSafety.assert_live_products!/1` が起動を止め、`Risk.check_live_product/2` が認可を止める。`config.exs` は `["BTC_JPY"]` |
| P0 #3 | Decode の構造 fail-closed | 完了 | **解決** | `decode.ex` L8 `:skip` は allowlist のみ・`@allowlisted_skip_order_states MapSet.new([])`、`@payload_errors` 6 種で snapshot 全体失敗。テストログに `unknown_side ... failing snapshot` / `missing_identifier` / `invalid_number` |
| P0 #4 | OrderRate の原子的予約 | 完了 | **解決** | `handle_call({:reserve, ...})` が GenServer 内で prune + count + `make_ref()` 挿入。warm は `:committed` 行のみ置換して in-flight を残す。warm 失敗は `{:error, :unsynced}` |
| P0 #5 | live fill 同期の整理 | 完了 | **解決** | `do_submit/2` から再同期を削除、`sync_live_fills_before_authorize/2` の 1 箇所のみ。`LiveFills.Gate` が最小間隔 1s と直列化。post-place 失敗は `{:error, :fill_sync_failed, %{order_accepted: true}}` + サーキット |
| P1 #6 | `BalanceCache.load_latest/1` | 完了 | **解決** | `BalanceSnapshot.latest_tips/1` の `DISTINCT ON`、索引の列順一致、rescue を 2 例外に限定。`Reconcile.read_latest_balances/1` も同じ関数へ委譲 |
| P1 #7 | FailureRate の warm | 完了 | **解決** | `init/1` → `replace_from_db/2` が trade_mode ごとに rejected Order を窓幅ぶん warm、失敗は unsynced で `{:halt, :failure_rate_unsynced}`。残差（理由を区別しない）は moduledoc に自認 |
| P1 #8 | Fill の証跡 | 完了 | **解決** | `order_id` FK（`on_delete: :restrict`）、`(trade_mode, exchange_execution_id)` 部分一意（`where: "... IS NOT NULL"`、`nils_distinct?: true`）、`execution_filled_at/1` で取引所時刻。旧 nil id baseline は `:legacy_nil_execution_id` で拒否 |
| P1 #9 | Status / ready の統一 | 完了（残差明記） | **部分解決** | `Health.classify_ready/4` と `OperationalStatus.classify/5` は同一の `market_feed_gate/2` を使う（ここは完全）。一方 `Risk.authorize/2` の鮮度検査は `Cache.fresh?/3` のみで Feed 切断を見ない。宣言文に残差が書かれているため過大申告ではないが、「画面が STOPPED でも認可が通る」窓が残る（**-1**） |
| P1 #10 | 未約定期限 / halt cancel-all | 完了 | **解決** | `OpenOrderPolicy` + `HaltCancelGate`（in-flight ロック・backoff 30s・`:cleared` 省略・stale 600s 失効）。`ensure_halt_cancels` を起動 / CircuitSync / halt_trading の 3 経路から呼ぶ。既定 `max_open_age_ms: :infinity` は運用選択として prod.md に記載 |
| P2 #11 | equity ドローダウンゲート | 完了 | **部分解決** | `Risk.Equity` の実装は完全（HWM・stale 3 層方針・未知 side は unsynced・`record_peak: false`）。しかし `DailyLoss.init/1` が `peak` に `zero()` を入れるため**再起動でピークが消える**。完了条件「建玉持ち越し・実現益後の含み損でも止まる」は再起動を挟むと満たされない（**-2**） |
| P2 #12 | 外部監視 | 完了（手順・探針） | **部分解決（宣言どおり）** | `bin/watch-ready.sh` / `compose.observe.yaml` / Windows exporter 手順 / Discord HEARTBEAT は存在。別ホストでの常駐は live チェックリスト側と自ら線引きしており、過大申告ではない |
| P2 #13 | Status の情報密度 | 完了 | **解決** | `Observe.Exposure`（建玉 mark / 未約定 count + oldest / 当日損益 + headroom / halt 復帰手順 / 残高）と StatusLive。`Ash.count` + `limit 20`、rescue で UI 保護 |
| P2 #14 | API contract / Game Day | 完了 | **解決** | 匿名化 corpus + `Contract.check_corpus/1` を precommit に、`@forbidden_private_paths` で発注 REST を禁止、`game-day.md` に 2026-09-12 Stage 0 の実施記録あり |
| P2 #15 | deps.audit ゲート分離 | 完了 | **解決** | 別ジョブ `deps-audit` + `bin/classify-deps-audit.sh` の 3 値分類（advisory のみ exit 1）。`test/ci/classify_deps_audit_test.exs` でシェルの分類を回帰。今回の実行も `No vulnerabilities found.` |

**判定: 解決 13 / 部分解決 3（うち #12 は宣言どおり）/ 未解決 0。**

15 項目中 13 が完全に閉じており、残る 3 件も「何が残っているか」を本文で自ら書いている（#9・#12）。**明確な過大宣言は 1 件も無かった。** これは評価者として最も検証しにくい部分であり、文書の信頼性そのものとして加点した（プラス点詳細「文書がコードと一致し、未達の残差を自分から書いている」`+3`）。

例外は #11 である。ここだけは宣言と実装に真の乖離がある。ドローダウンゲートは「実現益を出したあとに含み損で溶ける」を止めるために作られたが、そのゲートの基準となる当日ピークが揮発性で、プロセス再起動で 0 に戻る。vision.md 自身が本番 PC（Windows 11 + WSL2）の予期しない再起動をリスクに挙げているため、これは理論上の話ではない。

---

## 3. 前回マイナス点の解決状況

| 前回の指摘 | 前回 | 状況 |
|:---|:---:|:---|
| 既定 FX にスポット残高モデル（live ブロッカー） | -3 | **解決** |
| 部分約定に累積 VWAP（live ブロッカー） | -2 | **解決** |
| live 発注 1 回で全件照会 2 回 | -2 | **解決** |
| `Fill.exchange_execution_id` が常に nil | -1 | **解決** |
| `Fill.filled_at` がホスト壁時計 | -1 | **解決** |
| 残高検査と `reserve` のねじれ | -1 | 未解決 |
| `FailureRate` に再起動復元が無い | -1 | **解決** |
| `BalanceCache.load_latest/1` が全件読 | -2 | **解決** |
| 永続データの保持方針が無い | -1 | 未解決 |
| `Fill` が `Order` を文字列参照のみ | -1 | **解決** |
| ticker 一本（板・約定ストリーム無し） | -1 | 未解決 |
| `websockex` 0.4 依存 | -1 | 未解決 |
| `read_latest_balances` の生 Ecto + 広い rescue | -1 | **解決** |
| StatusLive に未約定 / 損益 / 不整合が無い | -1 | **解決** |
| `precommit` に `ash.codegen --check` が無い | -1 | 未解決 |
| 開発コンテナが root | -1 | 未解決 |
| `test_helper.exs` に Sandbox mode が無い | -1 | 未解決 |
| API 契約が手書き fixture のみ | -1 | **解決** |
| `apps/bitflyer/README.md` が TODO テンプレ | -1 | 未解決 |

**解決 11 件（-16 点分）/ 未解決 8 件（-8 点分）。** 根拠は[マイナス点詳細](./opus-specific-weaknesses-2026-09-12.md)の末尾表に、ファイルと行番号付きで記載した。

未解決 8 件のうち 5 件（`ash.codegen --check`、開発 Dockerfile の root、Sandbox mode、`websockex`、保持方針）は 3〜4 サイクル連続で残っている。いずれも 1〜2 行で片付く種類である。P0/P1/P2 を毎サイクル完走する実行力があるのだから、この滞留はやる気の問題ではなく、P3「軽微負債」が優先度の底に沈み続ける運用構造の問題だと見る。「毎サイクル P3 を 3 件必ず消す」のような別枠を設けたほうが早い。

### 新規に検出したマイナス点

| 指摘 | 点数 |
|:---|---:|
| live 残高突合が固定 baseline との厳密一致で、最初の残高変動で必ず `balance_mismatch` halt になる | -4 |
| live spot で建玉突合が完全に無効で、ドローダウンゲートの入力が一度も外部照合されない | -2 |
| 当日 equity ピーク（HWM）が永続化されず、再起動でドローダウンゲートが緩む | -2 |
| `Risk.authorize/2` が Feed 接続を見ず、Status / `/health/ready` と矛盾する | -1 |
| `getexecutions` の 500 件上限超過は恒久 fail-closed になる（ページングなし） | -1 |

上の 3 件は独立した実装ミスではなく、**同じ根に由来する**。P0 #2 を「live は spot のみ」で解いた結果、`getpositions` が使えなくなり、残高（`getbalance`）が唯一の外部正本になった。ところが「取引所残高を正本にして内部を更新する」という書き換えが行われず、突合は従来どおり「内部を正本にして取引所を検査する」形のまま残された。P0 #2 の実装は正しく、影響範囲の洗い出しが 1 段足りなかった、という性質の欠落である。

---

## 4. 実行検証の結果

Docker Compose を正本として 4 件を実行した（すべて `d:\Work\FRICK-ELDY\docker-bitflyer`）。

| # | コマンド | 結果 |
|:---:|:---|:---|
| 1 | `docker compose run --rm -e MIX_ENV=test app mix precommit` | **exit 0**。`bitflyer`: 1 doctest + **483 tests / 0 failures**、`ui`: **38 tests / 0 failures**。所要約 12 秒（`_build` ウォーム） |
| 2 | `docker compose config --quiet` | **exit 0** |
| 3 | `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **exit 0**（`.env.prod` は存在） |
| 4 | `docker compose run --rm app mix deps.audit` | **exit 0**。`No vulnerabilities found.` |

### 警告

`mix precommit` は `compile --warnings-as-errors` と `test --warnings-as-errors` を含み、いずれも通っている。コンパイル警告・テスト警告はゼロである。テスト実行中に `Bitflyer.Release.halt_trading_result/1` 由来の実行時警告が 1 件出るが、これは異常系を意図的に踏んだ結果で、`--warnings-as-errors` の対象ではない。

### テストログで確認できた安全装置の発火

「安全装置が実際に働くこと」がテストで踏まれていることを、ログから確認した。

`submission_unknown`（critical）/ `persist_failed`（critical）/ boot 突合 halt 5 種（`balance_baseline_missing`・`clock_skew`・`invalid_number`・`unsafe_api_permissions`・`position_missing_internal`）/ `daily drawdown exceeded; circuit opened` / `live fill refused` 3 種（`inconsistent filled_notional baseline`・`legacy nil exchange_execution_id baseline`・`terminal filled_size mismatch`）/ `prep_stop: in-flight drain timed out` / `order rate warm failed; marked unsynced` / `failure rate warm failed; marked unsynced` / `HaltCancelGate cancel worker died before finish` / `resume blocked: equity not resumable` / `unknown_side ... failing snapshot`。

### 実行しなかった項目

- **実 bitFlyer API への接続**（指示により禁止）。したがって `mix bitflyer.contract`（公開 GET）と `--private`（署名 GET）は未実行。corpus によるオフライン意味論検査は precommit 内で通っている
- **本番長時間稼働 / soak**（指示により禁止）。`compose.prod.yaml` は構成検証のみで、コンテナ起動と `Dockerfile.prod` の完全ビルドは行っていない（CI の `docker-prod` ジョブが同等をカバーしている）
- **実際の live 発注**（コード上も禁止中）

---

## 5. live 解禁の可否

### 結論: **live 実発注は解禁してはならない。** Stage 3 以降は引き続き封じる。

P0 #1 / #2 が閉じたことで、prod.md と game-day.md が Stage 3 の条件としている「P0 完了」は形式的には満たされる。しかし**満たしてはならない**。理由を資金保全の優先順で述べる。

**第一に、live を開始した直後に必ず停止する。** マイナス点詳細の 1 件目のとおり、live の残高突合は「baseline を取った瞬間の残高」と「現在の取引所残高」を厳密一致で比較し続ける。内部 `BalanceSnapshot` を前進させる書き手が live には存在しない（`LiveFills` は残高を触らず、`Reconciler` は ETS だけ更新し、`Balances.apply_fill` は paper 専用、`Baseline.import` は完了後は `:baseline_already_complete` で拒否）。指値を 1 本置けば `available` が動き、約定が 1 回入れば `amount` も動く。どちらも次の 60 秒突合で `balance_mismatch` → halt になる。しかも `reconcile_mismatch` は `cancel_on_halt: false` なので未約定は板に残り、正規の復旧手順は存在しない。

これは fail-closed なので資金は減らない。ただし「資金は減らないが、板に注文を残したまま止まり、人が DB を直接触るまで戻れない」という状態は、24/365 の無人運用としては失格である。

**第二に、止める仕組みの入力が検証されていない。** spot では建玉突合が完全に無効化されており、`max_position_size` とドローダウンゲートは「一度も外部照合されない内部カウンタ」だけで動く。`LiveFills` の記帳が正しい限り正しいが、それは前提であって検証ではない。README 自身が「Fill 後の Position ドリフトは残高突合と `LiveFills` に依存する」と書いており、その 2 本目の柱（残高突合）が上記のとおり機能しない。

**第三に、再起動でドローダウンゲートが緩む。** 当日ピークが永続化されていないため、+10 万 → +2 万（drawdown 8 万）の状態で再起動すると drawdown が 0 に戻る。本番 PC の予期しない再起動は Vision がリスクとして名指しした事象である。

**第四に、部品の質は高いが縦の 1 本が通っていない。** execution 単位の記帳、hold 会計、`submission_unknown`、halt cancel-all、承認付き回収——個々の設計はいずれも商用水準である。しかし「発注 → 部分約定 2 回 → 残高変動 → 次の定期突合 → Ready 維持」という縦の経路をコードで一度も通していない。上の 3 件はすべて、その縦のテストがあれば実装前に見つかっていた種類の欠陥である。部品が揃っていることと、系として回ることは別である。

**第五に、外部監視の常駐がまだ無い。** P2 #12 は自ら「完了は手順と探針まで」と線を引いている。無人運用の前提として、別ホストからの ready pull が実際に回っていることを live 前に確認する必要がある。

### 解禁の前提条件（この順で）

1. live の残高突合を「取引所を正本、内部 tip は監査記録」に反転させる。突合成功時に取引所残高から新しい `BalanceSnapshot` を append し、比較基準を前進させる。厳密一致をやめ、説明できない差分だけを `balance_mismatch` にする。`Baseline` は初期化専用と明示し、承認付き `--rebaseline` を用意する
2. 当日 equity ピークを永続化し、`init/1` で読み戻す（読取失敗は unsynced で fail-closed）
3. spot の在庫突合を `getbalance` の base 通貨数量と内部 Position（+ 未約定売り拘束）で行う
4. 擬似取引所ハーネスで「発注 → 部分約定 → 残高変動 → 定期突合 → Ready 維持」の縦 1 本を回帰にする
5. 別ホストからの ready pull 常駐を実際に動かし、非 ready の検知を人が確認する
6. そのうえで paper soak（Stage 2）を数日回し、Stage 3 へ進む

1〜4 が済むまで、Stage 3 の封印は解かないこと。**部品が増えたことを理由に解禁を前倒ししてはならない。**

---

## 6. 主要な結論

**このサイクルの仕事は、ほぼ完璧に近い。** 2 日で P0 5 件・P1 5 件・P2 5 件を、それぞれ独立した PR として閉じ、15 項目中 13 を完全に、残り 2 も残差を明記した部分解決として仕上げた。前回の live ブロッカー 2 件は、どちらも「回避」ではなく設計の作り直しで解いている。特に部分約定の累積 VWAP 問題を、価格計算の修正ではなく「約定を execution 単位で記帳する」というモデル変更で解き、`filled_size` / `filled_notional` の対不変条件と 3 段の coverage 検査と DB 往復を挟む回帰テストまで揃えたのは、個人プロジェクトで見たことのない水準である。この 1 項目に `+5` を付けた。

**同時に、live に対する評価は前回より厳しくなった。** 前回は「2 つのブロッカーが塞がれれば最小ロットに進める」と書いた。今回そのブロッカーは塞がれたが、代わりに「live を開始した瞬間から 1 分以内に、必ず誤検知で停止する」という欠陥が露出した。これは新しく作り込まれたバグではなく、P0 #2 を spot 限定で解いた際に影響範囲の洗い出しが 1 段足りなかった結果である。突合の意味論だけが FX 時代の前提（内部が正本で取引所を検査する）のまま取り残されている。

この構図は 3 サイクル連続で同じ形をしている。**部品の品質は毎回上がり、部品間の意味論的な接続が毎回 1 箇所取り残される。** 前回は「FX の建玉に spot の残高モデルを当てていた」、今回は「spot に切り替えたのに残高更新の向きを変えていない」。どちらも個々のモジュールを読むと正しく、モジュール間の前提を突き合わせると壊れている。モジュール単位のテストがいくら厚くても、この種の欠陥は捕まらない。

したがって次サイクルの最優先は、新機能でも新しい安全装置でもなく、**縦の 1 本を回すテストを作ること**だと考える。`Exchange.Client` behaviour が既にあるので、約定列と残高変動を台本で与えるスタブ取引所を置けばよい。それがあれば、今回検出した 3 件は実装前に赤くなっていた。改善提案では「live 縦貫通の擬似取引所ハーネス」として挙げた。live 化に向けて最も効く投資はこれ 1 つだと見る。

**総括すると、これは「よく設計された未完成品」ではなく「ほぼ完成した部品群と、まだ通っていない 1 本の配線」である。** 純点 +185 はその評価である。あと 1 サイクル、機能を足さずに配線だけを通す仕事に充てられるなら、live 最小ロットは現実的な射程に入る。逆に、ここで新機能や P3 の消化に向かうなら、live はまた遠ざかる。
