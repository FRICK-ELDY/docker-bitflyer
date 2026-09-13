# 第1評価者（Claude Opus 5）— 改善提案 2026-09-12

対象コミット: `1cfb413`（`Merge pull request #86 from FRICK-ELDY/fix/p2-deps-audit-gate`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-10_2](./archive/2026-09-10_2/opus-specific-proposals-2026-09-10_2.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は判断材料として参照していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 改善提案。現状が悪いわけではなく、「あると尚よい」という前向きな提案 |

**合計: 0 点（17 件）**

ここに挙げたものはいずれも**減点の対象にしていない**。現状が誤っているのではなく、今の水準をさらに押し上げる余地として書く。マイナス点詳細に挙げた 13 件の改善方針とは重複させていない。

---

## apps/bitflyer

### 取引所境界

- **`Exchange.Rest` にレート予算をコードで持たせる** `0`
  > 現在の流量制御は `LiveFills.Gate` の最小間隔（fill 同期経路）と `Risk.OrderRate`（発注件数）に分散している。bitFlyer の Private API は IP 単位・キー単位の制限があるため、`getbalance` / `getpositions` / `getchildorders` / `getexecutions` を合算した予算はどこにも表現されていない。定期突合 60 秒 + 認可前同期 + halt 時 cancel-all が重なる瞬間が最も濃い。
  >
  > `Exchange.Rest` の入口にトークンバケット（容量と補充速度を config）を置き、残トークンを telemetry に出せば、「今どれだけ余裕があるか」が Status で見えるようになる。429 が返ってきてから対処するより、返させない方が安全である。

- **`mix bitflyer.contract --private` の結果を監査行として残す** `0`
  > 署名 GET の契約確認は現在「人が実行して結果を目で見る」で終わり、記録は Game Day の手書き表に依存する。`BaselineImport` と同じ形で `ContractCheck` の監査行（実施時刻・操作者・対象・結果要約・権限一覧のハッシュ）を残せば、「最後に権限を確認したのはいつか」に機械が答えられる。live 解禁前チェックリストの証跡としても使える。

- **時計ずれを独立に観測して telemetry に出す** `0`
  > `Risk.check_clock_skew` は ticker の `source_timestamp` とホスト時刻の差で fail-closed になり、これは正しい。ただし「ずれ始めている」は見えず、halt して初めて分かる。vision.md が本番 PC（Windows 11 + WSL2）の時刻ずれをリスクとして名指ししているので、skew の実測値を周期的に telemetry に出し、Status に「現在の skew / 閾値までの余裕」を出すと予兆で気付ける。閾値の 8 割で Discord に warning を投げる運用もできる。

### risk-manager

- **`Order` に拒否理由を永続化して `FailureRate` の warm を絞る** `0`
  > `FailureRate` の起動 warm は `status == :rejected` の Order を全部数える（過大側 = 安全側）という妥当な妥協で、moduledoc にもそう書かれている。`Order` に `rejection_reason`（allowlist atom）を持たせれば、countable な理由だけを warm でき、「ユーザー取消由来の rejected でサーキットが一時的に厳しくなる」がなくなる。事後分析（どの理由で何回弾かれたか）にも使える。

- **スプレッドと板厚のゲート（P3 #16 の前段）** `0`
  > 板ストリームが無くても、ticker には `best_bid` / `best_ask` が含まれている。`Normalize` でこの 2 つを保持するだけで、`Risk` に「スプレッドが N bps を超えたら成行を拒否」を入れられる。異常時に成行を投げて大きく滑る、という損失パターンに対して、板購読を待たずに手が打てる。

- **戦略パラメータの段階適用（canary）** `0`
  > `StrategyParameterRevision` で改訂は記録できるが、適用は即時・全量である。「新改訂は最初の N 注文だけ / 最初の M 分だけ適用し、その間の結果が閾値を割ったら自動で前改訂に戻す」を入れると、パラメータ変更の事故を小さく閉じられる。既に改訂履歴と Order への適用記録があるので、戻す材料は揃っている。

### テスト

- **live 縦貫通の擬似取引所ハーネス** `0`
  > 現在の live 経路のテストは、モジュール単位では厚いが「発注 → 部分約定 2 回 → 残高変動 → 次の定期突合 → Ready 維持」という縦の 1 本を通していない。`Exchange.Client` behaviour が既にあるので、約定列と残高変動を台本で与えるスタブ取引所を作れば、Game Day Stage 3 / 4 の内容をコードで再現できる。マイナス点詳細の 1 件目（残高突合が baseline 固定）は、このハーネスがあれば実装前に検出できたはずの種類の欠陥である。今後の live 化で最も効く投資だと考える。

- **プロパティベーステスト（`stream_data`）** `0`
  > 金額会計には不変条件が明確にある。約定列をランダム生成しても (a) `filled_notional / filled_size` が全約定の VWAP に一致する、(b) hold の消費と解放の総和が保存される、(c) 同じ `internal_order_id` を何度投げても注文は 1 件、(d) 実現損益の総和が Position の増減と整合する。例示ベースのテストは既に厚いので、次の層はここである。

- **`Credo` / `Dialyzer` を precommit の別段に** `0`
  > `ci-cd.md` の「保証しないこと」に自ら挙げている項目である。`@spec` は主要モジュールにほぼ揃っているので Dialyzer の初期ノイズは少ないと見込める。PLT のキャッシュを CI に載せれば、`Decimal` と `nil` の混在のような型レベルの取りこぼしを機械が拾える。

---

## 観測・運用

- **Prometheus scrape エンドポイント（P3 #18）** `0`
  > telemetry の語彙は整備され、`ConsoleReporter` と Discord と Status があるが、時系列が残らない。`TelemetryMetricsPrometheus` を UI 側に足して `/metrics`（BasicAuth 配下）を出せば、既に用意してある別ホストの exporter 環境からそのまま scrape できる。ドローダウン推移・authorize 拒否理由の内訳・突合失敗頻度は、数値で追えると運用判断が変わる。

- **Status に「直近突合の結果」と「次回までの残り時間」を出す** `0`
  > 定期突合は 60 秒ごとに静かに走り、成功は画面に現れない。最後の突合時刻・結果・検出差分の要約と次回までの秒数を出すと、「止まっていないこと」を能動的に確認できる。halt してから気付くのではなく、健全であることが見える形になる。

- **Discord 通知の重要度別ルーティング** `0`
  > 現在は同一 Webhook に cooldown 付きで投げている。halt / `submission_unknown` / 突合不一致は mention 付き（`@here`）、HEARTBEAT と情報系は別チャンネル、という 2 系統にすると、深夜の停止に気付く確率が上がる。通知先を増やすのではなく、既存の 1 本を重要度で分けるだけで効果がある。

- **DB バックアップの復元試験を自動化する** `0`
  > prod.md にバックアップ / リストア手順はある。ただし「取ったダンプが実際に戻るか」は人が思い出したときに確認するしかない。月次でダンプを使い捨てコンテナに復元し、`fills` の当日合計と `orders` の件数が一致することを検査するスクリプトを置くと、バックアップが実際に使えることが保証される。資金記録の復元可能性は Recoverable の最後の砦である。

- **`resume` と live 戦略有効化に二者承認を要求する** `0`
  > `baseline` / `recover` には操作者名と hash 承認がある。一方 `resume` は「突合が成功すれば」1 操作で halt を解ける（突合成功が条件なので設計としては妥当）。それでも「なぜ止まったかを理解せずに resume を押す」は個人運用で最も起こりやすい行為である。resume 時に halt 理由と復帰手順を再表示し、理由コードのタイプ入力を要求する（`confirm=daily_drawdown_exceeded` など）だけで、反射的な再開を防げる。

---

## 実行基盤

- **SBOM 生成とイメージ署名（cosign）** `0`
  > `ci-cd.md` は Docker ベースイメージの脆弱性を保証しないと明記している。`docker-prod` ジョブで SBOM（syft 等）を artifact に残し、CD で push する digest に cosign 署名を付けると、「本番 PC が pull したイメージが CI が作ったものと同一か」を検証できる。個人運用でも、VLAN 越しの pull を前提にするなら価値がある。

- **`Bitflyer.System` の公開面に契約テストを張る** `0`
  > UI と mix タスクと `Release` rpc が触る面は `Bitflyer.System` に集まっている。ここが返す構造（`operational_status/0` / `exposure/0` のキー集合と型）を固定するテストを置くと、ドメイン側のリファクタで画面や運用タスクが静かに壊れるのを防げる。umbrella の依存方向は既に一方向なので、境界を固定する価値が高い。

- **`DailyLoss` の当日集計を DB 側の集約に寄せる** `0`
  > `sum_realized/3` は当日 Fill を全行読んで Elixir で合算する。60 秒ごとの `reload` で回るため、live を execution 単位 Fill にしたぶん行数が増える経路である。`Ash.aggregate(:sum)` か `Repo.aggregate` に寄せれば、行を BEAM に運ばずに済む。現状の規模では問題にならないので提案に留めるが、保持方針（マイナス点詳細参照）と合わせて考えるのが自然である。
