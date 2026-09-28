# この Windows ホストから watch-ready の常駐を外す。
# タスクを止め、登録を消し、wrapper（READY_URL を含む）を消す。
# 証跡ログ %LOCALAPPDATA%\bitflyer\watch-ready.log は残す。
#
#   powershell -NoProfile -File bin/unregister-watch-ready-task.ps1
#
# 登録: bin/register-watch-ready-task.ps1

$ErrorActionPreference = "Stop"

$taskName = "BitflyerWatchReady"
$stateDir = Join-Path $env:LOCALAPPDATA "bitflyer"
$wrapper = Join-Path $stateDir "watch-ready.task.ps1"
$evidence = Join-Path $stateDir "watch-ready.log"

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($null -eq $task) {
    Write-Output "task $taskName was not registered"
}
else {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output "unregistered $taskName"
}

if (Test-Path -LiteralPath $wrapper) {
    Remove-Item -LiteralPath $wrapper -Force
    Write-Output "removed wrapper $wrapper"
}

Write-Output "evidence log left at $evidence"
