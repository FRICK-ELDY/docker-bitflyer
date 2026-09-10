# 改善提案書（improvement-plan）

最終更新: 2026-09-10  
根拠: [evaluation-2026-09-10.md](./evaluation-2026-09-10.md) / [specific-weaknesses-2026-09-10.md](./specific-weaknesses-2026-09-10.md)

方針: **利益機能より資金保全・復帰・観測を先に直す。** live 実発注は下記 P0 の完了まで禁止。戦略の高度化は縦貫通の安全化の後。

---

## 消化済み（2026-09-09 計画の大半）

前回計画の P0 #1–#4、P1 全般、P2 全般、P3 #15–#19（UI 認証、API キー枠、本番 release、Exchange.Rest、deps audit）はコード上で解決済み。再掲しない。

**未消化として持ち越すもの:** なし（旧 P0 #5 の Decode strict まで解決済み）。

---

## P0 — live 解禁の前に塞ぐ穴

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 1 | ~~日次損失の実効化~~ **済** | Fill 正本 + invalidate→reload fail-closed。突合/resume で再同期。縦貫通回帰あり。含み損はスコープ外（実現のみ） | live/paper で Fill→DailyLoss→halt が緑。README risk 行を partial に正直化 |
| 2 | ~~残高検査の実効化~~ **済** | ETS + invalidate/reload（paper、残 hold 再適用）+ `reserve(hold_id)` / 部分約定 `consume_*` / `release_hold` 残額返却 + 突合一致時 exchange `put(clear_holds)`。baseline 更新は P1 #6 | pending+別 fill・部分約定 cancel・market 取消 LTP 差分などが緑 |
| 3 | ~~両建て建玉突合~~ **済** | 外部 `{product_code,side}` を突合前に net（buy−sell）正規化。順序反転 fixture で Ready/halt が一致 | buy+sell 並存でも片側上書きせず、ネット一致時 Ready・片脚一致のみは mismatch |
| 4 | ~~live 既定の安全化~~ **済** | live で Strategy 既定 enabled: false（BITFLYER_STRATEGY_ENABLED=true のみ有効）。FixedOnce 有効化は起動拒否＋evaluate 空。Risk 5 上限は環境変数必須 | live+confirm だけでは意図も開発上限も載らない |
| 5 | ~~Decode strict 化~~ **済** | 不正・欠損・NaN/Inf を 0 に丸めず :invalid_number で snapshot 失敗 → reconcile halt。構造欠落行は skip | NaN/null fixture と Reconciler halt が緑 |

---

## P1 — 停止からの出口と自己修復

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 6 | ~~baseline 初回 import~~ **済** | 承認付き `mix bitflyer.baseline` / `Release.import_baseline`。`BaselineImport` に snapshot hash・操作者。confirm しても Ready にせず、通常突合成功時のみ Ready。live は baseline 非更新のまま | 空 DB から人手 SQL なしで baseline 作成可 |
| 7 | ~~submission_unknown 回収~~ **済** | 時刻窓+side+size の `list_child_orders` 照合。一意時は hash 承認で ID 埋込、曖昧は `--exchange-order-id`、不在は `--absent`。`mix bitflyer.recover` / `Release.recover_submission`。Ready にせず resume 手順を prod.md に記載 | unknown から resume できる手順が prod.md にある |
| 8 | ~~連続障害・auth サーキット~~ **済** | 401/403 → `:auth_failed` 即 halt。その他確定拒否は `FailureRate` 窓内 N 回で `:consecutive_exchange_errors` | 鍵違いで盲目 rejected 連発しない |
| 9 | ~~WS サイレントストール watchdog~~ **済** | Feed が最終フレームから `stall_timeout_ms`（未設定時は鮮度窓×3）無通信なら `:stale_watchdog` で socket 切断→既存再接続 | 無言接続が人手なしで回復する |
| 10 | ~~in-flight drain~~ **済** | `InFlight` で submit/cancel を追跡。`prep_stop` はゲート閉鎖→drain（既定 10s）。timeout 時は pending を `submission_unknown` + halt。ID 埋込時は pending に整合 | 競合テストで不明状態が増えない |

---

## P2 — 観測と契約の締め

| # | 項目 | 具体策 | 完了の見方 |
|:---:|:---|:---|:---|
| 11 | ~~本番 metrics 消費者~~ **済** | prod 既定で `ConsoleReporter`（低頻度ドメインのみ）。BasicAuth 配下 `/ops/dashboard`（Ecto/RequestLogger オフ）。Prometheus は後続 | 率・推移が本番で見える |
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
