# docker-bitflyer 第2評価者 総合評価 2026-09-29

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-29 |
| 種別 | **再評価**（前回 2026-09-16） |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 基準 | `.workspace/0_doc/vision.md` / `.workspace/0_doc/architecture/overview.md` / `.cursor/rules/evaluation.mdc` |
| 対象コミット | `afc46bb`（Merge pull request #123） |
| 詳細 | [strengths](./gpt-specific-strengths-2026-09-29.md) / [weaknesses](./gpt-specific-weaknesses-2026-09-29.md) / [proposals](./gpt-specific-proposals-2026-09-29.md) |

第1評価者の `opus/` 配下は参照せず、現行ソース、テスト、証跡を直接再読した。スコアは差分だけでなく現状システム全体を積み上げ、同じ設計判断の二重計上を避けた。

## 総合スコア

| 加点 | 減点 | 純点 |
|---:|---:|---:|
| **+62** | **-5** | **+57** |

詳細ファイルの項目合計は、加点 `+62`、減点 `-5`、純点 `+57` と一致する。前回 GPT の網羅加点をそのまま踏襲せず、同一の安全設計は最も該当する観点へ一度だけ置いた。

## 観点別小計

| 観点 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 技術評価層 — apps/bitflyer | +38 | -3 | +35 |
| 技術評価層 — apps/ui | +2 | 0 | +2 |
| 技術評価層 — 実行基盤 / 設定 | +10 | 0 | +10 |
| 横断評価層 | +12 | -2 | +10 |
| **合計** | **+62** | **-5** | **+57** |

## 前回マイナスの再検証

| 前回指摘 | 現在 | 判定根拠 |
|:---|:---|:---|
| commission の売買別一次証跡 `-3` | **解決** | 実測の買い・売り差分が base 手数料式と JPY 1円 / BTC 1 satoshi 以内で一致し、旧式は許容外（`commission-unit-evidence.md:43-63`）。JPY 決め打ちと旧 quote-mark を落とす反証回帰もある（`commission_unit_guard_test.exs:20-65,69-115`）。 |
| HWM 認可後 crash 窓 `-2` | **部分改善・-2 維持** | write-behind、失敗再送、writer 単独再起動、通常停止 drain、GREATEST upsert は実装済み。しかし DB commit 前にノードが強制終了して DailyLoss / PeakWriter の両メモリが消える窓を実装自身が認める（`peak_writer.ex:3-15,38-51`）。 |
| 別ホスト監視未配備 `-2` | **未解決・-2 維持** | 証跡は同一ホスト開発 Compose、常駐未登録で、VLAN1 本番 URL は未（`watch-ready-evidence.md:10-29,73-78`）。 |
| 開発コンテナ root `-1` | **提案へ** | 本番は非 root（`Dockerfile.prod:55-69`）。開発環境だけの残差で、現時点の資金保全を直接損なわないため 0 点提案とした。 |
| Hex 外依存・image scanner 不在 `-1` | **提案へ** | CI は Hex advisory と prod image build を持つ（`ci.yml:74-153`）。OS / Git 依存 scanner は厚みであり、現時点では 0 点提案とした。 |
| 隔離 restore 証跡なし `-1` | **提案へ** | backup / restore 手順は存在する（`prod.md:402-417`）。実績追加は Recoverable を高めるが、現状のコード欠陥とは分離して 0 点とした。 |
| Fill / snapshot 保持方針なし `-1` | **提案へ** | 24/365 の容量・集約課題は残るが、現在の取引正しさを直ちに壊す証拠はないため 0 点とした。 |

前回まとめで未解決だった Game Day の停止解除副作用とハーネス共有性は解消した。Game Day は停止中に Repo だけで読み監督木を起動せず（`bitflyer.game_day_stage2.ex:60-76`）、`halted_at` 不変をテストする（`game_day_stage2_test.exs:52-73`）。ハーネスは誤った `:quote_mark` 売りを縦経路で `balance_mismatch` halt にする（`live_balance_advance_test.exs:363-408`）。

## improvement-plan 完了・部分完了の再検証

