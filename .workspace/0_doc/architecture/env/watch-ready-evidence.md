# ready 常駐の実施記録（P1 #5）

最終更新: 2026-09-29
関連: [prod.md](./prod.md) / [game-day.md](./game-day.md) / `bin/watch-ready.sh` / `bin/watch-ready.ps1`

完了条件は、作業PCの `BitflyerWatchReady` が `/health/ready` を引き、失敗が証跡ログに残り、解除手順があること。専用の監視PCは完了条件にしない。下の「常駐（2026-09-29）」が同じ条件を満たす。2026-09-13 の探針記録は残し、完了の事実は取り消さない。

## 役割

| 役割 | この記録での実体 |
| --- | --- |
| 監視ホスト | 作業用 PC `FRICK`（Windows 11、Vision の VLAN3） |
| 取引プロセス | 同一 PC 上の開発 Compose `app`（`127.0.0.1:4000`） |
| 探針 | `bin/watch-ready.ps1`（bash 版と同契約） |

開発 Compose をこの作業 PC で動かしているあいだ、監視と取引は **同じ物理ホスト** に乗る。
到達不能ドリルはホスト死と同じ失敗信号（接続不能）を外から見た記録である。
VLAN1 本番 PC を `READY_URL` に差し替え、この作業 PC で常駐させれば、取引ホスト死の検知になる。

## 実施（2026-09-13 UTC）

| 項目 | 記入 |
| --- | --- |
| 実施日 (UTC) | 2026-09-13 |
| 実施者 | 開発（作業 PC `FRICK`） |
| 監視 OS | Microsoft Windows NT 10.0.26200.0 |
| 探針 | `bin/watch-ready.ps1` |
| 常駐登録 | 未登録（`bin/register-watch-ready-task.ps1` は手順のみ。取引ホストでは動かさない） |

### A. 非 ready を人が確認

対象: `http://127.0.0.1:4000/health/ready`（認証なし。URL は証跡ログに書いていない）

開発 `app` は bind mount 後の `config/config.exs` 変更で Code Reloader が CompileError。
コンテナは Up（Compose 上は unhealthy）。`/health/ready` は JSON ではなく HTML 500。

```
2026-09-13T00:49:02Z result=fail http=500
ready probe failed http=500
exit=1
```

人が確認: HTTP 200 かつ `"status":"ready"` ではないので探針は失敗。終了 1。

### B. 到達不能（ホスト死と同じ信号）

対象: `http://127.0.0.1:3999/health/ready`（listen なし。接続不能）

`READY_LOOP=1` `READY_INTERVAL=1` `READY_STRIKES=3` `READY_TIMEOUT=2` で常駐相当を短時間走らせた。

```
2026-09-13T00:49:26Z result=fail http=000
2026-09-13T00:49:30Z result=fail http=000
2026-09-13T00:49:33Z result=fail http=000
2026-09-13T00:49:33Z result=alert http=n/a strikes=3
ready watch alert strikes=3
```

人が確認: 連続 3 失敗で `ready watch alert` が出た。監視プロセスは対象ポートの死と一緒には消えていない。

## 常駐の付け方（監視ホストだけ）

```powershell
$env:READY_URL = "http://<vlan1-prod>/health/ready"
powershell -NoProfile -File bin/register-watch-ready-task.ps1
Start-ScheduledTask -TaskName BitflyerWatchReady
```

ログオン時にも同じタスクが起動する。wrapper と実行ログは `%LOCALAPPDATA%\bitflyer\`（リポジトリ外）。
公開面が loopback のみなら Tailscale / SSH トンネルで監視ホストから到達させる（[prod.md](./prod.md)）。

## 常駐の外し方

監視ホストで、リポジトリのルートから実行する。

```powershell
powershell -NoProfile -File bin/unregister-watch-ready-task.ps1
```

このスクリプトが行うことは次のとおり。

1. タスク `BitflyerWatchReady` が走っていれば止める
2. タスクの登録を消す。次のログオンでは起動しない
3. `%LOCALAPPDATA%\bitflyer\watch-ready.task.ps1` を消す。ここには `READY_URL` が入っている

`%LOCALAPPDATA%\bitflyer\watch-ready.log` は残す。消すときはそのファイルだけを削除する。

確認:

```powershell
Get-ScheduledTask -TaskName BitflyerWatchReady
```

登録が無ければ「タスクが存在しない」旨のエラーになる。それが外れた状態である。

## 常駐（2026-09-29）

作業 PC `FRICK` に、開発 Compose の `http://127.0.0.1:4000/health/ready` へ向いた常駐を登録した。P1 #5 はこの配備で完了とする。

| 項目 | 記入 |
| --- | --- |
| 実施日 (UTC) | 2026-09-29 |
| 監視ホスト | 作業用 PC `FRICK` |
| READY_URL | 開発 Compose `127.0.0.1:4000/health/ready` |
| タスク | `BitflyerWatchReady`。登録確認時の State は Running |
| 証跡 | `%LOCALAPPDATA%\bitflyer\watch-ready.log` に `2026-09-28T17:28:41Z result=fail http=000` と `2026-09-28T17:29:43Z result=fail http=000` |
| 解除 | `bin/unregister-watch-ready-task.ps1` |

## まだ閉じないこと

- ホスト exporter の別ホスト scrape（prod.md の別項）
- Discord HEARTBEAT 欠落の別経路
