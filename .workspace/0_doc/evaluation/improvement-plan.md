# 改善提案書（improvement-plan）

最終更新: 2026-09-10  
根拠: [evaluation-2026-09-10.md](./evaluation-2026-09-10.md) / [specific-weaknesses-2026-09-10.md](./specific-weaknesses-2026-09-10.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

---

## 消化済み（2026-09-09 計画の大半）

前回計画の P0 #1–#4、P1 全般、P2 全般、P3 #15–#19（UI 認証、API キー枠、本番 release、Exchange.Rest、deps audit）はコード上で解決済み。再掲しない。

**未消化として持ち越すもの:** 旧 P0 #5（risk limits の実効化）。比較関数はあるが本番注入が無い。

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | 日次損失の実効化 | Fill/建玉から当日損失の正本を作る。`Risk.authorize` に必須注入。未計測は `0` ではなく `:unsynced` | live 経路で損失超過が halt する回帰が緑。README risk 行を正直化 |
| 2 | 残高検査の実効化 | OrderRate 同型の ETS キャッシュ。live 突合 / paper fill で更新。必要通貨欠落は fail-closed | 未注入・欠落で認可拒否のテストが緑 |
| 3 | 両建て建玉突合 | 外部 `{product_code,side}` をネット建玉へ正規化（または内部 side 別）。順序反転 fixture | buy+sell 並存でも同じ Ready/halt 判定 |
| 4 | live 既定の安全化 | prod/live で Strategy 既定 `enabled: false`。live 専用上限を明示必須。FixedOnce の自動成行を live で止める | live+confirm だけでは意図が出ない |
| 5 | Decode strict 化 | 不正・欠損数値を 0 に丸めず snapshot 失敗 → halt | malformed/null fixture で halt するテストが緑 |

---

## P1 — 停止からの出口と自己修復

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 6 | baseline 初回 import | 承認付き `mix` / RPC。snapshot hash・操作者を記録。その後通常突合成功時のみ Ready | 空 DB から人手 SQL なしで baseline 作成可 |
| 7 | submission_unknown 回収 | 時刻窓+side+size の候補照合。一意時のみ ID 埋込。曖昧なら承認 command | unknown から resume できる手順が prod.md にある |
| 8 | 連続障害・auth サーキット | 401/403 即 halt。その他は窓内 N 回で halt | 鍵違いで盲目 rejected 連発しない |
| 9 | WS サイレントストール watchdog | 最終 tick 経過で socket 切断→再接続 | 無言接続が人手なしで回復する |
| 10 | in-flight drain | SIGTERM 後、進行中 submit/HTTP 完了を待つ | 競合テストで不明状態が増えない |

---

## P2 — 観測と契約の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | 本番 metrics 消費者 | ConsoleReporter または Prometheus / BasicAuth 配下 Dashboard | 率・推移が本番で見える |
| 12 | source timestamp / clock skew / permissions | Normalize 保持、skew ゲート、`getpermissions` で出金禁止を起動検査 | live 起動時に権限・時刻で halt できる |
| 13 | OrderRate の再起動復元 | 直近 1 分の Order を ETS に温める | クラッシュ直後に頻度上限を回避できない |
| 14 | CD↔CI 結合 | 対象 SHA の precommit 成功を CD 前提に。任意で `Dockerfile.prod` ビルド検証 | 赤のまま配布しない |
| 15 | 戦略パラメータ履歴 | Revision Resource + Order への由来記録 | どの設定が注文を生んだか追える |

---

## P3 — 厚み（解禁後でも可）

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 16 | paper 手数料・スリッページ | LTP±bps + 手数料 | paper 損益が過大楽観にならない |
| 17 | AuthorizedOrder 型 | Risk 成功 opaque のみ executor へ | 境界が型で強制される |
| 18 | Kill switch / StatusLive resume | 認証付き即 halt・再突合操作 | console 以外で運用できる |
| 19 | 残骸棚卸し | Heartbeat・Layouts 生成ヘッダ・Mailer 等 | ノイズが減る |

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
| P2 Discord（前回） | 実装済み（アダプタ） |
| P3 release（前回） | [03-cd-prod-host.md](../../3_archive/03-cd-prod-host.md)（完了） |
| paper 厚み | `.workspace/1_backlog/paper-trade-adapter.md` |

次回評価では、本計画の **P0** がコード上で解決済みかを対象ファイルの再読で確認する。P0 未完了のまま live 実発注を進めた場合は重大減点とする。
