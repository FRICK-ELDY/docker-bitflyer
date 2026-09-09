# 第1評価者（Claude Opus 5）— 提案詳細 2026-09-09

対象コミット: `e029bd6`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/dev.md](../../architecture/env/dev.md) / [env/prod.md](../../architecture/env/prod.md)
前回（自系統）: [opus/archive/2026-09-08](./archive/2026-09-08/opus-specific-proposals-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

提案は批判ではなく「次のステップ」として記録する。Vision 上の必須度が高く欠如が資金保全に直結するものは、提案ではなく[マイナス点](./opus-specific-weaknesses-2026-09-09.md)側に計上している。

---

## 取引ドメインの厚み

### 約定と損益

- **Fill / Execution 履歴 Resource を切り出す** `0`
  > 現在、約定の事実は `Order.status` と `filled_size`、`Position.average_price` に畳み込まれており、**個々の約定イベントが残らない**。部分約定が 3 回に分かれても記録は 1 行の更新結果だけで、実現損益・手数料・約定単価の分布を後から再構成できない。`Fill`（内部注文 ID・約定単価・数量・手数料・取引所約定 ID・約定時刻）を足すと、日次損益リミット（マイナス点で挙げた `max_daily_loss`）の計算根拠、税務・確定申告バックログ（`.workspace/1_backlog/tax-portfolio-kakutei-shinkoku.md`）、戦略のバックテスト用データがすべて同じ 1 テーブルから取れる。`Positions.apply_fill/2` の中で 1 行 insert するだけなので、実装コストは小さいうちに入れたい。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`, `apps/bitflyer/lib/bitflyer/order_executor/positions.ex`

- **`paper` にスリッページ・手数料モデルを入れる** `0`
  > `OrderExecutor.Paper.fill_price/3` は成行を LTP で即時全量約定させる。overview.md L98 の「同じ経路を通さないペーパーは、本番で初めて壊れる」は経路の話だが、**約定条件が本番と違うペーパーも、本番で初めて壊れる**。`Bitflyer.Fill.Model` のような差し替え可能なモジュールを置き、既定を「LTP ± 固定 bps + 手数料率」にして設定から変えられるようにすると、paper の損益が本番の下限を示すようになる。板を購読していない現状でも bps ベースなら実装できる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

### 戦略の受け皿

- **`Bitflyer.Strategy` ビヘイビアとパラメータ Resource を先に置く** `0`
  > strategy の不在自体はマイナス点に計上したが、その先に「戦略を安全に差し替える枠」が要る。`@callback evaluate(market_snapshot, position_snapshot, params) :: [command]` のような純関数ビヘイビアにしておくと、(1) 取引所 API を直接叩けない依存方向が型で強制でき、(2) 戦略単体テストが DB もネットワークも要らなくなり、(3) パラメータ適用履歴 Resource と組み合わせて「いつどの値でどのシグナルが出たか」を再現できる。evaluation.mdc の strategy 観点（内部コマンドへの変換の明確さ / API 直叩き禁止 / パラメータ適用履歴と切替の安全性）を、アルゴリズムを書く前に満たせる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`

---

## 運用と可視化

### 画面と操作

- **`/health` に市場データ鮮度と最終 tick 経過を含める** `0`
  > 現在の `Health.snapshot/1` は DB と readiness と trade_mode の 3 点。overview.md L144 は「ヘルスチェックはプロセス生存だけでなくデータ鮮度と取引所との同期を見る」としており、材料（`Cache.age_ms/2`、`Feed.status/1`）は既に揃っている。`{"market_data": {"FX_BTC_JPY": {"age_ms": 120, "fresh": true}}, "feed_connected": true}` を足すだけで、外部監視から「生きているが盲目」を検知できるようになる。healthy? の判定に含めるかどうかは分けて考えてよい（含めると WS 断でコンテナが unhealthy になる）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `apps/ui/lib/ui_web/controllers/health_controller.ex`

- **運用操作の監査ログを残す** `0`
  > halt 解除・サーキット手動オープン・モード切替といった操作は、実行されると資金リスクが直接動く。`OperationLog`（操作種別・実行者・理由・実行時刻・実行前後の状態）を 1 テーブル置き、`clear_halt` 系の入口を必ずそこに通す設計にすると、事故後に「誰がいつ再開したか」を再構成できる。UI に停止・再開ボタンを付けるより前に、記録の枠だけ決めておくと後戻りが少ない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`

### アラート設計

- **アラートの閾値と到達確認（心拍）を数値で決める** `0`
  > prod.md L52-62 は監視項目を列挙しているが、閾値は書かれていない。通知アダプタを作るタイミングで「WS 切断が N 秒続いたら通知」「未約定が M 分滞留したら通知」「N 分心拍が来なければ外部から気付く」を数値として prod.md に書くと、通知の実装が仕様に落ちる。特に **心拍（何も起きていないことの通知）** が無いと、通知経路そのものが壊れていることに気付けない。Discord Webhook への定期 heartbeat は数行で書ける。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `.workspace/1_backlog/discord-notify-adapter.md`

---

## テストと検証

- **プロパティベーステストを冪等キー・建玉マージ・Decimal 演算に導入する** `0`
  > `stream_data` は Ash の依存として既に `mix.lock` に入っており、追加インストールが要らない。効果が高そうな 3 箇所は、(1) `OrderExecutor` の同一 `internal_order_id` を任意順・任意多重で投げても `Order` が 1 行に収束すること、(2) `Positions.merge_position/4` が任意の売買列に対して「サイズが負にならない」「平均単価が正」「全決済で行が消える」を満たすこと、(3) `Risk.projected_position_size/4` が符号付き合計として交換法則を満たすこと。いずれも例示テストでは穴が残りやすい領域で、金額計算の丸め事故を早期に捕まえられる。
  > 対象ファイル: `apps/bitflyer/test/`

- **障害注入（Game Day）スクリプトを用意する** `0`
  > dev.md L67-73 は「必ず見る経路」として初回起動・強制停止からの再起動・WS 切断と再接続・上限超過・取引所エラー・重複送信の 6 つを挙げている。現状これらはユニット/統合テストでは覆われているが、**Compose 上の実プロセスで通した記録が無い**。`docker compose kill app` → 再起動 → `/health` が halted か ready かを確認、`docker compose stop db` → `/health` が 503 になることを確認、といった 5 分程度のシナリオをスクリプト化して `.workspace` に置くと、本番 CD（ToDo 03 手順 6）の受け入れ確認をそのまま流用できる。
  > 対象ファイル: `.workspace/0_doc/architecture/env/dev.md`, リポジトリルート（スクリプト不在）

---

## 実行基盤

- **再接続の backoff にジッタを入れる** `0`
  > `Feed.reconnect_delay/3`（feed.ex L315-318）は `base * 2^attempt` を `max` で頭打ちにする素直な指数バックオフ。単一ノードでは実害は小さいが、取引所側の障害復旧時に「切断された全クライアントが同じ秒数で一斉に再接続する」thundering herd に自分も参加することになり、レート制限に当たりやすい。`delay + :rand.uniform(delay div 4)` 程度のフルジッタで済む。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`

- **`mix precommit` に静的解析を段階導入する** `0`
  > 現在のゲートは format / compile / test の 3 本で、意図どおり高速（コンテナ内で約 7 秒）。この速さは維持したうえで、CI 側にだけ `credo --strict` と `dialyzer` を別ジョブとして足すと、`@spec` と behaviour が整備されている現状を活かせる。特に `Bitflyer.Exchange.Client` / `MarketData.Socket.Client` / `MarketData.Rest.Client` の 3 behaviour は、実装差し替えの契約が型で守られているかを Dialyzer が検証できる。PLT のキャッシュを効かせれば CI 時間の増加は限定的。
  > 対象ファイル: `.github/workflows/ci.yml`, `mix.exs`

- **DB バックアップと復旧手順を決める** `0`
  > prod.md L21 は「名前付きボリュームまたはホストの永続ディスク。定期バックアップ」と方針だけ書き、手順は未定義。`Order` / `Position` / `RiskState` は「再起動後に取引所の事実と突き合わせる基準」であり、これを失うと live 復帰時に全建玉が `position_missing_internal` として halt する。`pg_dump` を日次で取り、復元テストを一度通しておくこと自体が Recoverable の一部。ToDo 03 手順 3 のチェック項目に入れるのが自然。
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`, `.workspace/2_todo/03-cd-prod-host.md`

---

## プロジェクト運営

- **`.workspace` のステージ運用ルールを 1 箇所に明文化する** `0`
  > `1_backlog` / `2_todo` / `3_archive` の使い分けは実際に機能している（02 が archive へ移り 03 が todo に残っている）が、ルール自体はどこにも書かれていない。`.workspace/README.md` に「backlog は未着手の要望カタログ / todo は着手中の 1〜2 本 / archive は完了。移動時は被参照リンクを直す」の 3 行を置くと、リンク切れの再発防止と、評価サイクルでの進捗判定が安定する。前回指摘した `elixir-umbrella-phoenix-ash.md`（ステータス完了なのに backlog にある）のような曖昧さも、ルールがあれば判断できる。
  > 対象ファイル: `.workspace/`

- **評価スコアの推移を 1 枚で追えるようにする** `0`
  > 評価は日付ごとにファイルが増える構造で、個別の詳細は追えるが「どの観点がいつ改善したか」の時系列が見えない。`evaluation/score-history.md` に日付 × 大分類の加点・減点を表で積むだけで、improvement-plan の効果測定になる。今回のように 1 サイクルで P0〜P2 を消化したことが数値で残ると、次にどこへ投資するかの判断材料になる。
  > 対象ファイル: `.workspace/0_doc/evaluation/`

---

## 意図的に「今はやらない」と確認したもの

以下は Vision の非目標、または後続段階が適切と判断し、提案としても優先度を下げる。

| 項目 | 理由 |
|:---|:---|
| 複数取引所対応 | vision.md L22 の非目標。`Exchange.Client` behaviour があるので将来コストは低い |
| 高機能な裁量トレード UI | vision.md L25 の非目標。運用 UI の充実（発注可否バッジ等）とは別物 |
| Redis / 外部キャッシュ | overview.md L92「単一ノードでは Redis を置かない」。ETS で足りている |
| Umbrella の第 3 アプリ分割 | overview.md L61。現在の 2 アプリで境界は保てている |
| Kubernetes / 複数ホスト | ToDo 03 の「実装時の決めごと」で対象外と明記済み |
| 機械学習基盤 | vision.md L23 の非目標 |
