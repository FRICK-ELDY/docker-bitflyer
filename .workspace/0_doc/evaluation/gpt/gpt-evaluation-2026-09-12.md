# docker-bitflyer 第2評価者 総合評価レポート（2026-09-12）

| 項目 | 内容 |
|:---|:---|
| 評価日 | 2026-09-12 |
| 評価者 | GPT-5.6 Sol（第2評価者） |
| 対象コミット | `1cfb413858a6d55aee8423e82cdafa3084b18f31` — Merge pull request #86 |
| 基準の正本 | [vision.md](../../vision.md) / [architecture/overview.md](../../architecture/overview.md) |
| 前回自系統 | [gpt-evaluation-2026-09-10_2.md](./archive/2026-09-10_2/gpt-evaluation-2026-09-10_2.md) |
| 詳細 | [強み](./gpt-specific-strengths-2026-09-12.md) / [弱み](./gpt-specific-weaknesses-2026-09-12.md) / [提案](./gpt-specific-proposals-2026-09-12.md) |

**相手評価者の当日文書および `.workspace/0_doc/evaluation/opus/` 配下は参照していない。** 現行 HEAD のコード、テスト、設定、CI、正本文書と、自系統の前回 archive だけを根拠に評価した。

## 採点基準

| 区分 | 基準 |
|:---:|:---|
| +1〜+5 | 正しい実装から、個人プロジェクトとして卓越した実装まで |
| -1〜-5 | 軽微な改善余地から、資金保全・復帰を失う致命的欠陥まで |
| 0 | 現時点を批判せず、実装すれば価値が上がる提案 |

## 総合スコア

| 区分 | 加点 | 減点 | 純点 | 提案件数 |
|:---|---:|---:|---:|---:|
| 今回 | **+84** | **-19** | **+65** | **7** |
| 前回 GPT（2026-09-10_2） | +66 | -33 | +33 | 7 |
| 変化 | +18 | 14点改善 | **+32** | 0 |

純点は大幅に伸びた。前回の3大 live ブロッカーである連続部分約定価格、FXにspot残高を当てる問題、private Decode の構造 skip は、現行コードで解決を確認した。OrderRate、post-place同期、含み損、Status、Fill証跡、halt cancel、外部監視手順、contract、auditにも実装が入っている。

ただし **純点 +65 は live 解禁を意味しない。** コードを縦に追うと、通常約定後の `BalanceSnapshot` tip を前進させる経路がない。初回 baseline と取引所残高の完全一致で Ready になっても、一度の約定で実残高が変わると次回周期突合または再起動は必ず `balance_mismatch` になる。しかも既存 tip を承認更新する入口もない。これは「安全に止まる」だけで「安全に再開できる」状態ではなく、24/365 live の価値命題に対する新たな致命的ブロッカーである。

## 主要結論

1. **前回の部分約定誤算は解決した。** execution ID・価格・取引所時刻を1件ずつ取り込み、remote全量とdeltaの二重coverage、DB一意制約、DB reloadを挟む連続部分約定テストがある。
2. **FX誤モデルはspot限定で解決した。** 既定は `BTC_JPY`。live起動時のMarketData allowlistとRisk認可の双方が `Product.spot?/1` を要求する。FX collateralは適切にbacklogへ退いた。
3. **Decode構造skipは解決した。** 未知side/status・必須ID欠落はlist全体のpayload errorとなり、Reconcileは `invalid_exchange_payload` でhaltする。
4. **資金保全の部品は強い。** Atomic OrderRate、AuthorizedOrder、DailyLoss/BalanceCache barrier、equity HWM、post-place halt、submission_unknown、SIGTERM drain、理由別cancel-allは同種個人プロジェクトの平均を明確に上回る。
5. **しかしlive残高の正本更新が欠落する。** 約定後のBalanceSnapshot appendがないため、次回突合と再起動復帰が成立しない。テスト522件が緑でも、この縦貫通は試験されていない。
6. **損失はまだgrossである。** live手数料がFill/DailyLoss/Equityへ入らず、口座equityと内部equityが一致しない。
7. **観測上STOPPEDでも短時間はRisk認可可能である。** Status/readyはFeed断を即時検知するが、実発注ゲートはCache鮮度切れまで閉じない。

## improvement-plan P0–P2「完了」主張の判定

