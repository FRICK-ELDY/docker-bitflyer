# docker-bitflyer 第2評価者 総合評価レポート 2026-09-10

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10 |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 基準 | `.workspace/0_doc/vision.md` / `.workspace/0_doc/architecture/overview.md` |
| 前回まとめ | `.workspace/0_doc/evaluation/archive/2026-09-09/evaluation-2026-09-09.md` |
| 詳細 | `gpt-specific-strengths-2026-09-10.md` / `gpt-specific-weaknesses-2026-09-10.md` / `gpt-specific-proposals-2026-09-10.md` |

相手評価者の当日文書および `.workspace/0_doc/evaluation/opus/` 配下は参照せず、現行コードとテストを直接再検証した。

## 総合スコア

| 加点合計 | 減点合計 | 純点 |
|---:|---:|---:|
| **+49** | **-45** | **+4** |

前回まとめ純点は **+7**。今回は機能実装量だけなら明確に前進したが、P0 #5 未完了のまま live client が差し込まれ、さらに live 建玉突合の誤 Ready 可能性が見つかったため、純点は **+7 → +4（-3）** とした。これは退歩というより、`Unavailable` が隠していた実弾経路の欠陥が評価対象として顕在化した結果である。

## 主要結論

1. **P0 #1〜#4 は解決した。** submission unknown、受注 ID 永続化失敗、残高 baseline、risk 迂回は fail-closed コードと回帰テストがある。
2. **P0 #5 は未解決であり、live 解禁不可。** `max_daily_loss` は未注入時常に0、残高は未注入・必要通貨欠落を許容する。比較関数の存在を「完成」と評価できない。
3. **live 建玉突合に重大な誤 Ready リスクがある。** 取引所の同一銘柄 buy/sell を product_code key の Map にすると片側が上書きされる。
4. **private REST・約定・取消・paper・strategy・shutdown・resume・Discord・Status・認証・release/CD まで一気に実装され、骨格から運用候補へ大きく前進した。**
5. **本番既定が危険である。** Strategy.FixedOnce は全環境で有効、live 専用上限もなく、Ready 後の最初の ticker で0.01 BTCの成行買い意図を出す。
6. **市場データの source age、時計ずれ、API 権限、進行中 submission drain が未完成で、Vision の Safety / Recoverable / Observable を実弾水準では満たさない。**

## P0 判定

### 1. submission 不明の安全化 — 解決済み

`Live.handle_place_error/2` は確定拒否以外を `submission_unknown` に更新し、`Risk.open_circuit(:submission_unknown)` で Readiness と RiskState を halt する（`apps/bitflyer/lib/bitflyer/order_executor/live.ex:130-147`）。timeout・disconnect 後に後続 REST が増えないテストもある（`apps/bitflyer/test/bitflyer/order_executor_test.exs:376-440`）。

### 2. 受注後 ID 永続化失敗時の halt — 解決済み

`exchange_order_id` 更新失敗時に critical ログと `open_circuit_or_log!(:persist_failed, ...)` を実行する（`apps/bitflyer/lib/bitflyer/order_executor/live.ex:45-85`）。同一・別 internal ID の後続 submit を止める回帰テストがある（`order_executor_test.exs:477-530`）。

### 3. 残高 baseline — 解決済み（安全停止）

live の必須通貨は既定 JPY/BTC。内部 baseline 欠落を `balance_baseline_missing` とし、空リストで成功しない（`apps/bitflyer/lib/bitflyer/startup/reconcile.ex:244-279`, `config/config.exs:21-23`）。ただし正式な初回 import 手段はなく、運用完成度の別減点とした。

### 4. risk 迂回 `authorize?: false` 廃止 — 解決済み

公開 `OrderExecutor.submit/2` は無条件で `Risk.authorize/2` を呼ぶ（`apps/bitflyer/lib/bitflyer/order_executor.ex:43-60`）。旧オプションを渡しても not_ready で拒否される（`order_executor_test.exs:548-566`）。

