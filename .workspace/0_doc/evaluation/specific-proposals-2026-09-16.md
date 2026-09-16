# 提案（0点）統合一覧 2026-09-16

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では減点せず、実装すれば価値が上がる次段階 |

根拠: [opus-proposals](./opus/opus-specific-proposals-2026-09-16.md) / [gpt-proposals](./gpt/gpt-specific-proposals-2026-09-16.md)。重複は統合。live 解禁前に効くものを上位に置く。

---

## live 解禁プロトコル

- **Stage 3 を 3a（買い1・単位実測）→ 3b（売り1）に割る** `0`
  > Opus。手数料数円で売り側モデルの 5 割推定を消せる。game-day.md / commission-unit-evidence.md に手順を足す。

- **売り fee 帰属を `:base_deduct | :quote_mark` 仮説スイッチにし、両モデルで縦回帰** `0`
  > Opus。観測確定まで設定で持たせる案。ハーネス独立性の弱点と対になる。

---

## risk / market-data

- **HWM write-behind（認可上昇直後に監督下 queue + shutdown drain）** `0`
  > GPT。弱点の crash 窓 `-2` の実装案。

- **HWM upsert を `GREATEST` / Ash upsert に畳む** `0`
  > Opus。`inspect` 衝突検出の根治。

- **ticker を `{ltp, book}` 2 層化し、板欠落でも LTP を残す** `0`
  > Opus。crossed→stale 化の改善。

- **成行拘束を live で ask 基準へ** `0`
  > Opus。弱点 `-1` の具体策。

- **板厚・getboardstate / gethealth ゲート** `0`
  > GPT。spread の次段。

---

## 戦略 / テスト / 観測

- **明示エントリ/エグジットを持つ薄い live 戦略 1 本** `0`
  > Opus（FixedOnce 減点からの移動）。LiveSafety が FixedOnce を禁ずる以上、解禁後に動かす対象が必要。

- **残高会計のプロパティ／状態機械試験** `0`
  > GPT。ハーネス共有誤りリスクの低減。

- **strategy revision canary / 段階上限** `0`
  > GPT。

- **Prometheus / SLO・重要通知の有限 retry** `0`
  > GPT。

- **private execution WS を同期トリガーに併用** `0`
  > GPT。

---

## 運用 / セキュリティ（解禁後でも可）

- **Fill/snapshot retention または「当面なし」の文書化 + DB aggregate** `0`
- **隔離 DB restore の定期証跡** `0`
- **Hex 外 / release image scanner（期限付き例外）** `0`
- **SBOM・署名・digest 配布** `0`
- **Windows/WSL2 長時間 soak 定型化** `0`
- **開発 Dockerfile 非 root・websockex 記録または移行** `0`

---

## 意図的に後回し（Vision 非目標）

- 複数取引所、ML 基盤、裁量高機能 UI、SaaS 化、FX 証拠金本実装
