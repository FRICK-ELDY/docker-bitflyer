# commission 単位の証跡（P0 #1）

最終更新: 2026-09-29

## 結論

**BTC_JPY（Lightning 現物）の `getexecutions.commission` は BTC（base）単位。**
2026-09-28 の売買各 1 回で、買いも売りもその BTC が base 残高から減ることを確認した。
売りで quote から `C·P` を引く旧式は実差分と合わない。

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

API は単位フィールドを返さない。単位は公式と、下の実測差分で確定する。
execution id は末尾 4 桁のみ残す。

## Stage 3a 試行（2026-09-27）

署名 GET のみ。`sendchildorder` / `cancelchildorder` は呼んでいない。

| 項目 | 結果 |
|:---|:---|
| 実施日 (UTC) | 2026-09-27 |
| 権限 | count=33。`sendchildorder` あり。withdraw / sendcoin なし |
| `gettradingcommission` | `BTC_JPY` の `commission_rate=0.0015`（0.15%） |
| 建玉・未約定 | BTC amount=0、open orders=0 |
| 板 | ask ≥ bid。0.001 BTC の ask 想定代金が利用可能 JPY を上回った |
| 発注 | **しない**。最小数量 0.001 BTC（[手数料表の単位・最小](https://bitflyer.com/ja-jp/s/commission)）に届かない |

翌日に円を足し、下の実測へ進んだ。

## 実測（2026-09-28 UTC）

署名つき `gettradingcommission` は `0.0015`。出金権限なし。BTC_JPY 成行を買い 1 回、続けて売り 1 回。全量売り（available 丁度）は `insufficient_funds` で拒否されたので、売り数量は available / 1.0015 に切った。残った BTC は 0.00000001（最小数量未満）。

| | 買い | 売り |
|:---|:---|:---|
| execution id | …6098 | …6123 |
| acceptance id | …6830 | …9600 |
| size | 0.00101151 | 0.00100848 |
| price | 13311678 | 13326965 |
| commission | 0.00000151 | 0.00000151 |
| JPY 実差分 | −13465 | +13439 |
| JPY expected | −13464.895…（`−S·P`） | +13439.978…（`+S·P`） |
| BTC 実差分 | +0.00101 | −0.00100999 |
| BTC expected | +0.00101（`+S−C`） | −0.00100999（`−(S+C)`） |
| `LiveBalance.explain` | 許容内（JPY 差 0.105 < 1） | 許容内（JPY 差 0.978 < 1、BTC は一致） |

旧売り式（JPY `+S·P−C·P`、BTC `−S`）だと JPY は約 20 円多く、BTC は `C` だけ少なく、絶対床（1 円 / 1 satoshi）の外だった。

全量（available 丁度）は `insufficient_funds` だった。認可は建玉ちょうどの売りを拒み、`size` に公表上限 0.15% を足した base 負担でカバーを見る。実レートが 0.15% 未満だと、売り残が最小 0.001 BTC を下回って次の売りが通らず long が残ることがある。この口座は 0.15% なので `size = 建玉 / 1.0015` で平坦にできる。`ETH_JPY` の買い・売りは下の実測。ほかの spot の単位は未実測で、余白だけこの上限を使う。

## 実測（2026-09-29 UTC、ETH_JPY）

署名つき `gettradingcommission` は `ETH_JPY` も `0.0015`。権限 count=33。出金・送付は無し。ETH 残高は 0、円の amount は 19820 から始めた。成行買いの数量は 0.01004。取引所最小の 0.01 ちょうどは、手数料後に売り最小 0.01 を下回る。刻み上で手数料後も売れる最小の買いは 0.0100301 で、実測はその上を使った。売りは受取 ETH ÷ 1.0015 を、取引所が拒否しない刻みへ切った。

`0.01000992` は `400` で「Enter the size in units of 0.0000001 ETH.」となった。`0.0100099` は約定した。`getmarkets` に刻みは無い。残高と `commission` はこれより細かく、残り ETH は 0.00000003 だった。

| | 買い | 売り |
|:---|:---|:---|
| execution id | …1777 | …1912 |
| acceptance id | …6459 | …0215 |
| size | 0.01004 | 0.0100099 |
| price | 420958 | 420058 |
| commission | 0.00001506 | 0.00001501 |
| JPY 実差分 | −4227 | +4204 |
| JPY expected | −4226.418…（`−S·P`） | +4204.739…（`+S·P`） |
| ETH 実差分 | +0.01002494 | −0.01002491 |
| ETH expected | +0.01002494（`+S−C`） | −0.01002491（`−(S+C)`） |
| 許容 | JPY 差 0.582 < 1、ETH は一致 | JPY 差 0.739 < 1、ETH は一致 |

会計は BTC_JPY と同じ式である。円の `amount` はどちらも整数円へ寄った。買いと売りを同じ tip から一度に説明すると、円の丸め 0.582 と 0.739 の合計は 1 円床を超える。片道ずつなら床の内側である。発注数量の刻みは別で、ETH_JPY の売り最小は 0.01、買い最小は 0.0100301、刻みは 0.0000001 である。残り 0.00000003 ETH は残高であり、絶対床には使わない。床は Fill があるときの 0.00000001。

## 会計モデル（BTC_JPY）

`commission = C`（BTC）、約定 `size = S`、価格 `P`（JPY/BTC）のとき:

| 側 | JPY amount | BTC amount | Position.size | realized mark (JPY) |
|:---|:---|:---|:---|:---|
| 買い | `−S·P` | `+S − C` | `+S − C` | `−C·P` |
| 売り | `+S·P` | `−(S + C)` | `−(S + C)` | `−C·P`（＋売買差） |

売建 0.01 を買い `S=0.01 / C=0.00001` でカバーすると残短は `0.00001`（フラットにしない）。
`Fill.fee = C`、`Fill.fee_currency = "BTC"`。Decode の欠落・負は従来どおり fail-closed。

## Fixture

- ファイル: `apps/bitflyer/test/fixtures/exchange/getexecutions_btc_jpy_fee.json`
- `size` / `price` / `commission` は JSON 文字列（float 経路を避ける）
- 買い: `size=0.01`, `commission=0.00001` → 受取 BTC `0.00999`、quote mark fee `50` JPY（損益のみ）
- 売り: `size=0.00999`, `commission=0.00001` → 受取 JPY は `S·P`、BTC は `S+C` 減る

初期 tip を JPY `1_000_000` / BTC `0.5` とすると:

1. 買い後: JPY `950_000`、BTC `0.50999`
2. 売り後: JPY `999_950`、BTC `0.49999`

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