| 項目 | 主張 | 採否 | コード・証跡との突合 |
|:---|:---|:---|:---|
| P1 #4 突合窓 `fill_sync_retries` | 完了 | **採用** | mismatch 時に Fill 再同期→restore→snapshot 再取得を1回行う（`reconcile.ex:290-350`）。exchange-ahead が tip を前進し、説明不能入金は拒否する（`reconcile_test.exs:1168-1217,1267-1291`）。 |
| P1 #6 Game Day Stage 2 paper 縦経路 | コード経路完了 | **採用** | `System.submit_order/2`、Feed 断拒否、復帰後再発注、Discord probe の同一経路である（`bitflyer.game_day_stage2.ex:1-22,88-119`）。実ホスト当日実行の完了とは解釈しない。 |
| P1 #6b 永続停止を消さない | 完了 | **採用** | 起動前に Repo だけで停止を読み、halted / unsynced なら app.start しない（同 `:60-76,141-157`）。発注直前にも永続停止を再読する（同 `:240-258`）。停止中の `halted_at` 不変と boot 設定差をテストする（`game_day_stage2_test.exs:52-73,102-125`）。 |
| P2 #7 BalanceCache.probe + Runner backoff | 完了 | **採用** | Risk は probe と reserve の差を明記し（`risk.ex:34-38`）、テストは insufficient_balance 後、throttle 0 の再 tick でも `last_evaluated` が進まず注文を作らないことを固定する（`runner_test.exs:319-351`）。 |
| P2 #8 ticker spread | 完了 | **採用** | 成行だけ spread 上限を検査し、板欠落を `bid_ask_missing` で拒否する（`risk.ex:569-595`）。 |
| P2 #9 ash.codegen / Sandbox / README | 完了 | **採用** | precommit に `ash.codegen --check --domains Bitflyer.Trading` がある（`mix.exs:42-57`）。両 test helper は Sandbox `:manual`（各 `test_helper.exs:1-2`）、bitflyer README は同 gate を案内する（`apps/bitflyer/README.md:5-7`）。 |
| P0 #1 commission 一次証跡 | 完了 | **採用** | 2026-09-28 の execution id 末尾、size、price、commission、前後差分があり、売買とも見方の許容内（`commission-unit-evidence.md:43-63`）。 |
| P0 #2 ハーネス独立性 | 完了 | **採用** | 正式モデルの縦回帰と、`quote_mark` 売りが Reconciler で halt する反証が分離されている（`live_balance_advance_test.exs:241-299,363-408`）。内部式を旧式へ戻すと少なくとも実測 explain / halt 期待の一方が失敗する。 |
| P2 #7 live 成行買い ask 拘束 | 完了 | **採用（残差を別途 -1）** | live は best ask、paper は LTP + FillPricing、板欠落は拒否（`risk.ex:804-852`）。見方は満たすが、明記された板厚超過の拘束不足（同 `:821-825`）は資金保全残差として減点した。 |
| P2 #8 ticker 二層化 | 完了 | **採用** | crossed / 欠落 / ゼロ板は `book: nil`、LTP は保持し、層キーがある値は平坦値へ fallback しない（`normalize.ex:1-13,123-158,242-280`）。 |
| P2 #9 DailyEquityPeak GREATEST | 完了 | **採用** | `INSERT ... ON CONFLICT ... peak = GREATEST(...)` の一文（`daily_equity_peak.ex:81-130`）。別接続3本の競合で最高値を保持する（`daily_equity_peak_upsert_test.exs:14-63`）。 |
| P1 #3 HWM crash 窓 | 部分完了 | **部分完了のまま採用** | writer 不在時の同期 fallback、失敗再送、writer 再起動、通常停止 drain は確認。ノード強制終了で両メモリが消える窓が残るため完了へ昇格させず `-2`。 |
| P2 #10 完了宣言ルール | 部分完了 | **部分完了のまま採用** | evaluation rule と improvement-plan に根拠行・見方・次回矛盾検査が定義され、今回コード再読で検査した。今回、完了宣言を却下すべき矛盾は見つからなかったため、この評価が次回確認の初回実績になる。 |

**完了宣言の却下: なし。**  
ただし P1 #3 と P2 #10 は元から部分完了であり、完了へは昇格させない。P2 #7 の完了範囲は best ask 拘束までで、板厚超過残差の解消を意味しない。

## 主な強み

1. live 起動突合が権限・時計・Fill・残高・spot 在庫・未約定を同じ fail-closed シーケンスへまとめ、取引所先行 / 内部先行の双方を限定再試行で救済する。
2. raw command が Executor へ入れず、opaque なワンショット認可トークンと内部 ID 冪等性で Risk 迂回・二重送信を構造的に防ぐ。
3. commission を実測一次証跡、会計式、在庫、反証ハーネスまで結び、前回最大のモデル不確実性を閉じた。
4. WS ACK、再接続、silent stall、LTP / book 二層、鮮度・時計・spread の責務分離が明確である。
5. shutdown は新規発注を先に閉じ、in-flight と HWM を drain し、不明結果を success / failure に推測しない。

## live 解禁可否

**不可。**

P0 commission とハーネス独立性は解消したが、次が残る。

1. VLAN1 本番 PC の `/health/ready` を別ホストから常駐監視した証跡がない。
2. HWM は認可復帰前の durable commit を保証せず、ノード強制終了窓が残る。
3. live 成行買いは最良 ask 超過の板歩き分を内部拘束しない。

少なくとも 1 は live 解禁の運用ブロッカー、2 は連続 live の資金保全ブロッカーである。3 は深さ取得または保守的 buffer と同時に閉じるべきである。

## 実行検証

| 項目 | 結果 |
|:---|:---|
| `git rev-parse --short HEAD` | `afc46bb` を確認 |
| CI 定義の静的確認 | PostgreSQL service 上で `mix precommit`、別 job で `mix deps.audit` と `Dockerfile.prod` build を実行する定義を確認（`.github/workflows/ci.yml:16-153`） |
| `mix precommit` | **未実行**。親評価者が品質ゲートを実行中であり、`_build` を競合させない指示に従った |
| `mix test` / Docker Compose | **未実行**（同上） |

本評価はコード・既存テスト・証跡の静的再読による。親の品質ゲート結果が失敗した場合、このスコアとは別に再評価が必要である。

## 現状の一文

**取引所事実との突合、実測手数料、モード隔離、二重発注防止、停止時 drain はプロダクション候補水準に達したが、ホスト外監視と HWM の強制終了耐性が未完のため、まだ「人が張り付かず安全に live 連続運転できる」状態ではない。**

## 優先して直す順

1. **VLAN1 別ホスト監視を常駐配備**し、取引ホスト停止、3 strikes、通知到達、監視 PC 再起動後の復帰を証跡化する。
2. **HWM の認可復帰前 durable 化**を行い、認可直後のノード強制終了でも DB または外部 WAL に最高値が残る回帰を追加する。
3. **live 成行買いの板厚超過拘束**を深さ付き板または保守的 slippage buffer で閉じる。
4. 隔離 restore、release image scanner、Prometheus / SLO を運用ゲートへ追加する。
5. retention / aggregate と property-based test を追加し、24/365 のデータ量と操作列を検証する。
