# 第1評価者（Claude Opus 5）— 提案（0点）詳細 2026-09-10

対象コミット: `490fb5a`
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) / [env/prod.md](../../architecture/env/prod.md)
前回（自系統）: [opus/archive/2026-09-09](./archive/2026-09-09/opus-specific-proposals-2026-09-09.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

提案は批判ではない。**マイナス点として計上した欠落は、ここには重複させない**（改善方針は weaknesses 側に書いてある）。ここに挙げるのは「無くても減点にならないが、あると明確に良くなる次の一手」だけである。

---

## 資金保全をさらに厚くする

- **`AuthorizedOrder` opaque 型で「risk を通った意図」を型に持たせる** `0`
  > 現状は `Risk.authorize/2` が `:ok` を返し、`OrderExecutor.submit/2` が同じ関数内で続けて dispatch する形で安全性を担保している（order_executor.ex L47-51）。公開 API から迂回できないことはテストでも固定されており、いまのままで十分機能している。そのうえで一段強くするなら、`Risk.authorize/2` の成功時に `%Bitflyer.Risk.AuthorizedOrder{}`（`@opaque`、生成関数は `Risk` 内のみ）を返し、`OrderExecutor` の live/paper/dry_run 出口がその型しか受け取らないようにする。将来 executor に別の入口（バッチ決済、緊急クローズ、UI からの手動発注）が増えたとき、「risk を通し忘れた経路」がコンパイル時に見つかる。Dialyzer を入れれば検出も自動化できる。
  > 参考: 金融系 Elixir で `Money`/`ValidatedCommand` を opaque 型にする定番パターン。

- **Kill switch（外部から即 halt できる入口）** `0`
  > いま止める手段は「コンテナを止める」か「IEx / rpc で `Risk.open_circuit/1` を叩く」しかない。BasicAuth 配下の `POST /admin/halt`（または `Bitflyer.Release.halt/1` の rpc ラッパ）を用意し、理由を添えて `Readiness.halt/1` + `RiskState` 永続化まで一撃で行えるようにすると、「怪しいから一旦止める」の心理的コストが下がる。prod.md L82-88 の「障害時の原則 1. 新規発注を止める」を、コンテナ停止より軽い手段で実行できるのは価値が大きい。既に `Circuit.open/2` があるので、薄い入口を足すだけで済む。

- **未約定注文の TTL（滞留の自動処理）** `0`
  > `Order` が `pending` / `partially_filled` のまま放置される時間に上限が無い。指値が板から遠いまま何時間も残ると、価格が動いたときに意図しない約定が起きる。`Reconciler` の定期突合（60 秒）に「`inserted_at` から N 分経過した open 注文は `OrderExecutor.cancel/2` する（または telemetry + Discord で警告する）」を足すと、prod.md L75 の監視項目「未約定注文の滞留」が監視ではなく自動処理になる。`orders_inserted_at_index` は既に存在するので（order.ex L19）、クエリコストも問題ない。

- **復旧後の段階的サイズランプ** `0`
  > prod.md L88 は「復旧後も、最初の数件は通常より厳しい上限で様子を見る」と書いているが、実装は無く運用者の記憶に依存している。`Resume.run/1` の成功時に「復帰後 N 件 / M 分は `max_order_size` を係数倍する」フラグを ETS に置き、`Limits.current/0` がそれを反映すれば、文書上の原則がコードで守られる。halt → resume の直後がいちばん状態が疑わしい時間帯なので、費用対効果が高い。

---

## 検証の厚み

- **プロパティベーステスト（StreamData）の導入** `0`
  > いまのテストは実例ベースで、意図した性質はよく押さえている（`capital_preservation_test.exs`）。次の段階として、性質そのものを検証すると質が上がる領域が 3 つある。(1) `Positions.merge_position/4` — 同方向積み増し・部分決済・ドテンをランダムな系列で回し、「size は常に非負」「平均単価は約定価格の凸結合の範囲内」を検証する。(2) `Balances.apply_fill/2` — 任意の売買列に対し「JPY 減 + BTC 増の名目金額が一致する」不変条件。(3) 冪等キー — 同じ `internal_order_id` を並行 N 本投げても `place_order` が 1 回しか呼ばれない（`SpyExchange` のカウンタで検証できる）。Decimal の丸め起因のずれは実例テストでは見つけにくい。
  > 参考: `{:stream_data, "~> 1.0", only: [:dev, :test]}`。

- **paper Game Day（障害注入の演習手順）** `0`
  > 安全装置は個別にテストされているが、「複数が同時に起きたとき運用者が何をするか」は試されていない。`TRADE_MODE=paper` の環境で、(a) DB を止める、(b) WS を切る、(c) `Exchange` スタブに 5xx を返させる、(d) 突合不整合を仕込む、を順に実行し、Discord に何が届き、StatusLive が何を出し、`mix bitflyer.resume` が何分で通るかを記録する手順書を `.workspace/0_doc/architecture/env/` に置く。これは実装ではなく演習なので、コストが低いわりに「復帰手順が本当に使えるか」が一度で分かる。live 解禁チェックリスト（prod.md L198-204）の前段に置くとよい。

- **Dialyzer / Credo の段階導入** `0`
  > `@spec` はほぼ全モジュールに書かれており、`Exchange.Client` / `Socket.Client` / `Strategy` の behaviour も揃っている。この状態なら Dialyzer の投資対効果が高い（PLT キャッシュを CI に載せれば実行時間も許容範囲）。Credo は `--strict` でなくても、`Enum.map |> Enum.reject` のような細かい指摘を拾える。どちらも `deps.audit` と同じく **ゲート外の可視化ステップ** から始めれば、CI を不安定にせずに導入できる。既に「ゲート外ステップ + artifact」の型が ci.yml にあるので、同じ形をコピーするだけで済む。

---

## 運用と観測

- **StatusLive からの `resume` / `reconcile_now` 操作** `0`
  > BasicAuth（Plug + on_mount の二層）が入ったので、UI から状態を変える操作を足す前提条件はもう満たされている。`Bitflyer.System.resume/1` と `reconcile_now/0` は既に公開されているので、halt 中だけ表示されるボタンを 2 つ置き、実行結果（成功 / 失敗理由）をフラッシュで出せばよい。`mix bitflyer.resume` は別 BEAM 問題（ETS と DB の乖離）を抱えているが、**UI からなら同一 BEAM なのでその問題自体が消える**。運用の主導線としてはこちらのほうが素直。二重押し防止と操作ログ（誰が押したかは BasicAuth のユーザー名で足りる）だけ入れる。

- **バックアップの restore 試験を自動化する** `0`
  > `bin/backup-db.sh` があり、prod.md L194 も「定期取得と **隔離環境への restore 試験** を運用に含める（バックアップの存在だけでは Recoverable と言えない）」と正しく書いている。次はこれをスクリプト化する。`bin/verify-backup.sh` が「最新のダンプを使い捨ての `postgres` コンテナへ restore → `mix ash.setup` 相当のスキーマ整合を確認 → 主要テーブルの件数を出力 → コンテナ破棄」まで行えば、月次で回すだけで Recoverable が証明できる。Vision の「いつ落ちても、永続化した状態から再開できる」に対する唯一の実証手段になる。

- **注文レイテンシと拒否率の SLO を数値で決める** `0`
  > telemetry イベントは揃っているので、次は「どの値なら異常か」を決める段階。例えば「`risk.rejected` のうち `:stale` が 5 分平均で 10% を超えたら Feed 品質の異常」「`place_order` の p99 が 2 秒を超えたら取引所側の劣化」「`market_data.tick` が 10 秒間ゼロなら配信停止」といった閾値を `.workspace/0_doc/architecture/` に 1 ページで書く。数値が決まれば、Discord 通知の条件やサーキットの追加条件を後から機械的に足せる。いまは「異常かどうか」を人の勘で判断する状態になっている。

---

## サプライチェーンと配布

- **SBOM 生成とイメージ署名（cosign）** `0`
  > CD は GHCR へ digest 固定で配布する形が整っている（cd.yml L64-80）。ここに `anchore/sbom-action` で SPDX を生成して artifact / OCI アタッチメントに付け、`sigstore/cosign-installer` + keyless 署名を足すと、「本番PC が pull したイメージが、その tag の CI が作ったものと同一である」ことを検証できるようになる。単一ホスト・個人運用なので緊急性は低いが、`docker/build-push-action` に 2 ステップ足すだけで済み、`provenance: false` を明示している現状（cd.yml L75）に対する自然な次段階でもある。

- **GitHub タグ依存の脆弱性可視化** `0`
  > README L114 が正直に書いているとおり、`mix deps.audit` は Hex advisory しか見ず、`heroicons` / `daisyui` のような GitHub タグ依存はスキャン対象外。Dependabot（`.github/dependabot.yml` に `package-ecosystem: mix` と `github-actions`）を足せば、少なくとも「タグが古いまま放置されている」ことは検知できる。あわせて `websockex` のような更新停止依存を `ci-cd.md` の「非保証」欄に列挙しておくと、次の評価者が同じ発見を繰り返さずに済む。

---

## 小計

| 分類 | 提案数 | 点数 |
|:---|---:|---:|
| 資金保全をさらに厚くする | 4 | 0 |
| 検証の厚み | 3 | 0 |
| 運用と観測 | 3 | 0 |
| サプライチェーンと配布 | 2 | 0 |
| **合計** | **12** | **0** |