### 5. risk limits 完成 — 未解決

価格逸脱と頻度の比較、日次損失と残高の比較関数・テストは追加された。しかし本番 submit では daily loss が注入されず、未注入時 `0` とする（`apps/bitflyer/lib/bitflyer/risk.ex:410-428`）。balances 未注入時は空として検査をスキップし、必要通貨欠落も成功する（`risk.ex:272-280, 291-336, 431-436`）。発注頻度 ETS も再起動で0へ戻る。したがって P0 の完了条件「risk limits 完成（+残高）」は満たさない。

## 前回からの変化

### 解決済み

- **strategy の骨**: Behaviour / FixedOnce / Runner が追加され、Feed tick から `System.submit_order` まで接続された（`strategy/runner.ex:145-189, 302-335`）。
- **graceful shutdown の受付停止**: `Application.prep_stop/1` と `stop_grace_period: 45s` が追加された（`application.ex:44-67`, `compose.prod.yaml:50-53`）。
- **resume**: 再突合成功時のみ Circuit を閉じる `Startup.Resume`、Mix task、release RPC が追加された（`startup/resume.ex:22-89`）。
- **paper 残高・指値**: LTP交差、Order/Position/Balanceの同一 transaction、advisory lock が実装された（`order_executor/paper.ex:16-67`, `order_executor/balances.ex:24-81`）。
- **Discord**: halt / mismatch / disconnect を非同期通知し、未設定・失敗で発注を止めない（`observe/discord.ex:252-291`）。
- **StatusLive**: 発注可否、Feed、鮮度、モード色分けを表示する（`apps/ui/lib/ui_web/live/status_live.ex:69-210`）。
- **health 分離**: `/health/live` と `/health/ready` を分離し、ready に Feed と stale を含めた（`health.ex:218-228`, `router.ex:20-28`）。
- **telemetry allowlist**: `:kind` / `:currency` / `:limit` が追加済み（`telemetry.ex:37-55`）。
- **README 同期**: private API、本番 release、認証、CD 等を現状表へ反映した。ただし risk 完成表記は過大。
- **UI 認証・bind**: prod BasicAuth 必須、LiveView session 再検査、ホスト loopback 公開が実装された（`runtime.exs:170-210`, `compose.prod.yaml:47-50`）。
- **API キー枠**: live で key/secret 欠落時に起動停止し、他モードは Unavailable のまま（`runtime.exs:111-157`）。
- **本番 release/CD**: multi-stage非root release、GHCR、digest、backup/rollback が追加された。
- **Exchange.Rest**: 署名付き発注、取消、残高・建玉・注文・約定照会と fixture test が追加された。
- **deps audit**: `mix_audit` と CI artifact 可視化が追加された。

### 未解決・新たに顕在化

- **risk の実データ接続**: daily loss と balance が本番認可へ渡らない。
- **建玉突合の両建て欠落**: external list を product_code key の Map にして片側を上書きする。
- **初回 baseline import**: 欠落時 halt は正しいが、安全に baseline を作る操作がない。
- **submission unknown / ID喪失の回収**: 停止はするが acceptance ID の候補照合がない。
- **market source age / channel / ACK / clock skew**: 到着時刻だけが鮮度の正本。
- **strategy parameter history**: revision と注文への由来記録がない。
- **shutdown drain**: 受付停止のみで、進行中 HTTP/DB を完了させる coordinator がない。
- **API permission 検査**: 出金禁止は文書だけで `getpermissions` を検証しない。
- **外部監視**: Discord の retry/heartbeat、ホスト・NTP・ディスク監視がない。

## P1〜P3 判定要約

