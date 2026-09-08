# docker-bitflyer 第2評価者 提案（2026-09-08）

## 採点基準

| 点数 | 基準 |
|:---:|---|
| 0 | 現時点では存在しないが、実装すれば価値を高める提案 |

## テスト戦略

### 生成・モデルベーステスト

- **Decimal と冪等キーのプロパティベーステスト** `0`
  > 発注基盤の通常例テストが揃った後、StreamData 等で価格・数量の境界値、丸め、最小ロット、同一 intent の反復を生成すると、人手で列挙しにくい資金計算と二重発注の欠陥を発見しやすい。`OrderIntent` の「同一 ID は外部送信が高々1回」を不変条件にする。
  >
  > 対象ファイル: `apps/bitflyer/test/`

- **起動シーケンスのモデルベーステスト** `0`
  > `restoring / reconciling / syncing / ready / halted` を状態機械として実装した後、任意順の DB断、API 5xx、WebSocket切断、プロセスクラッシュを生成し、「未同期では Ready にならない」を検査する。Recoverable の証拠を例示テストより強くできる。
  >
  > 対象ファイル: `apps/bitflyer/test/`

### 外部 API 契約

- **bitFlyer fixture の契約テストと記録再生** `0`
  > 認証情報を使わず、公開 REST / WebSocket payload の匿名化 fixture を版管理し、decoder と正規化イベントの契約を固定する。API field の追加・欠落・未知 status に対する fail-closed を CI で再現できる。
  >
  > 対象ファイル: `apps/bitflyer/test/fixtures/`

## 可観測性

### 運用診断

- **注文ライフサイクルの相関 ID と診断スナップショット** `0`
  > intent ID、internal order ID、exchange order ID、strategy revision、risk decision ID を相関可能にし、秘密値を除外した直近イベントを1つの診断スナップショットとして出力できると、障害後の説明可能性が大きく上がる。通常ログの大量出力とは分離する。
  >
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/observe/`

- **SLO とアラート予算の明文化** `0`
  > market-data age、reconciliation lag、未確定注文滞留、通知到達時間、再起動回数について warning / halt の閾値を定義し、UI・メトリクス・サーキットで同じ値を使う。単なる「監視あり」から運用判断可能な基準へ進められる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

## 運用・復旧

### 障害訓練

- **paper 環境での定期 Game Day** `0`
  > paper 経路完成後、コンテナ kill、DB 一時停止、時計ずれ、WebSocket遮断、API 429/5xx を定期的に注入し、停止・通知・復帰・二重送信なしを計測する。実装済みの安全装置が24/365運用でも機能する証拠になる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/dev.md`

- **バックアップ復元の自動検証** `0`
  > PostgreSQL backup を取得するだけでなく、隔離 DB へ定期 restore し、注文・建玉・RiskHalt の整合制約と起動突合を通す。バックアップの存在ではなく Recoverable を検証できる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/env/prod.md`

## セキュリティ

### サプライチェーン

- **release の SBOM・署名・digest 固定** `0`
  > 本番 image 実装時に SBOM を生成し、署名済み image を digest で Compose に固定すると、意図しない最新版追従と成果物の入れ替えを検出できる。個人運用でも rollback の再現性が上がる。
  >
  > 対象ファイル: `Dockerfile.prod`, `compose.prod.yaml`, `.github/workflows/`

## 開発者体験

### 要求トレーサビリティ

- **安全要件と自動テストの対応表** `0`
  > Vision の Safety / Recoverable / Observable / Idempotent 各要求に、実装 module、test、metric、運用手順を対応付ける。live 解禁レビュー時に「文書にはあるが未検証」を機械的に発見できる。
  >
  > 対象ファイル: `.workspace/0_doc/architecture/`

**提案合計: 0**
