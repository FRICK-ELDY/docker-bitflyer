# 改善提案書（improvement-plan）

最終更新: 2026-09-29（P1 #5 の完了条件を、作業PCへの登録から専用監視PCの準備と検知記録へ改めた。監視PCは未用意）
根拠: [evaluation-2026-09-29.md](./evaluation-2026-09-29.md) / [specific-weaknesses-2026-09-29.md](./specific-weaknesses-2026-09-29.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** 連続 live の前に残るハード条件は P1 #5（別ホスト監視）である。戦略の高度化はその後。

**完了宣言ルール:** 「完了」と書くときは、右列「完了の見方」を満たした根拠を 1 行必須にする。根拠は日付と、見方が真だと分かる観測（テスト名、証跡の差分、実行結果）を含む。「コード再読」だけでは根拠にしない。満たせない項目は取り消し線にせず **部分完了** と残す。見方を下げるときは、先に右列を書き換える。次回評価は根拠行と見方の矛盾を、コードまたは証跡の再読で落とす（手順は `.cursor/rules/evaluation.mdc` の「improvement-plan の完了宣言」）。

---

## 消化済み（2026-09-29 の再読で維持）

| # | 項目 | 状態 |
|:---:|:---|:---|
| — | tip 前進骨格・ゼロ手数料ハーネス（旧 P0） | 部品として維持 |
| — | Feed 認可・spot 在庫・ACK・有限 open age・ページング | 維持 |
| P1 #4 | 突合窓の対称化（`fill_sync_retries`） | **完了**（2026-09-16。`reconcile_test` の exchange-ahead は fill 再同期 1 回で `{:ok}` と tip 前進。再同期後も説明できない入金は `balance_mismatch`。2026-09-29 再読で見方との矛盾なし） |
| P1 #6 | Game Day Stage 2 の paper 縦経路 | **コード経路は完了**（2026-09-16。`bitflyer.game_day_stage2` は paper の `System.submit_order/2` で建玉を作り、Feed 断は `feed_disconnected`。2026-09-29 再読で見方との矛盾なし） |
| P1 #6b | Game Day の停止解除副作用 | **完了**（2026-09-28。paper の中断は Repo だけで読み、監督木は起動しない。既存停止の `halted_at` は変えない。`boot?: true` の起動突合だけが `halted_at` を更新する。2026-09-29 再読で見方との矛盾なし） |
| P2 #7（2026-09-16） | BalanceCache.probe + Runner backoff | **完了**（2026-09-16。`runner_test` は `insufficient_balance` のあと、throttle 0 の再 tick でも `last_evaluated` を進めず注文を作らない。2026-09-29 再読で見方との矛盾なし） |
| P2 #8 | ticker bid/ask → spread ゲート | **完了**（2026-09-16。`risk_test` は spread 4%・上限 0.5% の成行を `max_spread_pct` で拒否する。2026-09-29 再読で見方との矛盾なし） |
| P2 #9（ash.codegen） | ash.codegen --check / Sandbox manual / README | **完了**（2026-09-16。precommit に `ash.codegen --check --domains Bitflyer.Trading`。両 `test_helper.exs` は Sandbox `:manual`。2026-09-29 再読で見方との矛盾なし） |
| P2 #10 | improvement-plan 運用 | **完了**（2026-09-29。完了主張 11 件をコードまたは証跡と突き合わせ、見方と矛盾して却下した項目は 0。記録は [evaluation-2026-09-29.md](./evaluation-2026-09-29.md) の採否表） |
| P0 #1 | commission 一次証跡 | **完了**（2026-09-28。買い …6098 / 売り …6123 の実差分が更新後 expected と JPY 1 円・BTC 1 satoshi 以内。2026-09-29 再読で見方との矛盾なし。適用範囲は BTC_JPY。他銘柄は P2 #16） |
| P0 #2 | ハーネス独立性 | **完了**（2026-09-28。`:quote_mark` の売りは発注→約定同期→Reconciler で `balance_mismatch` halt。既定の縦回帰は Ready。2026-09-29 再読で見方との矛盾なし） |
| P2 #7（2026-09-28） | 成行拘束の ask 化 | **完了**（2026-09-28。live 成行買いの probe/reserve は `best_ask × size` ちょうど。ask 欠落は `bid_ask_missing`。最上段を超える超過は未拘束のまま。見方（ask 拘束）は満たす。超過は P2 #19） |
| P2 #8 | ticker 2 層化 | **完了**（2026-09-28。crossed / 欠落 / ゼロの板は `book: nil` のまま LTP を Cache に載せる。成行認可は `bid_ask_missing`。2026-09-29 再読で見方との矛盾なし） |
| P2 #9（2026-09-29） | DailyEquityPeak の GREATEST upsert | **完了**（2026-09-29。`upsert/3` は `INSERT ... ON CONFLICT DO UPDATE SET peak = GREATEST(...)` の 1 文。別接続 3 本で保存 peak は最高値。2026-09-29 再読で見方との矛盾なし） |

**「済」＝ live 解禁ではない。**

---

## P0 — live 解禁の前に塞ぐ穴

P0 に未完了は無い。前回まで P0 だった commission とハーネスは上表のとおり完了。

---

## P1 — 停止からの出口と安全装置

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 3 | HWM 認可後 crash 窓 | **部分完了 (2026-09-29 維持)。** writer 不在は認可しない。upsert 失敗は再送する。通常停止の drain と fsync 印は入った。残るのはノード強制終了で DailyLoss と PeakWriter の両メモリが消える窓（`peak_writer.ex` が明記。重みは `-1`） | 認可直後の強制終了でも DB 高値が残るテストがある |
| 5 | 専用監視PCからの実配備 | **未着手。** 監視は作業用PCに載せない。開発・移動・再起動がある作業PCは 24/365 の探針にならない。専用の監視PCを一台用意し、そのPCだけが VLAN1 本番の `/health/ready` を常駐で引く。2026-09-29 時点ではそのPCは未用意。2026-09-13 の記録は作業PC上の開発 Compose に対する手順確認であり、配備には数えない。証跡は [watch-ready-evidence.md](../architecture/env/watch-ready-evidence.md) | 専用監視PC（本番PCでも作業用PCでもない）から、取引ホストの停止を検知した記録がある。作業用PCへの Scheduled Task 登録だけでは完了にしない |

---

## P2 — 観測と自己修復の残差

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 16 | live 銘柄を一次証跡へ合わせる | `Risk` と `LiveSafety` が `Product.spot?/1` 全体ではなく、証跡のある銘柄（当面 `BTC_JPY`）だけを live で通す。他ペアは実測表を足してから集合に入れる | `ETH_JPY` を live の product_codes にすると起動または認可不通過になるテストがある |
| 17 | `halted_at` を起点のまま残す | 既に halted かつ同一 reason の再突合では `halted_at` を更新しない | 周期失敗の 2 回目で `halted_at` が変わらないテストがある |
| 18 | PeakWriter の再試行間隔 | 50ms 固定を上限付きの退避にし、同一失敗の error ログは初回と間引きだけにする | DB 失敗が続くテストで再試行間隔が延び、同じ error が連続しない |
| 19 | 成行買いの板厚超過 | 深さ付き板か、保守的な余白を best ask の拘束に足す。P2 #7 の ask 拘束は完了のまま、この残差だけを閉じる | 最上段数量を超えるサイズで、拘束額が ask×size より大きい回帰がある |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | データ保持方針 | fills/snapshots の retention または「当面なし」の文書化 + `sum_realized` の DB aggregate | 24/365 で表肥大の判断基準がある |
| 12 | Prometheus / SLO | 時系列蓄積、カーディナリティ抑制 | 率・推移がホスト外で追える |
| 13 | Hex 外 scanner | release image / lock の Trivy 等。high の例外期限 | GitHub tag と OS がゲートに入る |
| 14 | 隔離 restore 証跡 | backup hash → 空 DB → migration → boot/reconcile を記録 | Recoverable が手順だけでなく成功記録になる |
| 15 | 残る軽微 | 開発 Dockerfile の USER、websockex の採用理由 1 行 | 開発生成物が root 所有にならない、または採用理由が architecture にある |

HWM の強制終了窓を同期 upsert で閉じるか、prod.md に残差として固定するかは P1 #3 の見方を満たす作業であり、P3 ではない。

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ canary（live で FixedOnce は拒否済み。解禁後に薄い 1 本）
- 板の本格購読・プロパティテストの本格導入
- private execution WS、API レート予算、起動時 `getpositions` 空検査
- SBOM / 署名、裁量向け UI、複数取引所、ML 基盤、FX 証拠金（backlog）

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |
| FX 証拠金 | `.workspace/1_backlog/fx-collateral-adapter.md`（live は spot 限定で先行済み） |
| 本番 CD | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |
| Game Day | [game-day.md](../architecture/env/game-day.md) |

次回評価では、本計画の **P1 #5** が証跡上で解決済みかを再読で確認する。P1 #5 未完了のまま live 実発注を進めた場合は重大減点とする。
