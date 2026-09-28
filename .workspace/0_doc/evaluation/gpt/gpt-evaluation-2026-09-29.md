# docker-bitflyer 第2評価者 総合評価 2026-09-29

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-29 |
| 種別 | **同日上書き再評価**（P1 #3 実装・P1 #5 完了後） |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 基準 | `.workspace/0_doc/vision.md` / `.workspace/0_doc/architecture/overview.md` / `.cursor/rules/evaluation.mdc` |
| 対象コミット | `80c486f` |
| 詳細 | [strengths](./gpt-specific-strengths-2026-09-29.md) / [weaknesses](./gpt-specific-weaknesses-2026-09-29.md) / [proposals](./gpt-specific-proposals-2026-09-29.md) |

第1評価者の `opus/` 配下および当日のまとめ文書は参照せず、朝の自系統下書きを起点に現行コード・テスト・証跡を再読した。点数は現状システム全体の積み上げであり、閉じた欠陥は減点に残さず、同一設計判断は一度だけ加点した。

## 総合スコア

| 加点 | 減点 | 純点 |
|---:|---:|---:|
| **+65** | **-1** | **+64** |

詳細ファイルの項目合計は、加点 `+65`、減点 `-1`、純点 `+64` と一致する。

## 観点別小計

| 観点 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 技術評価層 — apps/bitflyer | +39 | -1 | +38 |
| 技術評価層 — apps/ui | +2 | 0 | +2 |
| 技術評価層 — 実行基盤 / 設定 | +10 | 0 | +10 |
| 横断評価層 | +14 | 0 | +14 |
| **合計** | **+65** | **-1** | **+64** |

## P1 完了宣言の再検証

### P1 #3 HWM 強制終了窓

**採用（完了）。**

非 suspend の `PeakWriter.enqueue/4` は upsert と DailyLoss ack が `:done` になるまで `:ok` を返さず、失敗時は pending を残して `{:error, :unsynced}` を返す（`peak_writer.ex:153-175,286-299`）。`DailyLoss.record_peak/3` も write-behind 完了後にのみ認可成功を返す（`daily_loss.ex:293-335,392-403`）。

回帰 `write-behind success leaves the DB peak after both processes are discarded` は認可成功後に PeakWriter を kill し、DailyLoss を `reinit` して DB から 160000 を復元する（`peak_writer_test.exs:139-158`）。「認可が返ったあと PeakWriter を捨てて DailyLoss を DB から読み直しても高値が残る」という完了の見方を満たすため、従来の `-2` を外した。

### P1 #5 作業 PC の readiness 常駐

**採用（完了）。**

2026-09-29 に作業 PC `FRICK` の `BitflyerWatchReady` が Running であり、`/health/ready` の到達失敗が `%LOCALAPPDATA%\bitflyer\watch-ready.log` へ記録された証跡がある（`watch-ready-evidence.md:96-108`）。登録スクリプトはログオン起動と再起動設定を持ち（`register-watch-ready-task.ps1:18-54`）、解除スクリプトはタスク停止・登録削除・URL を含む wrapper 削除を行う（`unregister-watch-ready-task.ps1:10-32`）。

「作業 PC の BitflyerWatchReady が `/health/ready` を引き、失敗が証跡ログに残り、解除手順がある」という完了の見方を満たすため、従来の `-2` を外した。同じ PC 自身の停止を検知できない残差は、この見方の達成を否定せず 0 点提案へ移した。

## 主な強み

1. live 起動突合が権限・時計・Fill・残高・spot 在庫・未約定を同じ fail-closed シーケンスへまとめ、取引所先行 / 内部先行の双方を限定再試行で救済する。
2. raw command が Executor へ入れず、opaque なワンショット認可トークンと内部 ID 冪等性で Risk 迂回・二重送信を構造的に防ぐ。
3. HWM は認可成功より前に単調 DB upsert を完了し、失敗を unsynced に倒すため、認可後のプロセス消失でも日次高値を復元できる。
4. WS ACK、再接続、silent stall、LTP / book 二層、鮮度・時計・spread の責務分離が明確である。
5. readiness pull は作業 PC の常駐タスク、失敗証跡、明示的な解除手順まで運用可能な形で閉じている。

## 残る減点

- **live 成行買いの拘束が最良 ask の数量超過を覆わない** `-1`
  > ticker に気配数量がないため、板を歩いた平均約定価格が best ask を超える分を hold できない（`risk.ex:821-825`）。深さ付き板または保守的 slippage buffer で改善すべきだが、取引所残高拒否という最終防壁があり、今回の live 解禁を単独で妨げる重大度とはしない。

## live 解禁可否

**可。**

P1 #3 と P1 #5 はどちらも、所有者が定めた完了の見方を現行実装・回帰・運用証跡で満たす。残る `-1` は live 成行買いの板厚超過分の内部拘束であり、改善優先度は高いが、現状には取引所残高拒否と既存 Risk 上限があるため解禁ブロッカーには据えない。実運用時は Architecture に記載された当日 confirm、Ready、有限 open age、spot 専用口座、権限検査など既存の全ゲートを満たすことが前提である。

## 実行検証

| 項目 | 結果 |
|:---|:---|
| `git rev-parse --short HEAD` | `80c486f` を確認 |
| `mix precommit` | **本再評価では未再実行**。親が #3 実装後に成功を確認済み（bitflyer doctest 1 + テスト 668、ui 38、失敗 0） |
| `mix test` / Docker | **本再評価では未実行**（指示どおり） |

## 現状の一文

**取引所事実との突合、二重発注防止、認可前 HWM 永続化、停止時 drain、readiness 常駐証跡が揃い、既存の live 安全ゲートを守る条件で live 解禁可能な段階に達した。**
