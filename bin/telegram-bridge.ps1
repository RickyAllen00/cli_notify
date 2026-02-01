#requires -Version 5.1
[CmdletBinding()]
param(
  [int]$PollSeconds = 3
)

$logDir = Join-Path $env:LOCALAPPDATA "notify"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "telegram-bridge.log"
$offsetFile = Join-Path $logDir "telegram.offset"
$stateFile = Join-Path $logDir "session-map.json"

function Write-BridgeLog {
  param([string]$msg)
  try { Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " " + $msg) } catch {}
}

function Get-EnvUser([string]$name) {
  try { return [Environment]::GetEnvironmentVariable($name, "User") } catch { return $null }
}

function Read-EnvFile {
  param([string]$path)
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content -Path $path -ErrorAction SilentlyContinue) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    if ($t -match '^\s*export\s+') { $t = $t -replace '^\s*export\s+','' }
    if ($t -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
      $key = $Matches[1].Trim()
      $val = $Matches[2].Trim()
      if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        if ($val.Length -ge 2) { $val = $val.Substring(1, $val.Length - 2) }
      }
      if ($key) { $map[$key] = $val }
    }
  }
  return $map
}

function Read-YamlFile {
  param([string]$path)
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content -Path $path -ErrorAction SilentlyContinue) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#") -or $t -eq "---") { continue }
    if ($t -match '^\s*([^:#]+?)\s*:\s*(.*?)\s*$') {
      $key = $Matches[1].Trim()
      $val = $Matches[2].Trim()
      if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        if ($val.Length -ge 2) { $val = $val.Substring(1, $val.Length - 2) }
      }
      if ($key) { $map[$key] = $val }
    }
  }
  return $map
}

function Load-NotifyConfig {
  $paths = @()
  if ($env:NOTIFY_CONFIG_PATH) { $paths += $env:NOTIFY_CONFIG_PATH }
  $paths += (Join-Path $PSScriptRoot ".env")
  $paths += (Join-Path $PSScriptRoot "notify.yml")
  $paths += (Join-Path $PSScriptRoot "notify.yaml")
  foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    $ext = [IO.Path]::GetExtension($p).ToLower()
    if ($ext -eq ".yml" -or $ext -eq ".yaml") { return (Read-YamlFile -path $p) }
    return (Read-EnvFile -path $p)
  }
  return @{}
}

function Get-NotifySetting {
  param([string]$name, $cfg)
  $v = [Environment]::GetEnvironmentVariable($name, "Process")
  if ($v) { return $v }
  if ($cfg -and $cfg.ContainsKey($name)) { return $cfg[$name] }
  return (Get-EnvUser $name)
}

$notifyConfig = Load-NotifyConfig
$token = Get-NotifySetting -name "TELEGRAM_BOT_TOKEN" -cfg $notifyConfig
$chatId = Get-NotifySetting -name "TELEGRAM_CHAT_ID" -cfg $notifyConfig

if (-not $token -or -not $chatId) {
  Write-BridgeLog "missing token/chat_id; exit"
  exit 1
}

function Send-Tg {
  param([string]$text)
  try {
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $payload = @{ chat_id = $chatId; text = $text } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json; charset=utf-8' -Body $payload | Out-Null
  } catch {
    Write-BridgeLog ("send fail: " + $_.Exception.Message)
  }
}

function Format-ArgsForLog {
  param([string[]]$items)
  if (-not $items) { return "" }
  return ($items | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\\"') + '"' } else { $_ }
  }) -join ' '
}

function Get-SessionState {
  param([string]$sessionId)
  if (-not (Test-Path $stateFile)) { return $null }
  try {
    $state = (Get-Content -Path $stateFile -Raw) | ConvertFrom-Json
    if ($sessionId) {
      $prop = $state.sessions.PSObject.Properties[$sessionId]
      if ($prop) { return $prop.Value }
    }
    return $state
  } catch { return $null }
}

function Start-Codex {
  param([string]$sessionId, [string]$prompt, [switch]$UseLast)
  if (-not $prompt) { Send-Tg "用法: /codex <问题>  或  /codex <会话ID> <问题>"; return }

  $cwd = $null
  if ($sessionId) {
    $entry = Get-SessionState -sessionId $sessionId
    if ($entry -and $entry.cwd) { $cwd = $entry.cwd }
  }
  if (-not $cwd) {
    $state = Get-SessionState -sessionId $null
    if ($state -and $state.codex -and $state.codex.cwd) { $cwd = $state.codex.cwd }
  }
  if (-not $cwd) { $cwd = (Get-Location).Path }

  $runner = Join-Path $PSScriptRoot "codex-bridge-run.ps1"
  $cmdArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$runner,"-Prompt",$prompt,"-Cwd",$cwd)
  if (-not $UseLast -and $sessionId) { $cmdArgs += @("-SessionId",$sessionId) }

  $argLine = Format-ArgsForLog $cmdArgs
  Write-BridgeLog ("codex: powershell " + $argLine + " | cwd=" + $cwd)
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList $cmdArgs -WindowStyle Hidden | Out-Null
    Send-Tg "已提交: Codex 执行中…结果会自动推送"
  } catch {
    Write-BridgeLog ("codex start fail: " + $_.Exception.Message)
    Send-Tg "启动 Codex 失败: $($_.Exception.Message)"
  }
}

