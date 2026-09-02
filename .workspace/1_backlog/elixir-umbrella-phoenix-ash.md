# 要望: Elixir Umbrella + Phoenix UI + Ash + Docker

ステータス: 要望を確定。着手手順は [ToDo](../2_todo/01-bootstrap-umbrella-and-docker.md) を正とする。

## 背景

自動売買の実装に入る前に、動かし続ける土台の技術を固定する。  
ホストに Elixir を常設する前提は置かず、**Docker 上で開発・起動できること**を先に満たす。

## 確定した技術

| 層 | 選定 | 役割 |
| --- | --- | --- |
| 言語 / ランタイム | Elixir (OTP) | 常駐プロセス、再接続、監視下の並列処理 |
| プロジェクト形 | Mix Umbrella | アプリ境界をリポジトリ内で分ける |
| 取引所連携 | `apps/bitflyer` | 市場データ、戦略、リスク、発注、状態同期 |
| UI | `apps/ui`（Phoenix / LiveView） | 稼働状況の閲覧と運用操作 |
| ドメイン / 永続化 | Ash Framework + AshPostgres | 注文・建玉・残高などの正本 |
| DB | PostgreSQL | 再起動後に戻す状態の置き場 |
| 実行基盤 | Docker Compose | アプリと DB を一式で起動する |

バージョンは実装時点の安定版をピン留めする。ここでの選定は「何を使うか」までを固定する。

## アプリ境界

```text
Umbrella (docker_bitflyer)
├── apps/bitflyer   取引所連携とドメインの正本
└── apps/ui         Phoenix。bitflyer を通して読む / 止める
        │
        ▼
   PostgreSQL
```

- `bitflyer` が Ash の Domain / Resource / Repo と、取引所クライアントを持つ
- `ui` は Phoenix Endpoint と LiveView を持ち、Ash の公開インターフェース経由でのみデータに触る
- `ui` から bitFlyer API を直接叩かない。発注経路は既存 Architecture どおり risk を通す
- 初期は Elixir コンテナは 1 つ。Umbrella 全体を 1 プロセス群として起動する

## この要望で満たすこと

1. `docker compose up` で PostgreSQL と Umbrella アプリが立ち上がる
2. ブラウザで UI の生存確認ページを開ける
3. Ash 経由で PostgreSQL に接続し、マイグレーションを適用できる
4. 開発用の秘密情報と接続先は Git に入れない
5. 開発の既定は dry-run のまま。この段階では実発注しない

## 初期 UI の範囲

Vision の「裁量トレード用の高機能 UI は作らない」は維持する。

最初の UI は運用用に限る。

- プロセス / ヘルス
- 取引モード（dry-run であることの表示）
- 後で足す建玉・注文・停止理由の受け皿

チャート取引端末、板の手動発注、複数ユーザー向け画面は対象外。

## この要望でやらないこと

- 戦略ロジックそのもの
- bitFlyer 本番 API での実発注
- 本番用イメージの最適化や複数ホスト構成
- 認証付きの公開 UI
- 取引所モックの完成（接続口だけ用意できればよい）

## 完了の見方

- リポジトリが Umbrella になり、`apps/ui` と `apps/bitflyer` がある
- Compose で DB とアプリが上がり、UI と DB 接続を確認できる
- Architecture 文書に、上記の技術とアプリ境界が追記されている
