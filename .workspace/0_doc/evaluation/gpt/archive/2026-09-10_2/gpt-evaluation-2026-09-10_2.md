# docker-bitflyer 第2評価者 総合評価レポート（2026-09-10_2）

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-10_2（同日2回目） |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 基準 | `.workspace/0_doc/vision.md` / `.workspace/0_doc/architecture/overview.md` |
| 詳細 | [強み](./gpt-specific-strengths-2026-09-10_2.md) / [弱み](./gpt-specific-weaknesses-2026-09-10_2.md) / [提案](./gpt-specific-proposals-2026-09-10_2.md) |

相手評価者の当日文書を判断材料にせず、現行コード、前回 GPT 指摘の対象ファイル、改善計画の「済」主張、テスト実行結果から再評価した。

## 採点基準

| 点数 | 基準 |
|:---:|:---|
| +1〜+5 | 正しい実装から、個人プロジェクトとして卓越した実装まで |
| -1〜-5 | 軽微な改善余地から、資金保全・復帰を失う致命的欠陥まで |
| 0 | 現時点の欠如を責めず、実装すれば価値が上がる提案 |

## 総合スコア

| 区分 | 加点 | 減点 | 純点 |
|:---|---:|---:|---:|
| 技術評価層・横断評価層 合計 | **+66** | **-33** | **+33** |
| 前回 GPT（2026-09-10） | +49 | -45 | +4 |
| 変化 | +17 | +12改善 | **+29** |

## 結論

**総合純点は +33。安全骨格と復旧導線は明確にプロダクション候補へ近づいたが、live 解禁は不可。**

前回の最重要3点のうち、両建て net 正規化と FixedOnce の live 既定は解決した。日次損失と残高も「値を注入しない本番経路で空振りする」状態から、Fill 正本・ETS barrier・reserve/consume/release へ大幅に改善している。しかしコードを縦に追うと、live の複数回部分約定で累積平均価格を差分価格として再利用し、Position 平均と `Fill.realized_pnl` を誤計算する。さらに既定商品 `FX_BTC_JPY` に現物 JPY/BTC 残高モデルを適用し、collateral・証拠金維持率を読んでいない。したがって改善計画 P0 #1/#2 の「済」は部品レベルでは事実だが、実弾対象商品の資金保全としては過大な完了宣言である。

良い点も大きい。submission_unknown の停止と承認付き回収、baseline import、AuthorizedOrder、起動時権限・時計検査、in-flight drain、CD↔CI、StrategyParameterRevision、kill/resume は、単なる雛形でなくコードと回帰を伴う。`mix precommit` も 387 tests + 1 doctest が緑である。問題は骨格の数ではなく、取引所の実レスポンス意味論と FX 商品モデルをまだ正しく表現できていない点にある。

## live 解禁可否

**不可。`TRADE_MODE=live` での実発注を解禁してはならない。**

最低限の解除条件:

1. 複数回部分約定の増分価格・増分 notional を正しく復元し、Position / Fill / DailyLoss を再計算できる。
2. live 対象を spot に限定するか、`FX_BTC_JPY` 用に collateral・レバレッジ・証拠金維持率・未実現損益の Risk モデルを実装する。
3. private snapshot の未知 side・識別子欠落を skip せず fail-closed にする。
4. 2回以上の部分約定、再起動、決済損失、CFD 証拠金を含む実レスポンス準拠テストを通す。
5. read-only 実 API contract と最小ロット Game Day を実施し、監視・取消・復旧まで記録する。

## 前回からの変化

### 解決を確認

