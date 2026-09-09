# プラス点の統合一覧 2026-09-10

根拠: [opus-specific-strengths](./opus/opus-specific-strengths-2026-09-10.md) / [gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-10.md)  
採用方針: 実装された資金保全骨格の質は Opus 寄りに加点しつつ、同一テーマの重複は統合。live 経路の欠陥は weaknesses 側で相殺する。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

**加点合計: +73**

---

## 技術評価層 — apps/bitflyer

### TradeMode / Readiness / Circuit

- **live の三重ゲート（mode + UTC 当日 confirm + Ready）** `+4`
  > 書き残し live も翌日閉じる時限式。fail-closed。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trade_mode.ex`, `config/runtime.exs`

- **Readiness 単一正本・halted から Ready 直遷移不可** `+4`
  > UI / executor / health が同じ状態を読む。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`

- **サーキット開閉の安全側順序** `+3`
  > 開く: メモリ → DB。閉じる: DB → clear。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/circuit.ex`

### order-executor / live 安全化（前回 P0 の塞ぎ）

- **`submission_unknown` を第一級状態として halt・再送禁止** `+5`
  > 確定拒否以外を unknown。timeout/disconnect 回帰あり。Client moduledoc にエラー分類契約。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`, `apps/bitflyer/lib/bitflyer/exchange/client.ex`
  > 採用: Opus `+5`（GPT も解決確認）

- **受注後 `exchange_order_id` 永続化失敗で即 halt** `+4`
  > critical ログ + circuit。後続 submit 拒否の回帰あり。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`

- **冪等キー（内部注文 ID）とモード別出口** `+4`
  > dry_run / paper / live。paper 中に live REST を呼ばないテスト固定。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **署名付き Exchange.Rest（発注・取消・照会・約定反映）** `+3`
  > 既定 Unavailable。live+キー時のみ差し込み。fixture 契約テスト。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/rest.ex`
  > 注: P0 #5 未完了同居は weaknesses で減点。重複抑制で `+3`

### risk / reconcile / datastore

- **リスク境界の強制（authorize 迂回不可）** `+3`
  > 公開 `submit/2` は常に Risk。旧 `authorize?: false` は効かない回帰。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`

- **limits 比較面の網羅（サイズ・建玉・鮮度・頻度・価格逸脱・損失・残高）** `+2`
  > 関数とユニットはある。損失・残高の本番注入は未達のため満点にしない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk.ex`, `risk/limits.ex`

- **残高 baseline 欠落で Ready 拒否** `+4`
  > 空リスト成功にしない。必須通貨 JPY/BTC。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`

- **Ash 永続 + Decimal + Repo 境界** `+2`
  > Order / Position / Balance / RiskState。ホットパスは ETS。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading/`

- **残高 append の advisory lock とロック順序固定** `+2`
  > デッドロック回避まで意識した永続化。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/balances.ex`

### market-data / strategy / OTP

- **Feed 再接続・gap-fill・ETS 鮮度ゲート** `+3`
  > stale は risk と `/health/ready` で拒否。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/`

- **Strategy Behaviour + Runner + FixedOnce 縦貫通** `+2`
  > Feed tick → Risk → Executor。アルゴリズムは骨のみで十分。live 既定有効は weaknesses。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/strategy/`

- **`prep_stop` + child shutdown + Compose grace period の数値整合** `+2`
  > 新規発注ゲート閉鎖。in-flight drain は未達。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.prod.yaml`

- **`mix bitflyer.resume`（再突合成功時のみ clear）** `+3`
  > prod.md / release RPC 手順あり。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/resume.ex`

### observe

- **Discord アダプタ（失敗非阻害・URL 非ログ・cooldown）** `+2`
  > 第3アプリなし。halt / mismatch / disconnect。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/discord.ex`

- **telemetry allowlist（`:kind` / `:currency` / `:limit`）** `+2`
  > 秘密情報をメタデータに出さない設計。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/telemetry.ex`

- **`/health/live` と `/health/ready` の分離** `+2`
  > ready に Feed/鮮度。Compose healthcheck は live。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`

---

## 技術評価層 — apps/ui / 実行基盤

- **StatusLive の発注可否・Feed・鮮度・モード色分け** `+2`
  > 「今トレードしてよいか」が分かる運用 UI。裁量 UI ではない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **UI BasicAuth 二層 + prod bind 最小化** `+2`
  > prod 必須資格情報。`/health*` は除外。`PHX_HTTP_IP` allowlist。
  > 対象ファイル: `config/runtime.exs`, `apps/ui/`

- **開発/本番 Compose 分離・非 root release・GHCR CD** `+4`
  > `Dockerfile.prod` / digest 固定 / backup・rollback。
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`, `.github/workflows/cd.yml`

- **`mix precommit` と CI の同一ゲート + deps.audit 可視化** `+2`
  > format / warnings-as-errors / test。audit はゲート外 artifact。
  > 対象ファイル: `mix.exs`, `.github/workflows/ci.yml`

- **`.env.example` 追跡・live キー必須・出金禁止の文書一貫** `+2`
  > `.env` / `.env.prod` は gitignore。
  > 対象ファイル: `.env.example`, `config/runtime.exs`

---

## 横断

- **資金保全回帰テストの密度（187 + 23、0 failures）** `+4`
  > unknown / persist_failed / baseline / risk 迂回不可などを回帰で固定。
  > 対象ファイル: `apps/bitflyer/test/`

- **評価 → improvement-plan → 1 項目 1 PR の自己改善サイクル** `+1`
  > 前回 P0–P3 の大半を消化。文書とコードの一致度が高い。
  > 対象ファイル: `.workspace/0_doc/evaluation/`