| 優先 | # | 項目 | 判定 | 現行コード根拠 |
|:---:|:---:|:---|:---:|:---|
| P0 | 1 | 部分約定の増分価格 | **解決** | `live_fills.ex:365-492` がexecution単位でcoverage・価格・notionalを反映。`live_fills_test.exs:248-320, 641-720` |
| P0 | 2 | FX証拠金 or spot限定 | **解決** | `config.exs:57-65` は `BTC_JPY`、`live_safety.ex:41-70` と `risk.ex:215-235` が非spotを拒否 |
| P0 | 3 | Decode構造fail-closed | **解決** | `decode.ex:18-28, 133-223, 351-377`。skip allowlistは空 |
| P0 | 4 | OrderRate原子的予約 | **解決** | `order_rate.ex:153-198` でreserve/commit/releaseを直列化。並行試験あり |
| P0 | 5 | live fill同期整理 | **解決** | 認可前syncは `system.ex:392-395` の一回。受注後失敗は `live.ex:49-74` でhaltし成功と分離 |
| P1 | 6 | BalanceCache.load_latest | **解決** | `balance_cache.ex:667-670` は `BalanceSnapshot.latest_tips/1`。DISTINCT ON正本へ委譲 |
| P1 | 7 | FailureRate再起動復元 | **解決** | warm失敗はunsynced、Risk認可は `risk.ex:261-275` で拒否 |
| P1 | 8 | Fill証跡 | **解決** | `fill.ex:120-125` と migration `20260912130000_add_fills_execution_evidence.exs:18-29` |
| P1 | 9 | Status / ready統一 | **部分解決** | UIとHealthは `market_feed_gate/2` を共有。ただし `operational_status.ex:10-15` の記載どおりRiskはFeed断を直接見ない |
| P1 | 10 | 未約定期限 / halt cancel-all | **部分解決** | 理由別cancelと再試行Gateは実装。通常open ageは `config.exs:20-24` で `:infinity`、runtime上書きなし |
| P2 | 11 | 含み損 / equityゲート | **部分解決** | realized+Position×LTPとHWMは認可・Fill後・周期・resumeへ接続。ただしlive手数料を含まず口座net equityではない |
| P2 | 12 | 外部監視 | **部分解決** | `prod.md:99-181` と `watch-ready.sh` は具体的。ただし別ホスト実配備は未確認、永続時系列と通知retryなし |
| P2 | 13 | Status情報密度 | **解決** | `exposure.ex:82-117` と `status_live.ex:168-420` に建玉・未約定・残高・損益・復帰手順 |
| P2 | 14 | 実API contract / Game Day | **部分解決** | 公開実corpus Stage 0は実施。`game-day.md:100-116` はprivate skipped、障害注入・復帰未実施 |
| P2 | 15 | deps.auditゲート分離 | **解決** | `ci.yml:73-131` が別jobでadvisory検出をfail。Actions SHA pin・Dependabotあり |

「完了」15件のうち、コード上で **解決10 / 部分解決5 / 未解決0**。ただしこの表とは別に、live残高tip不前進という新規P0が見つかった。

## 自系統前回マイナス点の解決状況

| 前回指摘 | 前回点 | 判定 | 根拠・残差 |
|:---|---:|:---:|:---|
| 複数回部分約定の増分価格 | -5 | **解決** | execution単位記帳＋coverage＋一意制約＋連続部分約定試験 |
| 既定FXにspot残高モデル | -5 | **解決** | 既定 `BTC_JPY`、live起動と認可の二重spot制約 |
| Decode構造skip | -4 | **解決** | 未知side/status/ID欠落でsnapshot全体失敗 |
| OrderRate check-then-act | -3 | **解決** | authorize時のGenServer原子予約 |
| post-place sync握り | -2 | **解決** | `fill_sync_failed` halt、`order_accepted: true` |
| 未約定期限 / halt cancel-all | -2 | **部分解決** | halt cancelは解決。通常期限は既定無効 |
| 購読ACK | -2 | **未解決** | `subscribe/2 :ok` を成立扱い。ACK id/timeoutなし |
| 実現損のみ・遅延halt | -3 | **部分解決** | 含み損HWMとFill後enforceは解決。live fee未計上 |
| 外部監視未閉 | -3 | **部分解決** | 手順・探針・heartbeatは実装。実配備/時系列/retryは未証明 |
| 実API契約薄い | -2 | **部分解決** | 公開実corpusあり。private・Stage2以降なし |
| Status-ready不一致 | -1 | **解決** | UI/Health classifier共有。ただしRiskとの残差を新たに評価 |
| deps.audit非ゲート | -1 | **解決** | Hex advisory検出時fail、Actions SHA pin |