- **日次損失の未接続**: Fill 正本と DailyLoss ETS reload が実経路へ接続された（`positions.ex:160-177`, `daily_loss.ex:365-394`）。
- **残高検査の未接続**: BalanceCache は未同期拒否、hold reserve、部分約定 consume、取消 release を実装した（`balance_cache.ex:115-220, 325-510`）。
- **両建て上書き**: 外部 buy/sell を product ごとに net 化してから比較する（`reconcile.ex:280-377`）。
- **FixedOnce live 既定**: live は strategy 既定無効、FixedOnce 有効化拒否、上限 env 必須（`live_safety.ex:21-77`）。
- **不正数値の 0 丸め**: NaN/Inf/欠損数値は `:invalid_number`（`decode.ex:14-72, 279-283`）。
- **baseline / submission_unknown 回収**: hash・操作者・候補曖昧性を扱う正式入口がある。
- **auth / FailureRate / watchdog / InFlight**: 401/403 即 halt、連続拒否、サイレントストール再接続、shutdown drain を確認。
- **source timestamp / permissions / OrderRate warm / CD↔CI / revision**: 対象コードと回帰が存在する。
- **paper FillPricing / AuthorizedOrder / kill switch / 残骸削除**: 対象コードを確認。Heartbeat・Mailer・PageController の source は現行 `lib` から削除され、drop migration がある。

### 未解決または新たに顕在化

- **P0 #1 は部分約定で未完了**: 累積 average price を差分 fill へ誤適用し、実現損失が壊れる。
- **P0 #2 は主対象商品に不適合**: hold の機構は正しいが、`FX_BTC_JPY` で見るべき collateral ではなく spot JPY/BTC を拘束する。
- **P0 #5 は構造面で未完了**: 数値は strict になったが、未知 side 等を skip する。
- **OrderRate は warm 済みだが並行 check/record が非原子的**。
- **Status ALLOWED は Feed 切断を直接見ず、`/health/ready` と不一致**。

## improvement-plan「済」主張の判定

| # | 項目 | 判定 | 根拠 |
|:---:|:---|:---:|:---|
| 1 | 日次損失 | **部分解決** | 一括 fill は実効。連続部分約定の増分価格が誤るため live 正本として未完了 |
| 2 | 残高検査 | **部分解決** | ETS hold は実効。既定 FX 商品に spot 残高を使い collateral 未検査 |
| 3 | 両建て net | **解決** | `net_positions/1` と順序非依存比較あり |
| 4 | live Strategy 安全化 | **解決** | 既定無効、FixedOnce拒否、5上限 env 必須 |
| 5 | Decode strict | **部分解決** | 数値 strict。識別子・未知 side は skip |
| 6–10 | baseline / recover / FailureRate / watchdog / drain | **概ね解決** | 正式入口・停止・回収・競合回帰あり |
| 11–15 | metrics / timestamp / permissions / warm / CD / revision | **概ね解決** | 消費者・起動ゲート・DB warm・CI結合・永続 revision あり。ただし OrderRate 実行時競合は残る |
| 16–19 | paper pricing / AuthorizedOrder / kill / 残骸 | **解決** | 実装・テスト・source 削除を確認 |

よって「P0〜P3 はすべて済」は、そのまま live 解禁根拠にはできない。特に #1 と #2 は資金保全の意味論が未完成である。

## 実行検証結果

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**。bitflyer: 1 doctest + 352 tests、ui: 35 tests、0 failures |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功** |
| `docker compose run --rm app mix deps.audit` | **成功**。`No vulnerabilities found.` |

未実行・非保証:

- 実 bitFlyer API への read-only/live 接続
- 最小ロット実発注・取消・複数回部分約定
- 本番ホストでの長時間稼働、NTP/ディスク/再起動ループ監視
- backup の隔離 restore 試験
- `deps.audit` 対象外の GitHub tag 依存と Actions supply chain

## 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| market-data | +5 | -2 | +3 |
| strategy | +7 | 0 | +7 |
| risk-manager | +11 | -11 | 0 |
| order-executor / recovery | +14 | -9 | +5 |
| datastore / cache / OTP | +10 | 0 | +10 |
| observe | +3 | -3 | 0 |
| apps/ui | +3 | -1 | +2 |
| Docker / config | +3 | 0 | +3 |
| CI / CD / security | +4 | -1 | +3 |
| テスト戦略 / 取引完成度 | +4 | -2 | +2 |
| DX / 全体設計 / 文書 | +2 | -4 | -2 |
| **合計** | **+66** | **-33** | **+33** |

