#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Prompt,
  [string]$SessionId,
  [string]$Cwd
)

$logDir = Join-Path $env:LOCALAPPDATA "notify"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "claude-bridge.log"

function Write-BridgeLog {
  param([string]$msg)
  try { Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " " + $msg) } catch {}
}

if (-not $Prompt) {
  Write-BridgeLog "no prompt"
  exit 1
}

if (-not $Cwd) { $Cwd = (Get-Location).Path }

$cmdArgs = @()
if ($SessionId) { $cmdArgs += @("--resume", $SessionId) } else { $cmdArgs += "--continue" }
$cmdArgs += @("--print", $Prompt)

Write-BridgeLog ("start claude: " + ($cmdArgs -join ' ') + " | cwd=" + $Cwd)

try {
  Push-Location $Cwd
  $raw = & claude @cmdArgs 2>&1 | Out-String
} catch {
  $raw = "claude failed: " + $_.Exception.Message
} finally {
  Pop-Location
}

$reply = $raw.Trim()
if (-not $reply) { $reply = "(无内容)" }
if (-not $SessionId) { $SessionId = "unknown" }

$payload = @{ "thread-id" = $SessionId; "cwd" = $Cwd; "last-assistant-message" = $reply } | ConvertTo-Json -Depth 6

try {
  & "$PSScriptRoot\notify.ps1" -Source "Claude" $payload | Out-Null
  Write-BridgeLog "notify sent"
} catch {
  Write-BridgeLog ("notify fail: " + $_.Exception.Message)
}
