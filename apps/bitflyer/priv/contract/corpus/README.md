# 匿名レスポンス corpus

公開 GET を実ホストから取得し、注文識別子だけを伏せた記録。
手書き fixture（`test/fixtures/exchange`）とは別に、取引所の現行意味論を固定する。

| ファイル | 取得先 | 伏せた項目 |
| --- | --- | --- |
| `public/ticker_btc_jpy.json` | `GET /v1/ticker?product_code=BTC_JPY` | なし（市場データ） |
| `public/executions_btc_jpy.json` | `GET /v1/getexecutions` | `buy/sell_child_order_acceptance_id` |
| `public/markets.json` | `GET /v1/getmarkets` | なし |

更新:

```bash
docker compose run --rm app mix bitflyer.contract --write-corpus
```

private 応答はリポジトリに置かない（残高・建玉が口座を特定しうる）。
`--private` は署名 GET のその場検査のみ。
