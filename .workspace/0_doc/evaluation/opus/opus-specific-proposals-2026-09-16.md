# 第1評価者（Claude Opus 5）— 提案（0点）詳細 2026-09-16

対象コミット: `a387746`（`Merge pull request #112 from FRICK-ELDY/chore/p2-9-minor-debt-triad`）
基準: [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md)
前回（自系統）: [opus/archive/2026-09-13](./archive/2026-09-13/opus-specific-proposals-2026-09-13.md)

第2評価者（GPT）の当日文書および `gpt/` 配下は参照していない。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

減点ではない。「次のステップ」として記録する。並びは資金保全への近さ順。

---

## live 解禁に向けた運用プロトコル

- **live Stage 3 を「買い 1 本で単位を確定 → 売りを解禁」の 2 段に割る** `0`
  > weaknesses の `-2`（commission 単位が推定）を、コードを増やさずに閉じる案である。現在の Stage 3 は「spot 最小ロット 1 発注→取消」だが、取消では手数料が発生しないため単位の確定にならない。
  >
  > 提案する分割:
  >
  > | Stage | 内容 | 記録すること |
  > |:---|:---|:---|
  > | 3a | 最小ロットの**買い成行 1 回**（保有したまま終了） | `getexecutions` の `commission` 値、直前直後の `getbalance` の JPY / BTC、`LiveBalance.explain` の `expected` / `unexplained` |
  > | 3b | 3a の証跡で単位が一致したあと、**同数量の売り 1 回** | 同上。base が `−S` か `−S−C` か、quote が `+S·P−C·P` か `+S·P` か |
  >
  > 3a の直後に `mix bitflyer.reconcile`（または Status の突合）を回し、`balance_mismatch` が出ないことを見る。出たら `unexplained` の符号と通貨がそのまま「どちらのモデルか」の答えになる。金額は最小ロット（0.001 BTC 相当）で、手数料は数円である。**数円で 5 割の推定が消える**。
  >
  > 併せて、3b が終わるまでは戦略側で売りを出さない運用（`Risk` に一時的な `live_sell_enabled?` を置くか、単に買い持ちのみの戦略で始める）にすれば、halt 事故そのものを避けられる。
  > 対象: `.workspace/0_doc/architecture/env/game-day.md`, `.workspace/0_doc/architecture/env/commission-unit-evidence.md`

- **手数料モデルを「設定で切り替えられる仮説」として持ち、観測で確定する** `0`
  > 上記より一段コードを足す案。`Fill.fee_currency` は既にあるので、足りないのは**売り時に fee をどちらの通貨残高から引くか**という 1 ビットである。
  >
  > ```elixir
  > # 案: Bitflyer.Trading.Product
  > @spec sell_fee_side(String.t()) :: :base_deduct | :quote_mark
  > def sell_fee_side(product_code), do: fee_side_env(product_code) || :quote_mark
  > ```
  >
  > `LiveBalance.fill_delta/2` の売り分岐と `Positions.held_size(:sell, ...)` がこの 1 関数を見るようにし、`LiveExchangeHarness` にも同じスイッチを持たせて**両モデルで縦回帰を回す**。観測で確定したら既定値を固定し、証跡に日付付きで書く。
  >
  > 副産物として、`ETH_BTC` のように quote が暗号資産のペアを増やすときの実験コストが下がる（`fee_currency` は現在 spot 全部を base に倒しており、moduledoc 自身が「ペア別の非ゼロ execution 証跡が無い間は base に倒す」と保留している）。
  > 対象: `apps/bitflyer/lib/bitflyer/trading/product.ex`, `apps/bitflyer/lib/bitflyer/startup/live_balance.ex`, `apps/bitflyer/test/support/live_exchange_harness.ex`

---

## risk-manager / 会計

- **HWM の upsert を AshPostgres の `GREATEST` 1 文に畳む** `0`
  > weaknesses の `-1`（`inspect` 文字列一致）の根治案。`DailyEquityPeak.do_upsert/4` は read → create → rescue → 条件付き `bulk_update` の 4 段だが、HWM は単調増加なので DB 述語で完全に表現できる。
  >
  > ```sql
  > INSERT INTO daily_equity_peaks (id, trade_mode, trading_day, peak, inserted_at, updated_at)
  > VALUES ($1, $2, $3, $4, now(), now())
  > ON CONFLICT (trade_mode, trading_day)
  > DO UPDATE SET peak = GREATEST(excluded.peak, daily_equity_peaks.peak), updated_at = now();
  > ```
  >
  > `Ash.Changeset.for_create(..., upsert?: true, upsert_identity: :unique_mode_day)` は既に `Circuit` で使われている（circuit.ex L155-156）ので、リポジトリ内に前例がある。`GREATEST` を Ash の宣言で書けない場合でも、`AshPostgres` の `upsert_fields` + 条件付き `atomic_update` で近い形になる。**エラー文字列の分類コード 40 行がまるごと消える**のが価値である。
  > 対象: `apps/bitflyer/lib/bitflyer/trading/daily_equity_peak.ex`

