# docker-bitflyer 第2評価者 マイナス点（2026-09-10）

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | 資金保全・24/365・復帰を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠陥。存在しないに等しい |

## 技術評価層 — apps/bitflyer

### risk-manager

- **P0 #5 は見かけ上の API だけで、実運用の損失・残高へ接続されていない** `-5`
  > `max_daily_loss` の比較関数はあるが、`:daily_loss` 未注入時は常に `0` を返す（`risk.ex:410-428`）。本番の `OrderExecutor.submit/2` は daily loss を注入せず、Fill・Balance 差分から当日損益を計算する実装もない。残高も未注入なら空で検査をスキップし、必要通貨が map に無い場合も `:ok` になる（`risk.ex:272-280, 291-336, 431-436`）。テストは損失値・残高を直接注入して比較関数だけを通しており、live 経路の資金保全を証明しない。P0 未完了のまま `Exchange.Rest` を live に差し込んだため重大である。
  >
  > 改善方針: 約定・建玉から実現/未実現損益の正本を永続化し、live 認可時に当日損失 snapshot を必須入力にする。live の残高は最新 reconcile snapshot を ETS へ原子的に公開し、必要通貨欠落を `:unsynced` とする。値が取得不能なら 0 や空ではなく fail-closed にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`, `apps/bitflyer/test/bitflyer/risk_test.exs`

- **発注頻度 ETS は再起動で消え、1分上限を回避できる** `-2`
  > `OrderRate` は「テーブル消失時は 0」とし、過去 1 分の Order を DB から復元しない（`order_rate.ex:31-44, 82-96`）。Runner や OrderRate だけの再起動直後に上限件数を再度発注できる。24/365 システムではプロセス再起動が安全上限のリセット操作になってはならない。
  >
  > 改善方針: 起動時に直近 1 分の Order `inserted_at` を読み ETS を再構築するか、DB 上の時間窓カウントを低頻度 snapshot として ETS へ同期する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`, `apps/bitflyer/lib/bitflyer/order_executor.ex`

### startup / reconciliation

- **両建てを含む取引所建玉が Map 化で欠落し、誤って Ready になりうる** `-4`
  > Private REST は建玉を `{product_code, side}` ごとに集約するため、同一銘柄の buy と sell を2要素で返しうる（`rest.ex:149-169`）。しかし突合側は `Map.new(active_positions(external), &{position_code(&1), &1})` と product_code だけをキーにし、一方を上書きする（`reconcile.ex:191-197`）。内部 Position は銘柄×モード1行のネット建玉モデルであるため、外部両建てを net 化しないまま比較する実装は、列挙順次第で片側の実エクスポージャを見落とす。
  >
  > 改善方針: 取引所 snapshot を銘柄単位の符号付き net size と整合する平均価格へ正規化するか、内部モデルを side 別に変更する。buy/sell 両方がある fixture と順序反転の突合テストを追加し、どちらでも同じ結果にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/trading/position.ex`

- **残高 baseline を安全に作る正式入口がなく、新規 live は手作業なしで Ready にできない** `-3`
  > baseline 欠落を halt する P0 #3 自体は解決した。しかし `getbalance` を初回 import して承認・永続化する command がなく、空 DB では resume しても同じ `balance_baseline_missing` になる（`reconcile.ex:244-279`）。文書は「RiskStateだけを手で書き換えない」とする一方、現状はテストの `seed_live_balance_baseline!` 相当を人が DB へ直接入れる以外に導線がない。
  >
  > 改善方針: `bitflyer.baseline --dry-run/--confirm` または release RPC を作り、取引所 snapshot、操作者、時刻、hash を記録して初回 baseline を transaction 作成する。作成後も通常 reconcile が一致した場合だけ Ready にする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/startup/resume.ex`, `.workspace/0_doc/architecture/env/prod.md`

- **submission_unknown と受注 ID 永続化失敗を自動回収できない** `-2`
  > 安全に halt はするが、`submission_unknown` は open order 読み出し対象外で、内部 ID は bitFlyer の `sendchildorder` payload に送れない。受注済みで `exchange_order_id` を失った pending 行も `open_order_missing_exchange_id` で止まるだけである（`reconcile.ex:298-304, 384-390`）。復帰時に acceptance ID の候補を注文時刻・side・size から照合して人へ提示する仕組みがない。
  >
  > 改善方針: 発注直前時刻と request fingerprint を永続化し、getchildorders/getexecutions の狭い時間窓から候補を列挙する。自動確定は一意一致時だけとし、曖昧なら停止したまま承認付き recovery command へ渡す。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

### market-data / exchange

