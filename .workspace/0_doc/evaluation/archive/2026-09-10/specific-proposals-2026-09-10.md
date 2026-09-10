# 提案（0点）の統合一覧 2026-09-10

根拠: [opus-specific-proposals](./opus/opus-specific-proposals-2026-09-10.md) / [gpt-specific-proposals](./gpt/gpt-specific-proposals-2026-09-10.md)  
方針: 必須欠如は weaknesses 側。ここは実装すれば価値が上がる前向きな次手のみ。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| 0 | 現時点では存在しないが、実装すればプロジェクトの価値を高める提案 |

---

## 取引ドメインの厚み

- **`AuthorizedOrder` opaque 型** `0`
  > Risk 成功時のみ返し、executor はそれ以外を受けない。境界を型で固定。
  > 出典: Opus（前回 GPT 提案の継続）

- **Fill / Execution 履歴 Resource（損益正本）** `0`
  > 日次損失の実効化と部分約定・手数料の根拠。weaknesses の P0 #5 解決の実装手段でもある。
  > 出典: Opus / GPT

- **shadow strategy と段階的 live 解禁** `0`
  > 同一経路で意図だけ比較し、最小ロットへ段階移行。
  > 出典: GPT

- **paper の手数料・スリッページモデル** `0`
  > 本番楽観バイアスを減らす。
  > 出典: Opus

- **注文状態機械のプロパティベーステスト** `0`
  > StreamData で冪等キー・金額・状態遷移を網羅。
  > 出典: 両評価者

---

## 運用・復旧

- **Kill switch（外部から即 halt）** `0`
  > Discord / StatusLive / mix から即停止。
  > 出典: Opus

- **未約定 TTL と滞留の自動処理** `0`
  > 指値が残ったままの資金拘束を防ぐ。
  > 出典: Opus

- **復旧後の段階的サイズランプ** `0`
  > resume 直後にフルサイズで戻さない。
  > 出典: Opus

- **StatusLive からの resume / reconcile_now** `0`
  > remote console 依存を減らす（認証必須）。
  > 出典: Opus

- **外部 heartbeat と paper Game Day** `0`
  > Discord 死活と障害注入演習。
  > 出典: 両評価者

- **注文ライフサイクルと資金保全 SLO の表示** `0`
  > StatusLive / ドキュメントに数値目標。
  > 出典: GPT

---

## セキュリティ・配布

- **SBOM・イメージ署名（cosign）・provenance** `0`
  > 出典: 両評価者

- **deps.audit を重大度ベースのゲートへ段階移行** `0`
  > 現状は可視化のみ。
  > 出典: GPT

- **GitHub タグ依存の脆弱性可視化** `0`
  > heroicons 等は Hex advisory 外。
  > 出典: Opus

- **バックアップ restore drill の自動化** `0`
  > 出典: 両評価者

- **実 API fixture の差分検知ジョブ（CI 外・承認付き）** `0`
  > 出典: GPT

---

## 意図的に後回し（評価対象外に近い提案）

- 戦略アルゴリズムの高度化・板の本格購読・裁量 UI・複数取引所・ML 基盤