function Start-Claude {
  param([string]$sessionId, [string]$prompt, [switch]$UseLast)
  if (-not $prompt) { Send-Tg "用法: /claude <问题>  或  /claude <会话ID> <问题>"; return }

  $cwd = $null
  if ($sessionId) {
    $entry = Get-SessionState -sessionId $sessionId
    if ($entry -and $entry.cwd) { $cwd = $entry.cwd }
  }
  if (-not $cwd) {
    $state = Get-SessionState -sessionId $null
    if ($state -and $state.claude -and $state.claude.cwd) { $cwd = $state.claude.cwd }
  }
  if (-not $cwd) { $cwd = (Get-Location).Path }

  $runner = Join-Path $PSScriptRoot "claude-bridge-run.ps1"
  $cmdArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$runner,"-Prompt",$prompt,"-Cwd",$cwd)
  if (-not $UseLast -and $sessionId) { $cmdArgs += @("-SessionId",$sessionId) }

  $argLine = Format-ArgsForLog $cmdArgs
  Write-BridgeLog ("claude: powershell " + $argLine + " | cwd=" + $cwd)
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList $cmdArgs -WindowStyle Hidden | Out-Null
    Send-Tg "已提交: Claude 执行中…结果会自动推送"
  } catch {
    Write-BridgeLog ("claude start fail: " + $_.Exception.Message)
    Send-Tg "启动 Claude 失败: $($_.Exception.Message)"
  }
}

$offset = 0
if (Test-Path $offsetFile) {
  try { $offset = [int](Get-Content -Path $offsetFile -Raw) } catch { $offset = 0 }
}

Write-BridgeLog "bridge started"
Send-Tg "Telegram 控制桥已启动。发送 /help 查看命令。"

while ($true) {
  try {
    $uri = "https://api.telegram.org/bot$token/getUpdates?timeout=30&offset=$offset"
    $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 35
  } catch {
    Write-BridgeLog ("getUpdates fail: " + $_.Exception.Message)
    Start-Sleep -Seconds $PollSeconds
    continue
  }

  foreach ($u in $resp.result) {
    $offset = $u.update_id + 1
    try { Set-Content -Path $offsetFile -Value $offset } catch {}

    $msg = $u.message
    if (-not $msg) { continue }
    if ($msg.chat.id -ne $chatId) { continue }
    if (-not $msg.text) { continue }

    $text = $msg.text.Trim()
    if ($text -match '^(?i)/help') {
      Send-Tg "/codex <问题>  或  /codex <会话ID> <问题>\n/claude <问题>  或  /claude <会话ID> <问题>\n/codex last <问题> | /claude last <问题>"
      continue
    }

    if ($text -match '^(?i)/codex\b(.*)$') {
      $rest = $Matches[1].Trim()
      if (-not $rest) { Send-Tg "用法: /codex <问题>  或  /codex <会话ID> <问题>"; continue }
      if ($rest -match '^(?i)last\s+(.+)$') {
        Start-Codex -UseLast -prompt $Matches[1]
      } elseif ($rest -match '^([0-9a-fA-F\-]{36})\s+(.+)$') {
        Start-Codex -sessionId $Matches[1] -prompt $Matches[2]
      } else {
        Start-Codex -UseLast -prompt $rest
      }
      continue
    }

    if ($text -match '^(?i)/claude\b(.*)$') {
      $rest = $Matches[1].Trim()
      if (-not $rest) { Send-Tg "用法: /claude <问题>  或  /claude <会话ID> <问题>"; continue }
      if ($rest -match '^(?i)last\s+(.+)$') {
        Start-Claude -UseLast -prompt $Matches[1]
      } elseif ($rest -match '^([0-9a-fA-F\-]{36})\s+(.+)$') {
        Start-Claude -sessionId $Matches[1] -prompt $Matches[2]
      } else {
        Start-Claude -UseLast -prompt $rest
      }
      continue
    }

    Send-Tg "未知命令，发送 /help 查看用法"
  }

  Start-Sleep -Seconds $PollSeconds
}

