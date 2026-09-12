# Game Day / 実 API contract

fixture 以外の意味論を、公開 GET の実応答と paper 障害注入で確認する。
**P0 未完了のあいだ live 実発注は禁止。** 本手順は発注・取消 REST を呼ばない。

関連: [prod.md](./prod.md) / [ci-cd.md](../ci-cd.md) / corpus `apps/bitflyer/priv/contract/corpus/`。

## 何を保証するか

| 層 | 手段 | CI |
| --- | --- | --- |
| 記録済み公開応答の意味論 | `mix bitflyer.contract --corpus`（ネット不要） | `precommit` の `Contract.check_corpus` |
| 現行公開 API | 人が `mix bitflyer.contract`（公開 GET のみ） | **叩かない** |
| 署名 GET | 人が `--private`（権限・突合 snapshot のみ） | **叩かない** |
| 障害注入 | paper で halt / Feed 断 / Status 復帰 | 既存ユニット。実ホスト注入は人手 |
| 最小ロット実発注 | P0 完了後の段階解禁。下表は記録テンプレのみ | しない |

禁止パス（契約ジョブもコードも呼んではならない）:

- `POST /v1/me/sendchildorder`
- `POST /v1/me/cancelchildorder`

## 公開契約（キー不要）

開発 Compose:

```bash
docker compose run --rm app mix bitflyer.contract
docker compose run --rm app mix bitflyer.contract --product-code=BTC_JPY
docker compose run --rm app mix bitflyer.contract --corpus
```

見るもの: ticker の `product_code` / 正の LTP・bid/ask（ask ≥ bid）/ ISO 先頭の `timestamp`。
直近 executions の id・side・正の price/size・`exec_date`。
markets に対象 `product_code` があること。

corpus を取り直す（注文 ID は自動で伏せる。一時ディレクトリ推奨）:

```bash
docker compose run --rm app mix bitflyer.contract --write-corpus \
  --corpus-dir=/tmp/bitflyer-contract-corpus
```

差分を目視してから `apps/bitflyer/priv/contract/corpus/` へコピーする。
private 応答はリポジトリに置かない。

## 署名 GET（任意・発注しない）

キーがあるホストでのみ。POST は走らない。

```bash
docker compose run --rm app mix bitflyer.contract --private
```

失敗したら鍵・権限・ネットワークを直し、再実行。成功しても Ready にはしない。

## paper 障害注入

`TRADE_MODE=paper`。取引所へは出さない。監視・取消方針・復帰手順が紙の上で閉じるかを見る。

1. paper で仮想建玉または未約定を作る
2. Status の kill、または `mix bitflyer.halt` → 新規発注が止まること
3. Feed 断または stale（ready が 503、`feed_disconnected` / `stale_market_data`）
4. Discord HEARTBEAT / halt 通知が届くこと（Webhook 設定時）
5. 別ホスト相当で `GET /health/ready` を引き、非 ready を人が検知できること
6. Status の復帰手順どおり resume / reconcile（[prod.md](./prod.md)）
7. 下の記録表に残す

## 最小ロット段階解禁（記録。live は P0 後）

P0 #1–#5 がコード上で閉じるまで Stage 3 以降は実施しない。

| Stage | 内容 | 実施条件 | 記録すること |
| --- | --- | --- | --- |
| 0 | 公開 GET contract | いつでも | 日時・product・結果 |
| 1 | `--private` 署名 GET | 出金なしキー | 権限一覧の要約（出金パス無し） |
| 2 | paper soak + 上の障害注入 | paper が動くこと | 注入内容・ready / Discord / 復帰 |
| 3 | spot 最小ロット 1 発注→取消 | **P0 完了後** | 注文 ID・約定の有無・DailyLoss |
| 4 | 部分約定 2 回以上 | Stage 3 成功後 | VWAP / realized / DailyLoss 一致 |
| 5 | 上限緩和の段階 | Stage 4 成功後 | 変更した env と理由 |

## 記録テンプレ

コピーして日付ファイルまたは運用メモに残す。秘密・生の注文 ID は書かない（必要なら末尾数桁）。

| 項目 | 記入 |
| --- | --- |
| 実施日 (UTC) | |
| 実施者 | |
| Stage | 0 / 1 / 2 /（3 以降は P0 後） |
| モード | dry_run / paper /（live は禁止中） |
| product_code | BTC_JPY |
| 公開 contract | ok / fail（理由） |
| `--private` | skipped / ok / fail |
| 注入 | なし / kill / feed 断 / stale / その他 |
| ready | 200 / 503（reason） |
| Discord | 届いた / 未設定 / 欠落 |
| 復帰 | 手順どおり / 詰まった点 |
| 次アクション | |

### 実施記録（2026-09-12）

| 項目 | 記入 |
| --- | --- |
| 実施日 (UTC) | 2026-09-12 |
| 実施者 | 開発（corpus 採取） |
| Stage | 0 |
| モード | dry_run |
| product_code | BTC_JPY |
| 公開 contract | ok（ticker / getexecutions / getmarkets を実ホストから採取し匿名化） |
| `--private` | skipped |
| 注入 | なし |
| ready | 対象外 |
| Discord | 対象外 |
| 復帰 | 対象外 |
| 次アクション | paper Stage 2 をホストで実施。Stage 3 は P0 後 |