- **source timestamp・WS channel 整合・購読 ACK・時計ずれを検査しない** `-3`
  > Normalize は `product_code` と `ltp` だけを残し、ticker の timestamp と `params.channel` を捨てる（`normalize.ex:9-18, 35-48`）。Feed は `subscribe/2` が `:ok` を返した時点で subscribe_count を増やすが、JSON-RPC response/timeout を追跡せず、購読失敗でも接続状態のままである（`feed.ex:190-208`）。遅延・リプレイ価格が「今届いた」ため fresh になり、署名時刻のホストずれも起動ゲートにない。
  >
  > 改善方針: source timestamp、monotonic receipt time、channel を正規化値に保持し、channel-product 対応と最大 source age を検査する。subscription ID ごとの ACK/timeout を追跡し、失敗時は再接続する。live 起動時に時刻同期状態または取引所時刻との差を検査する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`, `apps/bitflyer/lib/bitflyer/exchange/auth.ex`

- **外部 JSON の不正な数値を Decimal 0 に丸め、契約違反を隠す** `-3`
  > `Decode.to_decimal/1` は parse 失敗、nil、未知型をすべて `Decimal.new("0")` にする（`decode.ex:6-21`）。残高・建玉・注文・約定のデコードはその値を正常値として返すため、API 変更や欠損を normalization error として halt できない。特に建玉 size 0 は `active_positions/1` で除外され、実際の exposure を見落とす方向へ倒れうる。
  >
  > 改善方針: decoder を `{:ok, value} | {:error, field}` にし、必須数値の欠損・非数・負値を snapshot 全体の失敗へ伝播する。fixture に malformed、null、指数表記、overflow 相当を追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`

- **API キー権限と時刻同期を live 起動時に検証しない** `-3`
  > runtime はキー文字列の存在だけを検査し、`getpermissions` を呼ばない（`runtime.exs:111-157`）。文書上「出金権限なし」でも、誤って過大権限キーを設定した場合に起動を止められない。署名 timestamp もローカル system time を無条件で使う（`auth.ex:39-44`）。
  >
  > 改善方針: live boot の reconcile 前に permissions allowlist と時刻差を照会し、出金/送付権限、必要権限欠落、許容外 clock skew を永続 halt 理由にする。
  >
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`, `apps/bitflyer/lib/bitflyer/exchange/auth.ex`

- **private REST は fixture 契約だけで、実 API 互換性の定期確認がない** `-2`
  > 署名・query・fixture decode のテストは良いが、bitFlyer Sandbox/最小権限の参照専用 smoke、記録済み実レスポンスの schema test、API 変更検知がない。`getpositions` の両建てや `getchildorders` の検索窓など、実データ形状でのみ出る欠陥が残っている。
  >
  > 改善方針: CI 外の承認付き read-only contract job と、匿名化した実レスポンス fixture 更新手順を作る。発注系は dry-run HTTP adapter と最小ロットの段階運用で検証する。
  >
  > 対象ファイル: `apps/bitflyer/test/bitflyer/exchange/rest_test.exs`, `apps/bitflyer/test/fixtures/exchange/`

### strategy / order lifecycle

- **本番でも FixedOnce が既定有効で、上限も開発値のまま自動成行買いする** `-4`
  > 共通 config は Strategy を全環境で `enabled: true`、size `0.01`、side buy とし、Risk 上限は注文 `1` BTC・建玉 `5` BTC・日次損失 100,000 円である（`config.exs:37-53`）。runtime は live 用の小さい上限や strategy 明示確認を要求しない。live baseline を手動で揃え、当日確認を入れた直後の最初の ticker で固定成行買いが走る。live client を追加した現在、この既定は安全な「骨」ではない。
  >
  > 改善方針: prod/live は strategy 既定無効とし、strategy module・revision・size・全 risk limits を環境変数または署名済み設定で明示しなければ起動停止する。live 初回は no-op strategy と最小上限で参照・突合だけを確認する。
  >
  > 対象ファイル: `config/config.exs`, `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`

- **戦略パラメータ revision と注文への由来記録がない** `-2`
  > Strategy params は Application env の map だけで、Architecture の最低永続対象である「戦略パラメータ適用履歴」がない（`strategy.ex:31-38`）。Order に strategy module、revision、intent payload hash がなく、後からどの設定が注文を生んだか再現できない。
  >
  > 改善方針: immutable な StrategyParameterRevision Resource を追加し、Order に revision ID と command hash を保存する。Runner は有効 revision を起動時に固定し、途中変更は再 reconcile を経る。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`, `apps/bitflyer/lib/bitflyer/trading.ex`

