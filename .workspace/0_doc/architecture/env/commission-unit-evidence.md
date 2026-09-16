# commission 単位の証跡（P0 #1）

最終更新: 2026-09-16

## 結論

**BTC_JPY（Lightning 現物）の `getexecutions.commission` は BTC（base）単位として扱う。**

API レスポンス自体は単位フィールドを持たない。単位の根拠は公式手数料表と、
かんたん取引所 BTC の Unit: BTC 明示、および「Lightning 現物は単位が通貨ペアで異なる /
Unit varies by Crypto Assets」である。

## 公式根拠（秘密なし）

確認日: 2026-09-13（評価） / 2026-09-16（実装再確認）

| 出典 | 記載 |
|:---|:---|
| [手数料一覧](https://bitflyer.com/ja-jp/s/commission) | Lightning 現物: 「約定数量 × 0.01〜0.15%、単位: 各通貨ペアで異なります」 |
| [Fees and Taxes](https://bitflyer.com/en-jp/s/commission) | Lightning Spot: “Unit varies by Crypto Assets” |
| 同ページ・かんたん取引所 BTC | Unit: **BTC**（Lightning 現物と同系の数量×率モデル） |
| [Private API List Executions](https://lightning.bitflyer.com/docs?lang=en#list-executions) | `commission` 数値のみ。単位の注記なし |

実口座の非ゼロ `getexecutions` は鍵が要るため本リポジトリには置かない。
単位確定は上記公式に依拠し、会計モデルは fixture で固定する。

## 会計モデル（BTC_JPY）

`commission = C`（BTC）、約定 `size = S`、価格 `P`（JPY/BTC）のとき:

| 側 | JPY amount | BTC amount | Position.size | realized mark (JPY) |
|:---|:---|:---|:---|:---|
| 買い | `−S·P` | `+S − C` | `+S − C`（反対売買の減算もこの inventory） | `−C·P` |
| 売り | `+S·P − C·P` | `−S` | `−S` | `−C·P`（＋売買差） |

売建 0.01 を買い `S=0.01 / C=0.00001` でカバーすると残短は `0.00001`（フラットにしない）。
`Fill.fee = C`、`Fill.fee_currency = "BTC"`。Decode の欠落・負は従来どおり fail-closed。

## Fixture

- ファイル: `apps/bitflyer/test/fixtures/exchange/getexecutions_btc_jpy_fee.json`
- `size` / `price` / `commission` は JSON 文字列（float 経路を避ける）
- 買い: `size=0.01`, `commission=0.00001` → 受取 BTC `0.00999`、quote mark fee `50` JPY
- 売り: `size=0.00999`, `commission=0.00001` → 受取 JPY から mark `50` 差し引き

初期 tip を JPY `1_000_000` / BTC `0.5` とすると:

1. 買い後: JPY `950_000`、BTC `0.50999`
2. 売り後: JPY `999_900`、BTC `0.5`

内部 `LiveBalance.explain` の expected が同じ値に一致することを回帰で固定する。

## 実装対応

- `Product.fee_currency/1` — spot は base、FX は quote
- `Fill.fee_currency`
- `Positions` / `LiveBalance` / `LiveExchangeHarness` が上表に一致

## P0 #2 反証回帰

- テスト: `apps/bitflyer/test/bitflyer/regression/commission_unit_guard_test.exs`
- fixture の `fee_currency: "JPY"`（決め打ち）→ `balance_mismatch`
- 旧 quote 残高（949_920 JPY / 0.51 BTC）→ 正しい fill でも `balance_mismatch`
- Position が exec_size 全量・取引所 net が `size − fee` → `spot_inventory_inflated`
