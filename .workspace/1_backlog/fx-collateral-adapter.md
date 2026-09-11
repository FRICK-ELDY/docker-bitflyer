# 要望: FX/CFD 証拠金アダプタ（getcollateral 正本）

ステータス: 未着手。P0 #2 は **B（spot 限定）** で先に閉じる。全銘柄化・FX live 解禁の前提として本要望を残す。

根拠: [improvement-plan.md](../0_doc/evaluation/improvement-plan.md) P0 #2 案 A /
[specific-weaknesses-2026-09-10_2.md](../0_doc/evaluation/specific-weaknesses-2026-09-10_2.md)（FX に spot 残高モデルを当てていた件）

## 背景

現行 live の残高・拘束は **spot 前提**（`getbalance` + 買い JPY / 売り BTC）。P0 #2 では既定を `BTC_JPY` に揃え、live で `FX_*` を拒否した（案 B）。

将来すべての銘柄（spot / FX / 先物等）を扱うには、市場種別ごとの資金正本が必要になる。bitFlyer FX/CFD の正本は証拠金（`getcollateral` / 必要なら `getcollateralaccounts`）であり、spot モデルのまま FX を解禁してはならない。

案 B の成果（`Product.market_type/1`、spot 経路、live の種別ガード）は残し、**FX 用アダプタとして本要望を足す**。B を捨てて置き換えるのではない。

```text
資金・拘束・突合
  ├─ spot   … getbalance + JPY/BTC 拘束（現行・P0 #2 B）
  ├─ fx/cfd … getcollateral + 必要証拠金・維持率（本要望 = 案 A）
  └─ futures … 別途（本要望の後）
```

## 確定したい置き方

| 項目 | 方針 |
| --- | --- |
| 形 | `Product.market_type` で分岐するアダプタ（Exchange / Risk / Reconcile） |
| spot | 現行のまま（getbalance）。壊さない |
| FX live | collateral 経路が Ready になるまで `FX_*` は拒否のまま |
| 売り拘束 | FX ではスポット BTC を要求しない。必要証拠金の見積もりを拘束 |
| 維持率 | 閾値割れで fail-closed（halt）。stale 時方針を明示 |
| paper | FX を paper で扱うなら証拠金相当の内部モデルを別途定義（初期は spot paper のままでも可） |

## この要望で満たすこと

1. `Exchange.Client` / Rest / Decode に `fetch_collateral`（必要なら accounts）がある
2. live 突合で FX 銘柄の資金正本が collateral である（getbalance だけに依存しない）
3. `Risk.balance_hold` / 利用可能検査が FX で必要証拠金モデルになる（売りで BTC を要求しない）
4. 維持率が閾値を下回ったらサーキットが開く（理由が観測可能）
5. LiveSafety / Risk の「spot のみ」が「種別アダプタ Ready なら許可」に更新され、`FX_BTC_JPY` live がテストで緑になる
6. spot 経路の回帰が赤にならない

## この要望でやらないこと（初期）

- 先物・特殊コードの本格対応（`market_type` 拡張は足場のみ可）
- 板・流動性ゲート（improvement-plan P3）
- 含み損ゲートの本格化は P2 #11 と隣接するが、維持率で最低限を先に閉じる
- UI での証拠金ダッシュボード（Status 密度は P2 #13）

## 完了の見方

- FX live で collateral 突合・必要証拠金拘束・維持率 halt の縦貫通テストが緑
- 既定を `FX_BTC_JPY` に戻しても（または product_codes に FX を足しても）売り誤拒否と証拠金見逃しが再現しない
- README / overview に「spot=getbalance / FX=getcollateral」が明記されている
- improvement-plan P0 #2 の「FX live なら collateral 経路が緑」を満たす

## 着手タイミング（推奨）

残り P0（#3 Decode fail-closed / #4 OrderRate 予約 / #5 fill sync）のあと。共通発注経路の穴を先に塞いでから FX 面を足す。