- **`sum_realized/3` を `Ash.aggregate(:sum)` にし、保持方針を prod.md に書く** `0`
  > 前回まで減点として扱っていたが、`sum_realized/3` は `filled_at` の当日境界で絞られており「全行読み」ではないため、今回は提案へ移した。それでも当日分の Fill 行を BEAM に運んで `Enum.reduce` するのは無駄で、live は execution 単位なので行数は paper より増える。
  >
  > ```elixir
  > # 現状: apps/bitflyer/lib/bitflyer/risk/daily_loss.ex L761-768
  > {:ok, fills} -> net = Enum.reduce(fills, Decimal.new(0), fn fill, acc -> ... end)
  > ```
  >
  > `Ash.Query.aggregate(:realized_sum, :sum, :realized_pnl)` か生 SQL の `SUM` に変えれば、`Reconciler` が 60 秒ごとに 3 モードぶん回す読取が定数サイズになる。あわせて `prod.md` に保持方針（例: `fills` 2 年 / `balance_snapshots` 90 日で日次ロールアップ、または「当面剪定しない。判断閾値は行数 N / サイズ M」）を 5 行書く。**「ETS は消えても再構築できる / DB は無限に育つ」の非対称が文書に無い**状態を閉じる。
  > 対象: `apps/bitflyer/lib/bitflyer/risk/daily_loss.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **成行の拘束を `best_ask` / `best_bid` 基準にする** `0`
  > weaknesses の `-1` の直し方をここに具体化する。`Risk.quote_notional/2` の成行分岐で、live の買いは `best_ask`、paper は現状の不利化 LTP を維持する（paper は fee を価格に載せる設計なので二重に不利化しない）。売りは base 数量拘束なので変更不要。
  >
  > `fetch_bid_ask/2` は既にあるので（risk.ex L830-844）、`base_unit_price/4` に `:market` 用の分岐を 1 本足すだけである。副産物として、成行の想定コストが `AuthorizedOrder` に載れば、後から「認可時の想定 vs 実約定」の乖離を telemetry で追える。
  > 対象: `apps/bitflyer/lib/bitflyer/risk.ex`

---

## market-data

- **ticker の値を `{ltp, book}` の 2 層にし、板の欠落と鮮度切れを分ける** `0`
  > weaknesses の `-1`（板異常が鮮度に化ける）の直し方。`Normalize.from_ticker/1` は `ltp` と `source_timestamp` だけを必須にし、bid/ask は nil を許して Cache に載せる。`Risk.check_spread/3` は nil を `bid_ask_missing` で拒否（既にその reason がある）、`check_freshness` / `check_price_deviation` / `Equity` の mark は生き残る。
  >
  > 加えて telemetry に `ticker_book_invalid` を 1 本足せば、「板が壊れて成行が止まった」と「配信が止まった」を Status とログで区別できる。overview の Observable に対して、**停止理由の解像度**が上がる。
  > 対象: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`

- **`lightning_executions_*` を購読し、paper の約定に厚みを与える** `0`
  > 前回から継続。`Paper.decide_fill/3` は板の厚みを見ないため、大口の部分約定・不成立を paper で再現できない。直近約定列を `Cache` に置き、paper の約定サイズを出来高で頭打ちにすれば、「ペーパーで本番と同経路を検証できているか」という評価軸が一段上がる。
  >
  > `Socket.Client` behaviour と購読 ACK の仕組みが既にあるので、チャンネルを 1 本増やす形で入る。
  > 対象: `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`

- **`websockex` を `Mint.WebSocket` か `Fresh` へ差し替える** `0`
  > 記録を残すこと自体は weaknesses の `-1` に含めたので、ここでは移行そのものを提案として置く。`Socket.Client` behaviour と `Socket.Local`（テスト用）の分離が済んでいるため、差し替えの影響範囲は `socket.ex` 60 行と ws 系テストに限られる。OTP 27 の TLS 既定変更に自力で追随できるようになると、24/365 の前提が 1 つ強くなる。
  > 対象: `apps/bitflyer/lib/bitflyer/market_data/socket.ex`, `apps/bitflyer/mix.exs`

---

## 運用・可観測性

