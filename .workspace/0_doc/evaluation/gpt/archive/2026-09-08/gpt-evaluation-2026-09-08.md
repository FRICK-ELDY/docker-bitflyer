# docker-bitflyer プロジェクト評価（第2評価者 GPT-5.6 Sol）

- 評価日: 2026-09-08
- 評価種別: 初回評価
- 正本: `.workspace/0_doc/vision.md`、`.workspace/0_doc/architecture/overview.md`、`.workspace/0_doc/architecture/env/dev.md`、`.workspace/0_doc/architecture/env/prod.md`
- 評価方法: 第1評価者の文書および過去の評価まとめを参照せず、現行コード・設定・テスト・ToDo / Backlog を直接検証

## 総合スコア

| 評価層 | 加点 | 減点 | 純点 |
|---|---:|---:|---:|
| apps/bitflyer | +5 | -30 | -25 |
| apps/ui | +3 | -5 | -2 |
| 実行基盤 / 設定 | +7 | -12 | -5 |
| テスト戦略 | +1 | -5 | -4 |
| DX / セキュリティ | +1 | -3 | -2 |
| プロジェクト全体設計 | +3 | -2 | +1 |
| **合計** | **+20** | **-57** | **-37** |

詳細:

- プラス点: [gpt-specific-strengths-2026-09-08.md](./gpt-specific-strengths-2026-09-08.md)
- マイナス点: [gpt-specific-weaknesses-2026-09-08.md](./gpt-specific-weaknesses-2026-09-08.md)
- 提案: [gpt-specific-proposals-2026-09-08.md](./gpt-specific-proposals-2026-09-08.md)

## 観点別評価

### apps/bitflyer

**小計: +5 / -30 = -25点**

Repo を `bitflyer` に閉じ、UI から一方向依存にした骨格は良い（`apps/ui/mix.exs:47-49`, `apps/bitflyer/lib/bitflyer/repo.ex:1-12`）。Heartbeat Resource と migration により Ash / PostgreSQL の接続も実体がある（`heartbeat.ex:1-29`, `20260904092539_add_heartbeats.exs:10-27`）。

一方、Application の監督対象は Repo だけである。

```10:12:apps/bitflyer/lib/bitflyer/application.ex
    children = [
      Bitflyer.Repo
    ]
```

market-data、strategy、risk-manager、order-executor、ETS cache、observe、復元・突合シーケンスは未実装である。特に risk と冪等 executor は Vision の Safety first / Idempotent actions、永続状態と突合は Recoverable の中核であり、後続拡張ではなく現時点の重大な欠如として減点した。価格・数量を Decimal にする要件も、取引 Resource 自体がないため検証不能である。

### apps/ui

**小計: +3 / -5 = -2点**

StatusLive は取引 API を呼ばず、運用ステータスに責務を絞る。DB query の error / exception / exit を画面上の unavailable へ変換し、5秒ごとに回復を再確認する（`system.ex:12-25`, `status_live.ex:100-118`）。

しかし現在の表示は mode と DB 接続だけである。

```69:94:apps/ui/lib/ui_web/live/status_live.ex
        <dl class="grid gap-4 sm:grid-cols-2">
          <div id="trade-mode-card" ...>
            ...
            <dd id="trade-mode" ...>{@trade_mode}</dd>
          </div>
          <div id="db-status-card" ...>
            ...
          </div>
        </dl>
```

市場データ stale、取引所未突合、サーキット open を統合した「今トレードしてよいか」と停止理由は分からない。また production Endpoint は wildcard bind（`runtime.exs:94-103`）で、Router に認証がない（`router.ex:3-25`）。本番公開前にネットワーク制限と認証の多層防御が必要である。

### 実行基盤 / 設定

**小計: +7 / -12 = -5点**

開発 Compose は app / db、localhost 限定公開、DB healthcheck、app restart、bind mount を整合的に実装する（`compose.yaml:1-58`）。`TRADE_MODE` の既定は runtime / Compose / example の全てで dry_run、秘密情報は runtime 注入と `.gitignore` で分離されている（`runtime.exs:10-16,42-44,84-89`, `.gitignore:30-40`）。`docker compose config --quiet` は評価環境で成功した。

ただし app healthcheck は status page の HTTP 200しか見ない。

```49:54:compose.yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/ >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 60s
```

