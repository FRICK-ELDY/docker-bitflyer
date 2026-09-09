# マイナス点の統合一覧 2026-09-09

根拠: [opus-specific-weaknesses](./opus/opus-specific-weaknesses-2026-09-09.md) / [gpt-specific-weaknesses](./gpt/gpt-specific-weaknesses-2026-09-09.md)  
採用方針: 資金保全・live 復帰に直結する欠陥は GPT 寄りに重く、骨格品質の加点で相殺しすぎない。コード再検証済みの項目のみ採用。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| -1 | 改善余地あり。動作はするが設計・品質上の軽微な問題 |
| -2 | 重要な機能・設計の欠如。放置すると将来の拡張を阻害する |
| -3 | 設計上の明確な欠陥。バグ・損失・二重発注・状態不整合を引き起こしうる |
| -4 | プロジェクトの価値命題（資金保全・24/365・復帰）を損なう重大な欠如 |
| -5 | プロジェクトの根幹を揺るがす致命的な欠如。存在しないに等しい |

**減点合計: -55**

---

## 技術評価層 — apps/bitflyer

### order-executor / exchange

- **実取引クライアント・取消・約定追跡がなく live 運用不能** `-5`
  > 既定は `Exchange.Unavailable`。`Client` callback は突合 snapshot と `place_order` のみで、取消・注文照会・約定反映が無い。自動売買の価値命題として live ライフサイクルは未完成。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/exchange/client.ex`, `apps/bitflyer/lib/bitflyer/order_executor/live.ex`
  > 採用: GPT `-5`（Opus は取消欠如を `-3`。価値命題欠如として GPT を採用）

- **通信結果不明を rejected と確定し、受注後 ID 永続化失敗を自動回復できない** `-4`
  > `place_order` の全エラーを `rejected` 更新する。timeout / 切断は受注不明であり拒否とは限らない。受注成功後の `exchange_order_id` 永続化失敗は critical ログと `{:error, :persist_failed}` のみで Readiness halt しない。実 client 接続時に内部と取引所が分岐しうる。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/live.ex`
  > 採用: GPT `-4`（Opus 未計上。コード再読で確認）

- **paper が指値条件と仮想残高を再現しない** `-2`
  > limit は交差判定なしで即時全約定。BalanceSnapshot も更新しない。Architecture の「本番と同経路」検証としては不足。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor/paper.ex`
  > 採用: GPT `-2`（Opus は板欠如 `-1` と Balance 未書き込み `-2` に分割。paper 約定モデルとして統合）

### risk-manager

- **資金保全検査がサイズ・建玉・鮮度に偏り、損失・頻度・価格逸脱・残高が無い** `-4`
  > `Limits` は 3 キーのみ。prod.md の日次損失・発注回数・価格乖離を検査しない。サイズ上限だけでは小口連発や異常価格を止められない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/risk/limits.ex`, `apps/bitflyer/lib/bitflyer/risk.ex`
  > 採用: GPT `-4`（Opus `-3`。Vision Safety first の中核欠如として重め）

- **公開オプション `authorize?: false` で risk を迂回できる** `-3`
  > 本番と同じ `OrderExecutor.submit/2` が risk スキップを受け付ける。必須境界を API で強制していない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/order_executor.ex`
  > 採用: GPT `-3`（Opus 未計上。コード再読で確認）

### 起動・突合 / Recoverable

- **内部残高が空なら取引所残高を検証せず Ready になれる** `-4`
  > `compare_balances/2` は内部 snapshot の通貨だけ走査する。空なら比較ゼロ件で `:ok`。BalanceSnapshot の本番書き込みも無く、残高正本なしで live Ready へ進める。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/startup/reconcile.ex`, `apps/bitflyer/lib/bitflyer/trading/balance_snapshot.ex`
  > 採用: GPT `-4` に Opus の「書き込み無し」を内包

- **グレースフルシャットダウンが無い** `-3`
  > Application stop / submission drain / `stop_grace_period` が無い。注文・建玉を書く現状では停止時の不明状態が増える。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/application.ex`, `compose.yaml`
  > 採用: GPT `-3`（Opus `-2`。影響拡大を踏まえ重め）

- **halted からの復帰手段が UI / mix タスクに無い** `-2`
  > `clear_halt` はあるが呼び出し入口が remote console 以外に無い。無人運用の再開手順が未整備。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/readiness.ex`
  > 採用: Opus `-2`

### strategy / market-data

