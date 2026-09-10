# マイナス点の統合一覧 2026-09-10

根拠: [opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-10.md) / [gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-10.md)  
採用方針: 資金保全・live 復帰に直結する欠陥は GPT 寄りに重く、骨格品質の加点で相殺しすぎない。コード再検証済みの項目のみ採用。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠如。存在しないに等しい |

**減点合計: -37**

---

## 技術評価層 — apps/bitflyer

### risk-manager

- **日次損失・残高の比較関数はあるが本番経路で実効しない（P0 #5 未完了）** `-5`
  > `:daily_loss` 未注入時は常に `0`（`risk.ex` L425-428）。`:balances` 未注入時は空で検査スキップ（L272-278, L432-436）。必要通貨欠落も `:ok`。`lib/` からの注入は無く、テスト注入だけが通る。比較 API の存在を「limits 完成」と読めない。P0 未完了のまま `Exchange.Rest` が live に差し込まれた点が重大。
  > 改善方針: Fill/建玉から当日損益の正本を作り必須注入。残高は ETS キャッシュ。取得不能は 0/空ではなく `:unsynced`。README を `partial` に戻す。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `apps/bitflyer/lib/bitflyer/strategy/runner.ex`
  > 採用: GPT `-5`（Opus は損失 `-4` + 残高 `-2` に分割。P0 未完了＋live client 同居として一本化して GPT）

- **連続障害・署名エラーでサーキットが開かない** `-2`
  > 401/403 が `:rejected_by_exchange` 扱いで注文ごとに静かに rejected。連続 5xx も halt しない。prod.md の「連続障害・署名エラーでサーキット」未実装。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`
  > 採用: Opus `-2`

- **OrderRate が再起動でゼロに戻る** `-1`
  > ETS のみ。クラッシュ直後に頻度上限を回避しうる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/order_rate.ex`
  > 採用: 両評価者合意（`-1`/`-2` → 起動直後 Readiness fail-closed を踏まえ `-1`）

### startup / reconciliation

- **両建て建玉が product_code キーの Map で片側上書きされ、誤 Ready になりうる** `-4`
  > REST は `{product_code, side}` で集約（`rest.ex` L148-169）するが、突合は `Map.new(..., &{position_code(&1), &1})`（`reconcile.ex` L191-194）。同一銘柄の buy/sell が並ぶと片側が消える。内部はネット建玉モデルなのに外部を net 化しない。
  > 改善方針: 外部を符号付き net に正規化するか内部を side 別へ。順序反転 fixture を含む回帰を追加。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`
  > 採用: GPT `-4`（Opus 未計上。コード再読で確認）

- **残高 baseline の初回 import 導線が無い** `-3`
  > 欠落時 halt は正しいが、承認付き import command が無く空 DB の live は人手 DB 編集以外で Ready 不能。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `.workspace/0_doc/architecture/env/prod.md`
  > 採用: GPT `-3`

- **`submission_unknown` / ID 喪失からの回収経路が無い** `-2`
  > halt・再送禁止は正しい。bitFlyer は client order id を受け付けず、halt 後に resume 不能な出口塞がりが残る。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`
  > 採用: 両評価者合意

### market-data / exchange

- **Decode が不正数値を Decimal 0 に丸め、契約違反を隠す** `-3`
  > `to_decimal/1` の失敗・nil が 0。size 0 は active_positions から除外され exposure 見落とし方向。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest/decode.ex`
  > 採用: GPT `-3`

- **source timestamp / 購読 ACK / 時計ずれをゲートに使えない** `-3`
  > Normalize は ltp 中心。Feed は subscribe 送信成功で接続扱い。WS サイレントストール時は切断イベント無しで再接続しない（安全側には倒れるが人手再起動待ち）。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/market_data/feed.ex`
  > 採用: GPT の鮮度欠如 `-3` に Opus のサイレントストールを内包

- **live 起動時に API 権限（getpermissions）を検証しない** `-2`
  > キー文字列の存在のみ。出金権限禁止は文書依存。
  > 対象ファイル: `config/runtime.exs`, `apps/bitflyer/lib/bitflyer/exchange/rest.ex`
  > 採用: GPT `-3` を権限検査に絞り `-2`（時計ずれは上項に内包）

### strategy / lifecycle

- **本番でも FixedOnce が既定有効で、開発値の上限のまま自動成行買いしうる** `-4`
  > `config.exs` で Strategy `enabled: true`、size `0.01` buy。Risk 上限は 1 BTC / 5 BTC / 日次損失 10 万円で live 専用絞り込み無し。live Ready 直後の最初の ticker で意図が出る。
  > 対象ファイル: `config/config.exs`, `apps/bitflyer/lib/bitflyer/strategy/fixed_once.ex`
  > 採用: GPT `-4`（Opus は実装完了として扱ったが、live client 同居後は危険既定として減点）

- **戦略パラメータ適用履歴が無い** `-1`
  > Architecture の最低永続対象。Application env のみ。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy.ex`
  > 採用: 両評価者合意

- **グレースフル停止は受付閉鎖のみで in-flight drain が無い** `-2`
  > `prep_stop` と `stop_grace_period` はある。進行中 HTTP/DB 完了を待つ coordinator は無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`
  > 採用: GPT `-3` を部分実装を踏まえ `-2`

---

## 技術評価層 — 観測 / UI / 基盤

- **本番に telemetry 集計先が無い** `-2`
  > イベント定義はあるが reporter 未起動。LiveDashboard は dev 限定。率・推移の監視が構造化ログと Discord に落ちる。
  > 対象ファイル: `apps/ui/lib/ui/telemetry.ex`, `apps/ui/lib/ui_web/router.ex`
  > 採用: Opus `-2`

- **README が risk-manager を implemented と過大申告** `-1`
  > 損失・残高は比較関数のみ。現状表の他行は概ね一致。
  > 対象ファイル: `README.md`
  > 採用: 両評価者合意

- **CD が対象 SHA の precommit 成功を強制しない / 本番イメージの CI ビルド検証が無い** `-1`
  > 配布経路は整ったが、品質ゲートと CD の結合が弱い。
  > 対象ファイル: `.github/workflows/cd.yml`
  > 採用: GPT / Opus を統合して `-1`

- **Phoenix 生成テンプレ残骸・開発コンテナ root・Sandbox 明示不足など軽微負債** `-1`
  > Layouts ヘッダ、Heartbeat、Mailer 等。資金保全には直結しないが DX/保守性を削る。
  > 採用: Opus の未解決残骸をまとめて `-1`

---

## 集計メモ

| 大分類 | 小計 |
|:---|---:|
| risk 実効性・頻度 | -8 |
| 突合・baseline・回収 | -9 |
| market/exchange 契約 | -8 |
| strategy / lifecycle | -7 |
| 観測・文書・基盤 | -5 |
| **合計** | **-37** |
