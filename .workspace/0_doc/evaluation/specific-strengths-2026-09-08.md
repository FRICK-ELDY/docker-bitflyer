# プラス点統合一覧 2026-09-08

初回評価。第1評価者（Opus）と第2評価者（GPT）の独立評価を統合。
詳細の正本: [opus-specific-strengths](./opus/opus-specific-strengths-2026-09-08.md) / [gpt-specific-strengths](./gpt/gpt-specific-strengths-2026-09-08.md)

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1 | 正しく実装されている。問題はないが特筆するほどではない |
| +2 | 業界の一般的なベストプラクティスに沿った、良い設計判断 |
| +3 | 同規模・同種プロジェクトの平均を明確に上回る実装 |
| +4 | プロダクションレベルの自動売買・取引基盤と比較しても遜色ない実装 |
| +5 | このクラスの個人プロジェクトでは見たことがないレベルの卓越した実装 |

---

## プロジェクト全体設計

- **資金保全を中心に据えた Vision / Architecture が具体的** `+3`（採用） / Opus: 横断で +9 相当に分散 / GPT: `+3`
  > Safety first・Recoverable・Observable・起動順序・発注経路・モード表まで固定。同規模初期プロジェクトを明確に上回る。
  > 対象ファイル: `.workspace/0_doc/vision.md`, `.workspace/0_doc/architecture/overview.md`

- **「何を作らないか」を実装前に確定（paper はアプリ分割しない等）** `+2`（採用） / Opus: 文書品質に含む / GPT: 設計文書に含む
  > `apps/paper` 禁止、同じ経路を通さないペーパーは本番で壊れる、第3アプリ禁止が文書と backlog で揃う。
  > 対象ファイル: `.workspace/1_backlog/paper-trade-adapter.md`, `.workspace/0_doc/architecture/overview.md`

- **技術選定の自己評価（tech-stack.md）がある** `+1`（採用） / Opus: 文書に含む / GPT: —
  > Ash の適用範囲・ETS・Umbrella を増やさない判断が明文化されている。
  > 対象ファイル: `.workspace/0_doc/evaluation/tech-stack.md`

---

## 技術評価層 — apps/bitflyer

- **UI → bitflyer の一方向依存を Mix で強制** `+2`（採用） / Opus: `+2` / GPT: `+2`
  > 対象ファイル: `apps/ui/mix.exs`, `apps/bitflyer/mix.exs`

- **`Bitflyer.Repo` が bitflyer に閉じ、Ash を永続疎通の最小に限定** `+2`（採用） / Opus: `+2`+`+2` / GPT: `+2`+`+1`
  > Heartbeat 1 Resource。取引エンティティを意図的に置いていない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/system.ex`

- **`check_database/0` が exception と exit の両方を潰す** `+2`（採用） / Opus: `+2` / GPT: `+1`（UI 側と合算）
  > DB 断でも UI プロセスを巻き込まない。
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/system.ex`

- **UUIDv7・min_pg_version・extensions の明示** `+1`（採用） / Opus: `+1` / GPT: Heartbeat に含む
  > 対象ファイル: `apps/bitflyer/lib/bitflyer/repo.ex`, `apps/bitflyer/lib/bitflyer/system/heartbeat.ex`

- **Endpoint と取引監督が別 Application（兄弟）** `+2`（採用） / Opus: 横断 / GPT: —
  > `Ui.Application` と `Bitflyer.Application` が分離。UI 例外で Repo 以外の取引木を巻き込む構造になっていない（現状取引木は Repo のみ）。
  > 対象ファイル: `apps/ui/lib/ui/application.ex`, `apps/bitflyer/lib/bitflyer/application.ex`

---

## 技術評価層 — apps/ui

- **運用 UI に責務限定・裁量 UI に踏み込まない** `+2`（採用） / Opus: `+2` / GPT: `+2`
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **公開関数経由のみ・取引所 API 非接触** `+2`（採用） / Opus: `+2` / GPT: 境界に含む
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

- **LiveDashboard を `dev_routes` でコンパイル時排除** `+2`（採用） / Opus: `+2` / GPT: —
  > 対象ファイル: `apps/ui/lib/ui_web/router.ex`, `config/dev.exs`

- **主要 DOM ID + i18n テスト** `+2`（採用） / Opus: `+2` / GPT: テスト戦略 `+1`
  > 対象ファイル: `apps/ui/test/ui_web/live/status_live_test.exs`

- **DB 状態の定期再評価と理由表示** `+1`（採用） / Opus: `+1` / GPT: `+1`
  > 対象ファイル: `apps/ui/lib/ui_web/live/status_live.ex`

---

## 技術評価層 — 実行基盤 / 設定

- **開発 Compose の作り込み（health / depends_on / localhost / 名前付きボリューム）** `+3`（採用） / Opus: `+3` / GPT: `+2`
  > Windows bind mount 上の Mix 劣化への対処も含む。
  > 対象ファイル: `compose.yaml`

- **entrypoint が常駐時だけ setup、単発 mix は素通し** `+2`（採用） / Opus: `+2` / GPT: —
  > 対象ファイル: `bin/docker-entrypoint.sh`

- **`.gitattributes` で bin を LF 固定（実障害の再発防止）** `+2`（採用） / Opus: `+2` / GPT: —
  > 対象ファイル: `.gitattributes`

- **TRADE_MODE 既定 dry_run が一貫** `+2`（採用） / Opus: 設定に含む / GPT: `+2`
  > runtime / compose / `.env.example` / `trade_mode/0`。
  > 対象ファイル: `config/runtime.exs`, `compose.yaml`, `.env.example`

- **秘密情報の実行時注入と `.gitignore` 面防御** `+2`（採用） / Opus: `+2` / GPT: `+2`
  > 対象ファイル: `config/runtime.exs`, `.gitignore`, `Dockerfile`

- **イメージ・依存のバージョンピン** `+1`（採用） / Opus: `+1` / GPT: DX `+1`
  > 対象ファイル: `Dockerfile`, `compose.yaml`

- **prod の force_ssl / HSTS 基礎** `+1`（採用） / Opus: セキュリティに含む / GPT: `+1`
  > 対象ファイル: `config/prod.exs`

---

## 横断 — セキュリティ / プロセス

- **ToDo / archive / backlog による作業ステージ管理** `+2`（採用） / Opus: 文書 / GPT: —
  > CI・CD が未着手でも計画が文書化されている。
  > 対象ファイル: `.workspace/2_todo/`, `.workspace/3_archive/`

- **OTP / Elixir 選定と単一ホスト Compose 方針の整合** `+1`（採用） / Opus: tech-stack / GPT: 設計に含む
  > 対象ファイル: `.workspace/0_doc/evaluation/tech-stack.md`

---

## 小計（採用）

| 大分類 | 加点 |
|:---|---:|
| プロジェクト全体設計 | +6 |
| apps/bitflyer | +9 |
| apps/ui | +9 |
| 実行基盤 / 設定 | +13 |
| 横断 | +3 |
| **合計** | **+40** |

### 評価者間の主な相違

| 論点 | Opus | GPT | まとめの判断 |
|:---|:---|:---|:---|
| 加点の総量 | +61（文書・骨格を厚く加点） | +20（実装済みの狭い範囲のみ） | **中間寄り +40**。文書の質は認めるが、未実装を加点で相殺しすぎない |
| entrypoint / gitattributes / DOM ID | 個別に加点 | 薄い or 未計上 | **Opus を採用**（実コード根拠あり） |
| Vision 文書単体 | 横断で高得点 | +3 に集約 | **GPT の +3 を上限感**として採用し、周辺は別項目に分割 |