注: Decode の構造 skip `-4` は横断的な契約・全体設計へ計上した。各詳細項目は強み・弱み文書を正本とする。

## 観点別評価

### market-data

#### ✅ プラス点

- **鮮度・再接続・gap-fill・時計ずれが Risk/health へ接続** `+5`
  > `Feed`、`Normalize`、`Cache`、`Risk.check_source_timestamp/3` が一続きである。

#### ❌ マイナス点

- **subscription ACK が未追跡** `-2`
  > socket 書込み成功を購読成功として数え、対象 channel の ACK timeout を持たない。

#### 💡 提案

- **板と流動性ゲート** `0`
  > spread・板厚・sequence を Risk 入力へ加える。

**小計: +5 / -2 = +3点**

### strategy

#### ✅ プラス点

- **依存方向・live 安全既定・revision provenance** `+7`
  > Strategy は System 経由で Risk を通り、live は明示有効化かつ FixedOnce 禁止。Order まで設定由来が残る。

#### ❌ マイナス点

- なし

#### 💡 提案

- **revision 承認と canary** `0`
  > 設定変更の段階適用を可能にする。

**小計: +7 / 0 = +7点**

### risk-manager

#### ✅ プラス点

- **fail-closed 認可・generation barrier・AuthorizedOrder** `+11`
  > 未同期を拒否し、Fill 更新競合と Risk 迂回へ実行時防御がある。

#### ❌ マイナス点

- **FX collateral 不在、実現損限定、OrderRate 競合** `-11`
  > 主対象商品の証拠金を見ず、損失の意味と並行上限に穴が残る。

#### 💡 提案

- **状態機械のモデルベース試験** `0`
  > hold・fill・cancel・unknown の不変条件を生成試験する。

**小計: +11 / -11 = 0点**

### order-executor / recovery

#### ✅ プラス点

- **冪等なモード出口・回収・net 突合・baseline** `+14`
  > 前回の復帰不能点と両建て上書きは実装・手順とも解消した。

#### ❌ マイナス点

- **部分約定価格誤算、post-place 同期失敗の握り、注文期限不在** `-9`
  > とくに累積平均を差分に使う問題は DailyLoss 正本を破壊する。

#### 💡 提案

- **Execution ID 正本化** `0`
  > execution 単位の一意永続化で差分計算と冪等性を単純化する。

**小計: +14 / -9 = +5点**

### datastore / cache / OTP

#### ✅ プラス点

- **永続境界・Decimal・起動復元・graceful drain** `+10`
  > Ash は永続状態、ETS は短期状態に分かれ、起動と停止が安全側である。

#### ❌ マイナス点

- なし（他観点の意味論欠陥はそちらへ計上）

#### 💡 提案

- **隔離 restore の定期自動化** `0`
  > バックアップを実際に復元して RTO/RPO を測る。

**小計: +10 / 0 = +10点**

### observe

#### ✅ プラス点

- **telemetry allowlist と構造化語彙** `+3`
  > 秘密キーを落とし、ドメインイベントを中央化する。

#### ❌ マイナス点

- **外部監視・永続 metrics・通知到達保証がない** `-3`
  > 同一ホスト停止や通知経路断を同一ホストからは検知できない。

#### 💡 提案

- **SLO と外部資金保全ダッシュボード** `0`
  > ready率、open age、損失、証拠金を長期保存する。

**小計: +3 / -3 = 0点**

### apps/ui

#### ✅ プラス点

- **運用 Status と認証付き kill/resume/reconcile** `+3`
  > 裁量発注に踏み込まず、運用責務に限定する。

#### ❌ マイナス点

