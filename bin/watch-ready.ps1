# 取引ホストとは別の Windows 監視ホストで /health/ready を引く。
# 同一ホストから叩いてもホスト死は検知できない。
#
# 単発:
#   $env:READY_URL = "https://bot.example/health/ready"
#   powershell -NoProfile -File bin/watch-ready.ps1
#
# 常駐（間隔 60s・連続失敗 3 で stderr に alert）:
#   $env:READY_LOOP = "1"
#   powershell -NoProfile -File bin/watch-ready.ps1
#
# 証跡（追記。URL は書かない）:
#   $env:READY_EVIDENCE = "D:\logs\watch-ready.log"
# 終了 0: 単発が HTTP 200 かつ JSON status=ready
# 終了 1: 単発失敗。READY_LOOP=1 はアラート後も継続（Ctrl+C まで）

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:READY_URL)) {
    throw "READY_URL is required (e.g. https://host/health/ready)"
}

$Url = $env:READY_URL
$Timeout = if ($env:READY_TIMEOUT) { [int]$env:READY_TIMEOUT } else { 5 }
$Loop = if ($env:READY_LOOP) { $env:READY_LOOP } else { "0" }
$Interval = if ($env:READY_INTERVAL) { [int]$env:READY_INTERVAL } else { 60 }
$Strikes = if ($env:READY_STRIKES) { [int]$env:READY_STRIKES } else { 3 }
$Evidence = $env:READY_EVIDENCE

function Test-ReadyBody([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $compact = ((Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue) -replace "\s", "")
    return $compact -like '*"status":"ready"*'
}

function Write-Evidence([string]$Result, [string]$HttpCode, [string]$Extra = "") {
    if ([string]::IsNullOrWhiteSpace($Evidence)) {
        return
    }

    $dir = Split-Path -Parent $Evidence
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $line = "{0:yyyy-MM-ddTHH:mm:ssZ} result={1} http={2}" -f (Get-Date).ToUniversalTime(), $Result, $HttpCode
    if (-not [string]::IsNullOrWhiteSpace($Extra)) {
        $line = "$line $Extra"
    }

    Add-Content -LiteralPath $Evidence -Value $line
}

function Invoke-ReadyProbe {
    $tmp = [System.IO.Path]::GetTempFileName()
    $code = "000"
    $success = $false

    try {
        $curlArgs = @(
            "-sS",
            "-o", $tmp,
            "-w", "%{http_code}",
            "--max-time", "$Timeout",
            $Url
        )
        $code = & curl.exe @curlArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($code)) {
            $code = "000"
        }

        if ($code -eq "200" -and (Test-ReadyBody $tmp)) {
            Write-Evidence "ok" $code
            $success = $true
        }
        else {
            [Console]::Error.WriteLine("ready probe failed http=$code")
            if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0)) {
                [Console]::Error.WriteLine((Get-Content -LiteralPath $tmp -Raw))
            }
            Write-Evidence "fail" $code
        }
    }
    catch {
        $code = "000"
        [Console]::Error.WriteLine("ready probe failed http=$code")
        Write-Evidence "fail" $code
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    return $success
}

if ($Loop -ne "1") {
    if (Invoke-ReadyProbe) {
        exit 0
    }

    exit 1
}

$failCount = 0

while ($true) {
    if (Invoke-ReadyProbe) {
        $failCount = 0
    }
    else {
        $failCount += 1
        if ($failCount -ge $Strikes) {
            [Console]::Error.WriteLine("ready watch alert strikes=$failCount")
            Write-Evidence "alert" "n/a" "strikes=$failCount"
        }
    }

    Start-Sleep -Seconds $Interval
}
