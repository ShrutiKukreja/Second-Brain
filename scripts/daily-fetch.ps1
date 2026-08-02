$ErrorActionPreference = "Stop"

$root = "C:\Users\HP\Documents\Visual Studio\Second-Brain"
$promptFile = Join-Path $root "scripts\daily-fetch-prompt.md"
$logDir = Join-Path $root "scripts\logs"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$today = Get-Date -Format "yyyy-MM-dd"
$logFile = Join-Path $logDir "$today.log"

$promptTemplate = Get-Content -Raw $promptFile
$prompt = $promptTemplate -replace "\{\{TODAY\}\}", $today

Set-Location $root

$prompt | claude --print --permission-mode acceptEdits *>> $logFile
