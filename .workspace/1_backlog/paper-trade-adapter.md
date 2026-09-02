# 要望: ペーパー取引（order-executor のアダプタ）

ステータス: 方針を確定。Umbrella 骨格のあと、実発注より先に着手する。

## 背景

開発の既定は実資金を使わない。ただし「注文を出さない」だけだと、約定・建玉・再起動後の復帰を検証できない。

ペーパーは、市場データと strategy / risk は本番と同じ経路を使い、最後の発注先だけを仮想約定にする。

`apps/paper` は作らない。ペーパーは取引所ではなく、order-executor の出口である。

## 確定した置き方

| 項目 | 方針 |
| --- | --- |
| 形 | `apps/bitflyer` 内の executor アダプタ |
| 切替 | `TRADE_MODE=paper`（開発既定。`dry_run` と同系統） |
| 発注経路 | strategy → risk-manager → executor は live と同一 |
| 市場データ | 本番と同じ market-data。板をペーパー専用に複製しない |
| 正本 | 仮想残高・仮想建玉・内部注文を datastore に書く |
| 禁止 | ペーパー中に live API へ注文を送ること |

```text
strategy → risk-manager → order-executor
                              ├─ paper  擬似約定 → datastore
                              └─ live   bitFlyer REST → datastore
```

## この要望で満たすこと

1. `TRADE_MODE=paper` で、risk を通った注文が仮想約定になり、建玉と残高が内部で動く
2. 再起動後も仮想状態から復帰できる
3. `paper` のとき取引所のプライベート API（発注・取消）を呼ばない
4. live への切替は明示的で、ペーパー用状態と本番建玉を混ぜない
5. Architecture の取引モードと一致している

## この要望でやらないこと

- `apps/paper` を Umbrella に追加すること
- 独自の板合わせエンジンを取引所の代替として作ること（初期は ticker / 最良気配での即時擬似約定で足りる）
- ペーパーと live を同一プロセスで同時に動かすこと
- ペーパー損益を Discord 以外の対外報告に使うこと

板合わせや遅延約定が必要になったら、executor アダプタの中で足す。アプリ分割は、ペーパーを他システムへ提供する境界が痛くなってから検討する。

## 完了の見方

- executor に paper 実装があり、`TRADE_MODE` で切り替わる
- ペーパー注文が datastore の建玉を変え、再起動後も残る
- paper 中に発注 REST が呼ばれないことをテストで固定できる
- `apps/` に `paper` アプリが存在しない
