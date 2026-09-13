# この Windows 監視ホストに watch-ready の常駐タスクを登録する。
# 取引ホストでは動かさない。READY_URL は VLAN1 の公開面を指す。
# wrapper は %LOCALAPPDATA%\bitflyer に書き、リポジトリには置かない。
#
#   $env:READY_URL = "http://<prod>/health/ready"
#   powershell -NoProfile -File bin/register-watch-ready-task.ps1
#
# 解除: Unregister-ScheduledTask -TaskName BitflyerWatchReady -Confirm:$false

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:READY_URL)) {
    throw "READY_URL is required"
}

$script = Join-Path $PSScriptRoot "watch-ready.ps1"
$stateDir = Join-Path $env:LOCALAPPDATA "bitflyer"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$evidence = if ($env:READY_EVIDENCE) {
    $env:READY_EVIDENCE
}
else {
    Join-Path $stateDir "watch-ready.log"
}

$envPairs = [ordered]@{
    READY_URL      = $env:READY_URL
    READY_LOOP     = "1"
    READY_INTERVAL = $(if ($env:READY_INTERVAL) { $env:READY_INTERVAL } else { "60" })
    READY_STRIKES  = $(if ($env:READY_STRIKES) { $env:READY_STRIKES } else { "3" })
    READY_TIMEOUT  = $(if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "5" })
    READY_EVIDENCE = $evidence
}

$wrapper = Join-Path $stateDir "watch-ready.task.ps1"
$lines = @("`$ErrorActionPreference = 'Stop'")
foreach ($key in $envPairs.Keys) {
    $lines += "`$env:$key = '$($envPairs[$key] -replace "'", "''")'"
}
$lines += "& `"$script`""
Set-Content -LiteralPath $wrapper -Value $lines -Encoding UTF8

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
    "-NoProfile -WindowStyle Hidden -File `"$wrapper`""
)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "BitflyerWatchReady" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Output "registered BitflyerWatchReady evidence=$evidence"
