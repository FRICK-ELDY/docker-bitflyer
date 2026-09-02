# 評価: Elixir Umbrella / Phoenix / Ash / PostgreSQL / Docker

対象: [elixir-umbrella-phoenix-ash.md](../../1_backlog/elixir-umbrella-phoenix-ash.md)  
基準: [vision.md](../vision.md) と [overview.md](../architecture/overview.md)

## 結論

この Vision（24/365、再起動後の復帰、資金保全、単一ホスト）に対して、**技術の組み合わせは採用してよい**。

Elixir と PostgreSQL と Compose は要求に対して強い。変えるべきなのは製品の入れ替えより、次の使い方である。

- Ash は永続状態だけに使う。板・Tick・毎秒の判定には使わない
- Umbrella は `ui` と `bitflyer` の 2 つで止める
- 同じコンテナでも、UI と取引エンジンの監督ツリーは分ける

## 層ごとの判定

| 層 | 判定 | 相性 | 理由 |
| --- | --- | --- | --- |
| Elixir / OTP | 採用 | 高い | 再接続、プロセス隔離、監視下の常駐が言語の前提 |
| PostgreSQL | 採用 | 高い | 注文・建玉・サーキットの正本に向く。Tick は書かない |
| Phoenix / LiveView | 採用（運用 UI） | 中〜高 | ライブ表示に向く。エンジンと同じ再起動単位が弱点 |
| Mix Umbrella | 早期でも可 | 中 | 境界は正しい。3 アプリ目はまだ早い |
| Ash + AshPostgres | 永続層のみ | 中 | 注文状態には効く。ホットパスには向かない |
| Docker Compose | 採用 | 高い | 単一ホストの初期形として妥当。本番は release |

bitFlyer Lightning はインターネット経由の REST / WebSocket であり、マイクロ秒のコロケーションが勝負ではない。必要なのは切断からの復帰、未約定の突合、失敗時に発注を閉じること。OTP と永続化した注文状態は、その形に乗る。

Phoenix を裁量端末ではなく運用画面に限っている判断も正しい。

## 変えた方がよいこと

### Ash の適用範囲

Ash は注文、建玉、残高スナップショット、リスク停止状態、パラメータ履歴に使う。

板・Ticker・約定ストリームは ETS か GenServer に置く。判定ループから Resource を呼ばない。

ホットパスを Ash に載せると、遅延とロックと学習コストが先に来る。壊れた突合は結局 Ecto / SQL に落ちる。Ash 未経験なら、最初の状態機械は Ecto だけでも成立する。

### 監督の分け方

初期の「Elixir コンテナは 1 つ」は正しい。ただし Application ツリー上で Endpoint と取引監督を兄弟にする。UI の例外で発注プロセスを巻き込み再起動しない。

デプロイのたびにエンジンが落ちるのが痛くなったら、`ui` と `bitflyer` を別リリースにする。今は割らない。

### Umbrella を増やさない

`bitflyer` がドメインもクライアントもエンジンも持つのは、初期としては許容する。`core` / `exchange` / `ui` の 3 分割は、境界が実際に痛くなってから。

人が少なく、常に一緒に起動するなら、単一 Phoenix アプリ + context でも同じ価値は出る。Umbrella を選ぶなら、恩恵は「ui が API を直接叩けない」ことを依存関係で強制できる点に置く。

## 足した方がよいもの

| 項目 | 時期 | 理由 |
| --- | --- | --- |
| ETS（鮮度付き市場データ） | 今 | Architecture の cache。単一ノードなら Redis は不要 |
| Decimal（価格・数量） | 今 | float は残高不整合の原因になる |
| Telemetry + 構造化ログ | 今 | 切断、拒否、再起動理由を残す |
| 定期突合（`send_after`） | 発注の前 | 起動時だけでなく、稼働中も取引所の事実と合わせる |
| `mix release` | 本番前 | 開発用 `mix phx.server` を本番に出さない |
| WSL2（Windows の場合） | 開発開始時 | bind mount 上の Mix コンパイルが辛い |

## 今は足さないもの

Redis、Oban、AshAdmin、エンジンの別コンテナ、機械学習基盤。

定期ジョブはプロセスで足りる。キャッシュも ETS で足りる。最初の dry-run が通ってから足す。

## 代わりに選ぶなら

| 代替 | 向く場合 | この Vision では |
| --- | --- | --- |
| Elixir + Ecto（Ash なし） | 早く注文状態機械を書きたい | 次点。Ash 未経験なら安全 |
| 単一 Phoenix アプリ | 常に UI と engine を一緒に出す | Umbrella と同等以上になり得る |
| Python + ccxt | 戦略研究とバックテストが主目的 | 24/365 の監督が弱く、後からインフラを足す |
| Go 単体バイナリ | 依存の薄い常駐デーモン | Supervision を自前で書くコストが大きい |

Rust はレイテンシが商品になるときだけ意味がある。今回の接続形態では過剰である。

## 進め方

スタックは変えず、ToDo の骨格（Compose + Umbrella + 生存確認）を先に通す。

Architecture に次を一文で固定してから、取引所クライアントに進む。

- Ash は永続、市場データは ETS
- UI と engine は別監督
- 金額は Decimal