- **`RiskState` をモード別にするか、グローバル 1 行である理由を文書化する** `0`
  > weaknesses の `-2`（診断タスクが停止理由を消す）の構造側の対処。`RiskState` は `name == "default"` の単一行で `trade_mode` を持たない。この設計判断（「停止は全モード共通」）は妥当でありうるが、**overview / architecture のどこにも書かれていない**。
  >
  > 選択肢は 2 つ。(a) 現状維持＋文書化（「halt は取引所接続そのものへの停止であり、モードを跨ぐ」と明記し、診断タスクは clear を禁止する）。(b) `RiskState` に `trade_mode` を足し、`name` を `{trade_mode, "default"}` 相当にする（マイグレーションと `CircuitSync` の変更を伴う）。どちらでもよいが、**書かれていない前提の上に診断タスクが乗っている**現状は解消したい。
  > 対象: `.workspace/0_doc/architecture/overview.md`, `apps/bitflyer/lib/bitflyer/trading/risk_state.ex`, `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

- **Game Day Stage 2 を `mark_ready` 抜きで通す** `0`
  > 現在のタスクは各ステップで `Readiness.mark_ready()` を押しているため、本番の Ready 遷移を検証していない。`Reconciler.run_now()` の結果が `:ready` になることを要求し、ならなければ失敗として記録する形に変えれば、**「復帰したら自動で Ready になる」という 24/365 の中核**がドリルで確認できるようになる。
  >
  > seed 段は既に `mark_ready` の push-through を拒否しているので（game_day_stage2.ex L107-111）、その判定をそのまま feed 復帰後にも適用すればよい。
  > 対象: `apps/bitflyer/lib/mix/tasks/bitflyer.game_day_stage2.ex`

- **操作監査を「単一 Basic 認証アカウント」から一段進める** `0`
  > 現状の `ops_operator` は Basic 認証のユーザー名を session 経由で伝播しており（`UiWeb.Hooks.BasicAuth.session_username/1`）、prod では Basic 認証が必須（runtime.exs L284-295）なので `anonymous` にはならない。設計は正しい。
  >
  > 残るのは「アカウントが 1 個しかない」点で、停止・再開という最も重い操作を**誰が**行ったかはアカウント粒度でしか残らない。単一運用者の段階では実害がないため提案に留める。将来複数人で運用するなら、Basic 認証を複数ユーザー対応にする（または最小の認証層に差し替える）だけで監査線が繋がる。
  > 対象: `apps/ui/lib/ui_web/hooks/basic_auth.ex`, `config/runtime.exs`

- **Prometheus / SLO とホスト exporter の別ホスト scrape** `0`
  > 前回から継続（improvement-plan P3 #11）。現在の観測はログと Discord と `/ops/dashboard` で、**率と推移がホスト外に残らない**。`/health/ready` の pull 監視（P1 #5）が入ったら、その隣に `windows_exporter` の scrape を足すのが自然な順序である。SLO は「Ready 率」「突合成功率」「認可拒否率の内訳」の 3 本で足りる。
  > 対象: `.workspace/0_doc/architecture/env/prod.md`

---

## テスト戦略 / 品質ゲート

- **金額・数量・冪等キーにプロパティベーステストを入れる** `0`
  > 前回から継続。今サイクルで `held_size` / `fee_to_quote` / `fill_delta` / `spread_pct` という**小さくて純粋な算術関数**が増えたので、`StreamData` の投入先として理想的な形になった。
  >
  > 検査したい不変条件の例:
  >
  > - 買い → 同量売りの往復で、`Position` は 0 か `fee` ぶんの残短のみ（inventory 基準の一貫性）
  > - `fill_delta` の buy/sell を足すと、base と quote の変化が `notional` と `fee` だけで表せる
  > - `fee_to_quote(fee, base_ccy, ...) / fill_price == fee`（丸め方向の一貫性）
  > - `spread_pct(bid, ask) >= 0` かつ `bid == ask` で 0
  >
  > 手数料会計は本サイクルの最重要変更なので、ここに 1 ファイル足す価値は高い。
  > 対象: `apps/bitflyer/test/bitflyer/order_executor/positions_test.exs`, `apps/bitflyer/test/bitflyer/startup/live_balance_test.exs`

- **Hex 外 scanner（Trivy 等）を release image と lock に当てる** `0`
  > 前回から継続（improvement-plan P3 #12）。`mix deps.audit` は Hex advisory しか見ないため、ベースイメージ（`elixir:1.18.3-otp-27-slim`）の OS パッケージと GitHub tag 依存はゲートに入っていない。`Dockerfile.prod` の成果物に Trivy を当て、high の例外に期限を付ける運用を書けば、Least privilege と並ぶセキュリティ側の基礎が揃う。
  > 対象: `.github/workflows/`, `.workspace/0_doc/architecture/ci-cd.md`

- **開発 `Dockerfile` の非 root 化** `0`
  > weaknesses に `-1` で計上済みだが、実装イメージをここに置く。uid/gid 1000 のユーザーを作り、`mix_deps` / `mix_build` の名前付きボリュームの所有者を `bin/docker-entrypoint.sh` で合わせる（または compose に `user: "1000:1000"`）。WSL2 ホストでの日常的な摩擦（root 所有の生成物）が消える。
  > 対象: `Dockerfile`, `compose.yaml`, `bin/docker-entrypoint.sh`

---

## 意図的に後回し（今サイクルも提案に留める）

- 戦略アルゴリズムの高度化、パラメータ canary、二者承認
- private execution WS、API レート予算、起動時 `getpositions` 空検査
- SBOM / 署名、複数取引所、ML 基盤、FX 証拠金（`getcollateral`）
- 裁量向け UI（Vision の非目標）
