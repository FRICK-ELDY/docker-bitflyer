# 改善提案書（improvement-plan）

最終更新: 2026-09-09  
根拠: [evaluation-2026-09-09.md](./evaluation-2026-09-09.md) / [specific-weaknesses-2026-09-09.md](./specific-weaknesses-2026-09-09.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 接続は下記 P0/P1 の完了まで禁止。戦略の中身は縦貫通の後。

---

## 消化済み（2026-09-08 計画の P0–P2）

前回計画の #1–17（品質ゲート、TradeMode、Readiness、health、telemetry、永続 Resource、突合、ETS、risk 骨、executor 出口、market-data、資金保全回帰）はコード上で解決済み。再掲しない。

---

## P0 — live 解禁の前に塞ぐ穴（実 client より先）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | submission 不明の安全化 | timeout/切断を `rejected` にしない。`submission_unknown`（または同等）+ 即 Readiness halt。確定拒否だけ rejected | 不明結果で halt し、再送しないテストが緑 |
| 2 | 受注後 ID 永続化失敗 | `exchange_order_id` 更新失敗時も halt。起動突合で回収するまで Ready にしない | persist_failed で発注ゲートが閉じる |
| 3 | 残高 baseline | live で必須通貨の BalanceSnapshot が無ければ Ready にしない。空リストで compare 成功にしない | 空 DB の live 突合が halt |
| 4 | risk 迂回の廃止 | `authorize?: false` を本番 API から除去。AuthorizedOrder 型または test 限定注入 | 公開 `submit/2` だけでは risk をスキップできない |
| 5 | risk limits 完成 | `max_daily_loss` / `max_orders_per_minute` / `max_price_deviation_pct`（+ 可能なら残高） | 各拒否理由のユニット + 回帰が緑 |

---

## P1 — 縦貫通と停止・復帰

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 6 | strategy の骨 | Behaviour + 固定ルール 1 本。Feed → Strategy → Risk → Executor を dry_run で駆動 | compose up 放置でも dry_run 意図がログに出る（または明示的に no-op でも経路が繋がる） |
| 7 | グレースフルシャットダウン | `prepare_stop` で発注ゲート閉鎖、子 `shutdown`、Compose `stop_grace_period` | SIGTERM 後に新規 submit が拒否される |
| 8 | halted 復帰手段 | `mix bitflyer.resume`（再突合成功時のみ clear_halt）。手順を prod.md に記載 | remote console 以外で再開できる |
| 9 | paper 残高・指値 | 擬似約定で BalanceSnapshot 更新。limit は LTP 交差（簡易で可） | paper 経路で残高行が増える |

---

## P2 — 観測と運用 UI

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 10 | Discord（または同等）通知 | halt / reconcile_mismatch / disconnect。失敗しても取引を止めない | Webhook 未設定でも起動し、設定時に halt が届く |
| 11 | StatusLive 発注可否 | `exchange_order_gate`・鮮度・Feed・モード色分けを最上部に | 「今トレードしてよいか」が 1 秒で分かる |
| 12 | health の外形 | `/live` と `/ready` 分離、または ready に stale/Feed を含める方針を文書+実装 | WS 断を外形監視で検知できる |
| 13 | telemetry allowlist | `:kind` / `:currency` / `:limit` を通す | mismatch 種別がログに残る |
| 14 | README 現状同期 | implemented / partial / unavailable をコンポーネント別に | README だけで現状が分かる |

---

## P3 — 本番形と live クライアント

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 15 | UI 認証・bind | BasicAuth（環境変数）+ 本番 publish 最小化。ToDo 03 に明記 | 認証なしで取引詳細を見られない |
| 16 | API キー枠 | `.env.example` に `BITFLYER_API_KEY` / `SECRET`。live 時のみ必須。出金権限禁止を文書化 | live でキー欠落時に起動停止 |
| 17 | 本番 release Compose | `mix release`、非 root、digest 固定、backup/rollback（ToDo 03） | 実弾なしで一度上げられる |
| 18 | private API client | 署名付き REST。cancel / 照会 / 約定反映。fixture 契約テスト | Unavailable 以外を差し込める |
| 19 | deps audit | CI で可視化（最初は fail させなくてもよい） | 既知脆弱性が一覧できる |

---

## 意図的に後回し（提案のみ）

- 戦略アルゴリズムの高度化・パラメータ UI
- 板の本格購読・プロパティ / モデルベース試験の本格導入
- paper Game Day、SBOM / 署名、SLO 数値の精緻化
- 裁量向け UI、複数取引所、ML 基盤

---

## 既存 ToDo / バックログとの対応

| 改善 | 既存文書 |
|:---|:---|
| P3 #17 | `.workspace/2_todo/03-cd-prod-host.md` |
| P2 #10 | `.workspace/1_backlog/discord-notify-adapter.md` |
| P3 #18（paper 厚みの延長） | `.workspace/1_backlog/paper-trade-adapter.md` |

次回評価では、本計画の **P0** がコード上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live client を足した場合は重大減点とする。