- **ALLOWED が Feed 接続を見ない** `-1`
  > ready probe と表示上の注文可否が一時的に矛盾する。

#### 💡 提案

- **高危険操作の二者承認** `0`
  > resume 等だけに追加し、kill の即時性は維持する。

**小計: +3 / -1 = +2点**

### Docker / config

#### ✅ プラス点

- **開発と本番 release の分離、非 root、秘密・bind の安全既定** `+3`
  > Dockerfile.prod と compose.prod.yaml は本番形として良い。

#### ❌ マイナス点

- なし

#### 💡 提案

- **本番ホスト hardening の機械検査** `0`
  > Docker daemon、WSL2 時刻、更新制御、ACL をチェックリストから実測へ移す。

**小計: +3 / 0 = +3点**

### CI / CD / security

#### ✅ プラス点

- **precommit 共通化と同一 SHA の CI→CD 強制** `+4`
  > test と prod image build の双方が緑の commit だけを配布する。

#### ❌ マイナス点

- **audit 非ゲート・対象外依存** `-1`
  > Hex advisory 以外と Actions pin を覆わない。

#### 💡 提案

- **SBOM・署名・デプロイ時検証** `0`
  > digest 固定を supply-chain 証跡へ拡張する。

**小計: +4 / -1 = +3点**

### テスト戦略 / 取引完成度

#### ✅ プラス点

- **387 tests + 1 doctest の資金保全回帰** `+4`
  > precommit は全成功し、故障注入・回復経路も広い。

#### ❌ マイナス点

- **実 API 意味論・CFD・複数部分約定の契約試験不足** `-2`
  > テスト緑でも live の中核誤りを検出できていない。

#### 💡 提案

- **read-only contract と最小ロット Game Day** `0`
  > 本番形の事実で fixture を更新し、段階解禁する。

**小計: +4 / -2 = +2点**

### DX / 全体設計 / 文書

#### ✅ プラス点

- **README・Architecture・運用手順の具体性** `+2`
  > baseline、recover、rpc、rollback、backup が実操作へ接続する。

#### ❌ マイナス点

- **private payload の構造欠落を skip する契約** `-4`
  > 資金保全 snapshot で未知 side・ID 欠落を捨て、誤 Ready の余地を残す。

#### 💡 提案

- **コード化された live readiness checklist** `0`
  > 実 API contract、restore drill、監視到達、最小ロット証跡を機械判定する。

**小計: +2 / -4 = -2点**

## 優先課題

1. **P0: live 部分約定の増分価格を修正** — execution 単位で正本化し、Position / Fill / DailyLoss を再検証。
2. **P0: FX collateral risk を実装または live 商品を spot に限定** — 現物残高 hold を FX 安全装置と呼ばない。
3. **P0: private Decode の構造 strict 化** — 未知 side・status・必須 ID 欠落で snapshot 全体を失敗。
4. **P1: Fill 後の損失超過を即 halt** — 次回注文待ちにしない。未実現損益・手数料も段階追加。
5. **P1: OrderRate を原子的 reserve 化** — 並行認可の check-then-act を除去。
6. **P1: open order TTL / cancel-all policy** — halt 理由別に未約定 exposure を閉じる。
7. **P2: Feed ACK と銘柄別 watchdog** — 接続ではなく購読成立を観測。
8. **P2: 外部監視と通知到達保証** — 別ホスト監視、永続 metrics、retry/heartbeat。
9. **P2: 実 API contract / Game Day** — fixture と商品モデルを現実へ合わせる。

## 最終所見

前回の空洞だった P0 群に実装を入れ、停止後の出口まで作った速度と設計力は高い。ただし自動売買では「安全部品が多い」ことより、「取引所が返す累積値を正しく差分化し、取引商品の証拠金構造を正しくモデル化している」ことが優先される。現状は dry_run / paper の安全基盤として強く、live の observe-only 起動にも価値があるが、実発注の資金保全は未証明である。