DB unavailable でも StatusLive は200を返すため、これは readiness ではない。取引所同期や市場鮮度も見ない。本番 release image / Compose / backup / rollback は未実装で、唯一の Dockerfile は明示的に開発用である（`Dockerfile:1-20`）。さらに `TRADE_MODE` は任意文字列を受け入れ、live 解禁条件を持たない（`runtime.exs:42-44`）。

CI も存在せず、ルート `mix.exs` に precommit alias がない（`mix.exs:24-28`）。標準ゲートの実測結果は後述する。

### テスト戦略

**小計: +1 / -5 = -4点**

StatusLive のテストは主要 DOM ID と利用者向け結果を検証する（`status_live_test.exs:6-28`）。一方、bitflyer のテストは生成時の hello doctest / test だけである。

```1:7:apps/bitflyer/test/bitflyer_test.exs
defmodule BitflyerTest do
  use ExUnit.Case
  doctest Bitflyer

  test "greets the world" do
    assert Bitflyer.hello() == :world
  end
end
```

冪等性、dry_run / paper / live 分離、risk、stale、再接続、突合、不整合時停止、クラッシュ復旧の回帰がない。安全機能そのものが未実装であることに加え、その後の実装を固定するテスト戦略もまだないため大きく減点した。

### DX / セキュリティ

**小計: +1 / -3 = -2点**

Elixir 1.18.3 / OTP 27 の開発 image 固定は再現性に寄与する（`Dockerfile:2-15`）。しかし README は「Umbrella 本体は手順4以降」とする古い状態で（`README.md:9-14`）、完了済みアーカイブ（`01-bootstrap-umbrella-and-docker.md:1-7`）と矛盾する。新規参加者が実際の起動・テスト手順へ到達しにくい。

また依存は多いが（`apps/ui/mix.exs:47-78`）、deps audit、Dependabot、SBOM 等の脆弱性管理がない。API key はまだ実装されていないため漏洩は確認されなかったが、将来の bitFlyer key について「出金権限なし」をコードや起動検査で保証する仕組みも現段階にはない。

### プロジェクト全体設計

**小計: +3 / -2 = +1点**

Vision は利益より資金保全を優先し（`vision.md:1-18`）、Architecture はアプリ境界、モード、永続対象、起動順序、発注経路まで具体化する（`overview.md:62-145`）。設計文書の品質は高い。

反面、その大部分はまだコードになっておらず、README も現状を誤っている。「設計済み」「実装済み」「障害試験済み」「live 解禁可能」を区別する traceability がないため、文書の完成度が実装の安全性と誤認される危険がある。

## 実行検証

### mix precommit

2026-09-08、次を実行した。

```text
docker compose run --rm app mix precommit
```

結果は **失敗（exit 1）**。ルートに `preferred_envs: [precommit: :test]` がなく MIX_ENV=dev のまま UI test をコンパイルし、test support の `UiWeb.ConnCase` がロードされなかった。

```text
error: module UiWeb.ConnCase is not loaded and could not be found
test/ui_web/live/status_live_test.exs:2
```

UI 子アプリの alias に `format` が含まれるため、この失敗実行は追跡対象ファイルを自動整形した。評価文書以外を変更しないよう、その差分は実行後に復元した。

切り分けとして次を実行した。

```text
docker compose run --rm -e MIX_ENV=test app mix test
```

これは **成功（exit 0）**。`bitflyer` は doctest 1 + test 1、`ui` は test 6、合計8件が失敗0だった。したがってテスト本体は現状通るが、共通品質ゲートの環境指定と副作用が壊れている。

`docker compose config --quiet` も **成功（exit 0）** した。

## 総評

設計は強いが、実体は「自動売買システム」ではなく「Phoenix / Ash / PostgreSQL が Compose で起動する骨格」である。二アプリ境界、Repo 所有権、dry_run 既定、localhost 公開、秘密情報分離は良い出発点であり、無計画な実装ではない。

しかし Vision が最優先する Safety / Recoverable / Idempotent の実装はほぼゼロである。risk-manager、冪等 executor、注文等の永続状態、起動突合、stale gate がない以上、現時点で live はもちろん paper 運用にも進めない。特に `TRADE_MODE=live` という文字列だけが先に存在し、解禁条件がない点は将来の誤操作リスクになる。

次の優先順位は、(1) ルート precommit と CI、(2) 永続注文状態と boot halt / reconciliation、(3) market-data freshness と fail-closed risk、(4) 冪等 executor と dry_run / paper 非送信テスト、(5) readiness / observability である。戦略の収益性や高機能 UI は、その後でよい。

**最終評価: +20 / -57 = -37点**