| 計画項目 | 判定 | 根拠・留保 |
|:---|:---:|:---|
| P1 strategy | 解決 | Runner まで縦貫通。ただし revision 欠落、live 既定有効は危険 |
| P1 graceful shutdown | 部分解決 | 新規受付停止あり。in-flight drain なし |
| P1 resume | 解決 | 再突合成功時のみ解除。release RPC 手順あり |
| P1 paper | 解決 | 残高・limit交差・transactionあり。部分約定等は後続 |
| P2 Discord | 解決 | 非同期・失敗非阻害。retry/heartbeatは未実装 |
| P2 StatusLive | 解決 | gate/Feed/鮮度表示あり。ただし gate判定がFeedを直接見ない |
| P2 health | 解決 | live/ready分離、readyにFeed/stale |
| P2 telemetry | 解決 | allowlist追加 |
| P2 README | 部分解決 | 現状表あり。riskを過大表示 |
| P3 UI認証 | 解決 | prod必須BasicAuth + session hook + loopback |
| P3 APIキー | 部分解決 | 欠落停止・文書化あり。permissions検査なし |
| P3 release/CD | 解決 | release、GHCR、digest、backup/rollback。ただしCDはCI成功を強制しない |
| P3 Exchange.Rest | 実装済みだが live不可 | 発注・取消・照会・fillあり。P0 #5と建玉突合欠陥が残る |
| P3 deps audit | 解決 | CI可視化 + ローカル監査成功 |

## 実行検証結果

| コマンド / 確認 | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功（親実行済み）**: bitflyer 1 doctest + 187 tests、ui 23 tests、0 failures、exit 0 |
| `docker compose config --quiet` | **成功**、exit 0 |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**、exit 0 |
| `docker compose run --rm app mix deps.audit` | **成功**、`No vulnerabilities found.`、exit 0 |
| コード再読 | P0〜P3、market-data、strategy、risk、executor、Ash、ETS、observe、OTP、UI、Docker/config、CI/CD を現行ソース・テストで確認 |

注: `mix deps.audit` は Hex advisory の現時点結果であり、GitHub tag 依存、将来の advisory、実 API 契約を保証しない。

## 優先改善リスト

1. **live を再び明示禁止し、P0 #5を本物の実データへ接続する**  
   実現損益・未実現損益・残高 snapshot を認可時の必須入力にし、取得不能・通貨欠落は fail-closed。README を partial に戻す。
2. **建玉突合の両建て上書きを修正する**  
   外部 buy/sell を内部のネット建玉モデルへ正規化し、順序反転 fixture を含む回帰を追加する。
3. **live 既定を no-op/disabled にし、live 専用上限を必須化する**  
   FixedOnce と `1 BTC / 5 BTC` の共通値で live 起動できないようにする。
4. **取引所 decoder を strict 化する**  
   不正・欠損数値を0へ丸めず、snapshot 全体を失敗させて halt する。
5. **初回 baseline と unknown recovery の承認付き command を作る**  
   直接 DB 編集なしで、snapshot hash・操作者・候補照合を監査可能にする。
6. **source timestamp / channel / subscribe ACK / clock skew / permissions を起動・risk gateへ追加する。**
7. **in-flight submission drain と SIGTERM 競合テストを追加する。**
8. **戦略 revision・注文 command hash・損益 ledger を永続化する。**
9. **Discord retry/heartbeat とホスト外形監視を追加する。**
10. **CD が対象 SHA の precommit 成功を必須条件にする。**

## 総評

前回の「live lifecycle 不在」は解消し、実装量とテスト密度は個人プロジェクトの平均を明確に上回った。特に submission unknown、受注 ID 永続化失敗、残高 baseline、risk 迂回を短期間でコードと回帰テストへ落とした点は高く評価できる。

しかし、自動売買の評価は機能数ではなく「実資金を安全に出せるか」で決めるべきである。現状は日次損失が本番で常に0扱い、残高検査が任意、両建て建玉の片側を見落としうる。さらに全環境既定の FixedOnce が live でも自動成行買いする。この組み合わせでは **live 運用は不合格** であり、P0完了を宣言してはならない。

現時点の一文評価は、**「本番形と実APIまで到達した高品質な安全基盤だが、実弾接続によって新たに露出した資金保全穴が残り、live 解禁直前で再停止すべき段階」** である。