- **グレースフル停止は新規ゲート閉鎖だけで、進行中 submission を drain しない** `-3`
  > `prep_stop/1` は Readiness を not_ready にするが、HTTP 発注中件数・DB transaction 中件数を追跡せず待たない（`application.ex:44-67`）。子の一律 5 秒 shutdown と Compose 45 秒はあるものの、「送信済みだがレスポンス待ち」の処理を完了または submission_unknown 永続化してから終了する保証がない。
  >
  > 改善方針: Executor coordinator に受付停止と in-flight registry を持たせ、prep_stop で close → drain → timeout 時 unknown 永続化の順にする。SIGTERM を HTTP 応答前・応答後・ID保存前へ注入する統合テストを追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `compose.prod.yaml`

- **未約定の滞留期限・全取消・出口戦略がない** `-2`
  > cancel API と定期同期は実装されたが、注文ごとの time-in-force、最大 open age、サーキット時の cancel-all 方針がない。limit 注文や cancel accepted 後の pending が無期限に残りうる（`live/cancel.ex:61-99`）。無人運用で exposure を閉じるポリシーが未完成である。
  >
  > 改善方針: Order に期限と cancel requested 状態を持たせ、reconciler が滞留を検知して通知・取消する。halt 理由別に「新規停止のみ」「未約定全取消」を設定し、取消結果不明も専用状態で追跡する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live/cancel.ex`, `apps/bitflyer/lib/bitflyer/startup/reconciler.ex`, `apps/bitflyer/lib/bitflyer/trading/order.ex`

- **paper は部分約定・手数料・証拠金を再現しない** `-1`
  > limit 交差と残高更新は改善したが、交差時は常に全量を指値で約定し、手数料・スリッページ・証拠金・注文予約を扱わない（`paper.ex:70-100, 142-159`）。本番同経路の機能回帰には使えるが、資金曲線やリスク閾値の妥当性検証にはまだ使えない。
  >
  > 改善方針: 板出来高に基づく部分約定、手数料、予約残高、FX/CFD 証拠金を段階的に追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`, `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`

## 技術評価層 — apps/ui / observe

### 運用 UI

- **Status の ALLOWED 判定が Feed 切断を直接見ていない** `-1`
  > `OperationalStatus.snapshot/1` は feed を取得するが、`classify/4` へ渡さず、Readiness・live confirm・cache freshness だけで ALLOWED を決める（`operational_status.ex:53-71, 150-169`）。切断直後から cache stale まで最大5秒、画面は Feed disconnected と ALLOWED を同時表示しうる。health/ready の判定とは不一致である。
  >
  > 改善方針: UI の orders gate も `Health.classify_ready` と同じ feed 条件を共有し、判定ロジックを一つにする。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/operational_status.ex`, `apps/ui/lib/ui_web/live/status_live.ex`

### 可観測性

- **通知は失敗時再試行せず、ホスト監視・永続メトリクス・心拍もない** `-2`
  > Discord は送信失敗でも即 cooldown 済みにし、queue や retry を持たない（`discord.ex:126-163`）。通知できない状態そのものを別経路で検知できず、コンテナ再起動ループ、ディスク、メモリ、NTP、未約定滞留、日次損益の監視もアプリ外を含め未実装である。無人24/365の「届く」保証には未達。
  >
  > 改善方針: bounded retry queue、通知 adapter heartbeat、外部 uptime 監視、ホスト exporter を導入し、通知経路断を別経路で検知する。注文滞留と損失接近の telemetry も追加する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`, `.workspace/0_doc/architecture/env/prod.md`

## 技術評価層 — 実行基盤 / 横断評価

### CI/CD / production

- **CD が同一 commit の precommit 成功を依存関係として強制しない** `-2`
  > `cd.yml` はタグ・手動参照を checkout して直ちに image build/push し、CI workflow の成功を needs や再実行で検査しない（`cd.yml:1-29, 34-80`）。保護されていないタグや手動 dispatch では、テスト未通過 commit を production environment へ載せられる。
  >
  > 改善方針: reusable workflow で precommit を CD 内から必須実行するか、対象 SHA の必須 check 成功を API で検証してから build する。production environment reviewer も実設定で必須化する。
  >
  > 対象ファイル: `.github/workflows/cd.yml`, `.github/workflows/ci.yml`

### DX / プロジェクト全体設計

- **README の risk「implemented」は実装度を過大表示する** `-1`
  > README は risk-manager を「サイズ・建玉・損失・頻度・価格逸脱・残高」の implemented とする（`README.md:24-30`）。しかし本番 submit の日次損失は常時0、残高は未注入でスキップされる。live 解禁判断に使う入口文書として危険な表現である。
  >
  > 改善方針: risk を partial とし、「比較関数あり / 実データ正本未接続」を明記する。live 禁止理由を P0 #5 と建玉突合欠陥に具体化する。
  >
  > 対象ファイル: `README.md`, `.workspace/0_doc/evaluation/improvement-plan.md`

**減点合計: -45**
