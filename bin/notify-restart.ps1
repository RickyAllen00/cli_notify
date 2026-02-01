#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$Quiet
)

$bin = Split-Path -Parent $MyInvocation.MyCommand.Path
$trayVbs = Join-Path $bin "notify-tray.vbs"
$telegramVbs = Join-Path $bin "telegram-bridge.vbs"
$serverVbs = Join-Path $bin "notify-server.vbs"
$codexWatch = Join-Path $bin "codex-watch.ps1"

function Write-Info {
  param([string]$msg)
  if (-not $Quiet) { Write-Host $msg }
}

function Stop-ByCmdline {
  param([string]$pattern)
  Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern } |
    ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Write-Info "Stopping existing processes..."
Stop-ByCmdline 'notify-tray\.ps1|notify-tray\.vbs'
Stop-ByCmdline 'telegram-bridge\.ps1|telegram-bridge\.vbs'
Stop-ByCmdline 'notify-server\.ps1|notify-server\.vbs'
Stop-ByCmdline 'codex-watch\.ps1'
try { schtasks /End /TN CodexWatch | Out-Null } catch {}

Write-Info "Starting tray..."
if (Test-Path $trayVbs) {
  Start-Process -FilePath "wscript.exe" -ArgumentList "`"$trayVbs`"" -WindowStyle Hidden | Out-Null
}

Write-Info "Starting Telegram bridge..."
if (Test-Path $telegramVbs) {
  Start-Process -FilePath "wscript.exe" -ArgumentList "`"$telegramVbs`"" -WindowStyle Hidden | Out-Null
}

Write-Info "Starting Notify server..."
if (Test-Path $serverVbs) {
  Start-Process -FilePath "wscript.exe" -ArgumentList "`"$serverVbs`"" -WindowStyle Hidden | Out-Null
}

Write-Info "Starting CodexWatch..."
$taskExists = $false
try {
  schtasks /Query /TN CodexWatch 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $taskExists = $true }
} catch {}
if ($taskExists) {
  try { schtasks /Run /TN CodexWatch | Out-Null } catch {}
} elseif (Test-Path $codexWatch) {
  Start-Process -FilePath "powershell.exe" -ArgumentList "-NoLogo -NonInteractive -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$codexWatch`"" -WindowStyle Hidden | Out-Null
}

Write-Info "Done."