- **strategy が無く、本番経路で `submit_order` が駆動されない** `-3`
  > tick → 意図 → risk → executor の判断主体が無い。アルゴリズム後続は Vision どおりだが、経路の骨も無い。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/`
  > 採用: Opus `-3`（GPT は境界欠如 `-2`。縦貫通欠如として Opus）

- **取引所時刻・時計ずれを鮮度拒否に使えない** `-2`
  > 受信 monotonic のみ。Normalize は exchange timestamp を捨てる。Vision が WSL2 時刻ずれをリスクとして明記。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/market_data/normalize.ex`, `apps/bitflyer/lib/bitflyer/market_data/cache.ex`
  > 採用: GPT `-3` と Opus `-1` の中間 `-2`

- **戦略パラメータ適用履歴 Resource が無い** `-1`
  > Architecture 永続化最低限 6 項目のうち未実装。strategy と表裏のため軽め。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/trading.ex`
  > 採用: 双方合意（Opus `-1` / GPT `-2` → `-1`）

### observe（bitflyer 内）

- **telemetry allowlist が突合診断キーを落とす** `-1`
  > `:kind` / `:currency` / `:limit` が落ち、mismatch 種別がイベントに残らない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/telemetry.ex`
  > 採用: Opus `-1`

- **用途を失った Heartbeat Resource が残る** `-1`
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`
  > 採用: Opus `-1`

---

## 技術評価層 — apps/ui

- **「今トレードしてよいか」が一目で分からない** `-2`
  > Ready / DB / mode はあるが、`exchange_order_gate`・鮮度・Feed・未確定注文を使っていない。
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`
  > 採用: 双方 `-2`

- **本番 UI が wildcard bind かつ認証なし** `-3`
  > `0.0.0.0` bind + BasicAuth 無し。VLAN 越し監視想定に対する多層防御が無い。
  > 対象ファイル: `config/runtime.exs`, `apps/ui/lib/ui_web/router.ex`
  > 採用: GPT `-3`（Opus `-2`）

- **Phoenix 生成テンプレ残骸が運用画面を占有** `-1`
  > 対象ファイル: `apps/ui/lib/ui_web/components/layouts.ex`
  > 採用: Opus `-1`

---

## 技術評価層 — 実行基盤 / 設定

- **本番 release / Compose / backup・rollback が無い** `-3`
  > 開発 Dockerfile + bind mount のみ。Vision の本番 PC 常時稼働の実行形が無い。
  > 対象ファイル: `Dockerfile`, `compose.yaml`, `.workspace/2_todo/03-cd-prod-host.md`
  > 採用: 双方 `-3`

- **health が market stale / Feed 切断を unhealthy にしない** `-2`
  > DB / halted のみ。盲目運転を外形監視で検知できない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/health.ex`, `compose.yaml`
  > 採用: GPT `-2`

- **bitFlyer API キー環境変数名と最小権限検査が未定義** `-2`
  > `BITFLYER_LIVE_CONFIRM` はあるが KEY/SECRET 名がリポジトリに無い。
  > 対象ファイル: `.env.example`, `config/runtime.exs`
  > 採用: 双方 `-2`

- **開発コンテナが root 実行** `-1`
  > 対象ファイル: `Dockerfile`
  > 採用: Opus `-1`

---

## 横断評価層

- **人に届くアラート経路が無い** `-3`
  > halt / mismatch / disconnect が標準出力と Dashboard に留まる。無人 24/365 の Observable 未達。自動 halt 実装後は重要度が上がった。
  > 対象ファイル: `.workspace/1_backlog/discord-notify-adapter.md`
  > 採用: GPT `-3`（Opus `-2`）

- **README が実装より古い** `-1`
  > engine 未実装と書くが market-data / risk / executor は存在する。
  > 対象ファイル: `README.md`
  > 採用: 双方 `-1`

- **依存脆弱性の自動検査が無い** `-1`
  > 対象ファイル: `.github/workflows/ci.yml`
  > 採用: 双方 `-1`

- **`test_helper.exs` に Sandbox mode 明示が無い** `-1`
  > 対象ファイル: `apps/bitflyer/test/test_helper.exs`
  > 採用: Opus `-1`

---

## 小計

| 大分類 | 減点 |
|:---|---:|
| apps/bitflyer | -35 |
| apps/ui | -6 |
| 実行基盤 / 設定 | -8 |
| 横断 | -6 |
| **合計** | **-55** |