## 新規に確認したliveブロッカー

### BalanceSnapshotが一約定後に前進しない

現行のデータフローは次のとおりである。

1. baselineが取引所のJPY/BTCを `BalanceSnapshot` に一度だけ書く。
2. Reconcileはそのtipと `getbalance` のamount/availableが完全一致したときだけ成功する。
3. live FillはOrder/Fill/Positionを更新するがBalanceSnapshotは更新しない。
4. 約定により取引所JPY/BTCが変わる。
5. 次回周期突合または再起動でtipと取引所残高が不一致になりhaltする。
6. baselineは既存tipを更新しないため、通常の承認復帰経路もない。

この欠陥は発注直後の二重発注ではなく、安全側に停止する。しかし「一度だけ発注できるbot」は24/365の自動売買基盤ではなく、再起動後のRecoverableも満たさないため `-5` とした。

## live 解禁の可否

**不可。`TRADE_MODE=live` での実発注をまだ解禁してはならない。**

最低限の解除条件:

1. live execution・手数料・残高差分を同じ会計へ接続し、説明可能な差分だけ `BalanceSnapshot` tipを前進させる。
2. 約定→部分約定→周期突合→プロセス再起動→Ready復帰を、実応答準拠fixtureと最小ロットGame Dayの双方で確認する。
3. live手数料をDailyLoss/Equityへ含める。
4. Riskの実発注ゲートへFeed接続を入れ、Status STOPPED と実際の認可を一致させる。
5. liveの通常未約定期限を有限値で起動時必須にする。

observe-only live、公開/署名GET contract、paper Stage 2までは有用である。実発注Stage 3は上記修正後に限る。

## 実行検証結果

| コマンド | 結果 |
|:---|:---|
| `docker compose run --rm -e MIX_ENV=test app mix precommit` | **成功**。bitflyer: 1 doctest + 483 tests、ui: 38 tests、0 failures |
| `docker compose config --quiet` | **成功** |
| `docker compose -f compose.prod.yaml --env-file .env.prod config --quiet` | **成功**（`.env.prod` あり） |
| `docker compose run --rm app mix deps.audit` | **成功**。`No vulnerabilities found.` |

compile warnings は0。テスト出力には意図的な故障注入ログが多数あり、`resume_test` のpersist失敗ケースで意図的なruntime warningが1件出たが、品質ゲートは終了コード0である。

未実行・非保証:

- 実bitFlyer private GET、live発注・取消、実手数料、複数部分約定
- paper Game Day Stage 2
- 本番ホストでの長時間稼働、別ホスト監視ジョブの実配備確認
- backupの隔離restore
- GitHub tag依存・コンテナOSの脆弱性scan

## 観点別小計

| 観点 | 加点 | 減点 | 小計 |
|:---|---:|---:|---:|
| market-data | +5 | -4 | +1 |
| strategy | +7 | 0 | +7 |
| risk-manager | +17 | -3 | +14 |
| order-executor / recovery | +19 | -7 | +12 |
| datastore / cache / OTP | +10 | 0 | +10 |
| observe | +7 | -2 | +5 |
| apps/ui | +4 | 0 | +4 |
| Docker / config | +3 | 0 | +3 |
| CI / CD / security | +5 | -1 | +4 |
| テスト / 文書 / 取引完成度 | +7 | -2 | +5 |
| **合計** | **+84** | **-19** | **+65** |

`BalanceSnapshot` tip不前進 `-5` と未約定期限 `-2` は order-executor/recovery、live fee `-3` は risk、契約未実施 `-2` はテスト/取引完成度へ計上した。

## 最終所見

前回からの改善は本物である。特にexecution単位Fill、原子的OrderRate、strict Decode、spot二重制約、equity HWM、post-place halt、理由別cancel、Status exposure、SHA pin付きCIは、単なるファイル追加ではなく相互接続と回帰を伴う。加点を増やす根拠は十分にある。

一方、自動売買で最も危険なのは「部品が揃ったためlive可能と思うこと」である。現行コードは約定を正しくFillへ記帳できても、その約定で変化した取引所残高を次の永続正本へ安全に進められない。結果として一約定後の再同期・再起動復帰が成立しない。さらに手数料を損失へ含めず、Feed断とRiskゲートにも数秒の意味論差がある。

したがって評価は **強いpaper/observe-only基盤、live実発注は不合格**。次の最優先は新機能ではなく、execution・fee・BalanceSnapshot・reconcileを一つの説明可能な会計トランザクションへ閉じることである。
