#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Prompt,
  [string]$SessionId,
  [string]$Cwd
)

$logDir = Join-Path $env:LOCALAPPDATA "notify"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "codex-bridge.log"

function Write-BridgeLog {
  param([string]$msg)
  try { Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " " + $msg) } catch {}
}

if (-not $Prompt) {
  Write-BridgeLog "no prompt"
  exit 1
}

if (-not $Cwd) { $Cwd = (Get-Location).Path }

# Guard: if SessionId isn't a UUID, treat it as part of the prompt
if ($SessionId -and ($SessionId -notmatch '^[0-9a-fA-F-]{36}$')) {
  $Prompt = ($SessionId + " " + $Prompt).Trim()
  $SessionId = $null
}

$cmdArgs = @("exec","resume")
if ($SessionId) { $cmdArgs += $SessionId } else { $cmdArgs += "--last" }
$cmdArgs += "--skip-git-repo-check"
$cmdArgs += "--json"
$cmdArgs += @("-c","notify=[]")
$cmdArgs += $Prompt

function Format-ArgsForLog {
  param([string[]]$items)
  if (-not $items) { return "" }
  return ($items | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\\"') + '"' } else { $_ }
  }) -join ' '
}

Write-BridgeLog ("start codex: " + (Format-ArgsForLog $cmdArgs) + " | cwd=" + $Cwd)

function Get-CodexExe {
  try {
    $cmd = Get-Command codex -ErrorAction Stop
    if ($cmd.CommandType -eq 'Application') { return $cmd.Source }
    if ($cmd.Source -match 'codex\\.ps1$') {
      $base = Split-Path $cmd.Source -Parent
      $candidate = Join-Path $base 'node_modules\\@openai\\codex\\vendor\\x86_64-pc-windows-msvc\\codex\\codex.exe'
      if (Test-Path $candidate) { return $candidate }
    }
    return $cmd.Source
  } catch { return "codex" }
}

function Get-TextFromContent {
  param($c)
  if (-not $c) { return $null }
  if ($c -is [string]) { return $c }
  if ($c.text) { return $c.text }
  if ($c.value) { return $c.value }
  if ($c.content) { return (Get-TextFromContent -c $c.content) }
  if ($c -is [System.Collections.IEnumerable]) {
    $parts = @()
    foreach ($x in $c) {
      $t = Get-TextFromContent -c $x
      if ($t) { $parts += $t }
    }
    if ($parts.Count -gt 0) { return ($parts -join " ") }
  }
  return $null
}

function Get-JsonObjectCount {
  param([string]$text)
  if (-not $text) { return 0 }
  $count = 0
  foreach ($line in ($text -split "`r?`n")) {
    $t = $line.Trim()
    if (-not $t) { continue }
    if (-not ($t.StartsWith('{') -or $t.StartsWith('['))) { continue }
    try { $null = $t | ConvertFrom-Json; $count++ } catch {}
  }
  return $count
}

$rawText = ""
try {
  Push-Location $Cwd
  $exe = Get-CodexExe

  # First try: capture stdout directly (keeps JSON lines intact)
  $oldOut = [Console]::OutputEncoding
  $oldIn = [Console]::InputEncoding
  $oldPipe = $OutputEncoding
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [Console]::OutputEncoding = $utf8
  [Console]::InputEncoding = $utf8
  $OutputEncoding = $utf8
  try {
    $rawText = (& $exe @cmdArgs 2>&1 | Out-String)
  } finally {
    [Console]::OutputEncoding = $oldOut
    [Console]::InputEncoding = $oldIn
    $OutputEncoding = $oldPipe
  }

  # Fallback: if no output, try redirect to file and decode bytes
  if (-not $rawText -or $rawText.Trim().Length -eq 0) {
    $tmpOut = Join-Path $logDir ("codex-out-" + [guid]::NewGuid().ToString() + ".txt")
    Start-Process -FilePath $exe -ArgumentList $cmdArgs -WorkingDirectory $Cwd -NoNewWindow `
      -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpOut -Wait | Out-Null
    if (Test-Path $tmpOut) {
      $bytes = [IO.File]::ReadAllBytes($tmpOut)
      Remove-Item -Path $tmpOut -Force -ErrorAction SilentlyContinue

      $encList = @(
        (New-Object System.Text.UTF8Encoding($false, $true)),
        [System.Text.Encoding]::Unicode,
        [System.Text.Encoding]::Default
      )
      $bestText = ""
      $bestCount = -1
      $bestEnc = ""
      foreach ($enc in $encList) {
        try {
          $text = $enc.GetString($bytes)
          $cnt = Get-JsonObjectCount -text $text
          if ($cnt -gt $bestCount) { $bestCount = $cnt; $bestText = $text; $bestEnc = $enc.WebName }
        } catch {}
      }
      if ($bestText) { $rawText = $bestText }
      else { $rawText = [System.Text.Encoding]::Default.GetString($bytes) }
      if ($bestEnc) {
        Write-BridgeLog ("decode: best=" + $bestEnc + " json=" + $bestCount + " bytes=" + $bytes.Length)
      }
    }
  }
} catch {
  $rawText = "codex failed: " + $_.Exception.Message
} finally {
  Pop-Location
}

$rawLines = @()
if ($rawText) { $rawLines = $rawText -split "`r?`n" }

# Parse session id from output if missing
if (-not $SessionId) {
  $joined = ($rawLines -join "`n")
  if ($joined -match 'session id:\s*([0-9a-fA-F-]{36})') { $SessionId = $Matches[1] }
}
if (-not $SessionId) { $SessionId = "unknown" }

# Extract assistant reply from JSONL
$reply = $null
$buffer = New-Object System.Text.StringBuilder
$assistantTexts = @()
foreach ($line in $rawLines) {
  if (-not $line) { continue }
  $obj = $null
  try { $obj = $line | ConvertFrom-Json } catch { continue }
  if (-not $obj) { continue }

  if (-not $SessionId -or $SessionId -eq "unknown") {
    if ($obj.thread_id) { $SessionId = $obj.thread_id }
    elseif ($obj.'thread-id') { $SessionId = $obj.'thread-id' }
  }

  if ($obj.type -and ($obj.type -match 'output_text')) {
    if ($obj.delta) { [void]$buffer.Append($obj.delta) }
    elseif ($obj.text) { [void]$buffer.Append($obj.text) }
    continue
  }

  $role = $null
  if ($obj.role) { $role = $obj.role }
  elseif ($obj.author) { $role = $obj.author }
  elseif ($obj.type -and $obj.type -eq 'assistant') { $role = 'assistant' }

  if ($role -eq 'assistant') {
    $text = $null
    if ($obj.content) { $text = Get-TextFromContent -c $obj.content }
    elseif ($obj.message) { $text = Get-TextFromContent -c $obj.message }
    elseif ($obj.text) { $text = $obj.text }
    elseif ($obj.output_text) { $text = $obj.output_text }
    if ($text) { $assistantTexts += $text }
  }

  # Responses API style: item.completed with agent_message text
  if ($obj.type -eq 'item.completed' -and $obj.item) {
    if ($obj.item.type -eq 'agent_message' -and $obj.item.text) {
      $assistantTexts += $obj.item.text
    } elseif ($obj.item.type -eq 'output_text' -and $obj.item.text) {
      $assistantTexts += $obj.item.text
    }
  }
}

if ($assistantTexts.Count -gt 0) { $reply = $assistantTexts[-1].Trim() }
elseif ($buffer.Length -gt 0) { $reply = $buffer.ToString().Trim() }

if (-not $reply) {
  $fallback = ($rawLines -join "`n").Trim()
  $reply = $fallback
}
if (-not $reply) { $reply = "(无内容)" }

$payload = @{ "thread-id" = $SessionId; "cwd" = $Cwd; "last-assistant-message" = $reply } | ConvertTo-Json -Depth 6

if ($reply -eq "(无内容)") {
  try {
    $rawDump = Join-Path $logDir "codex-raw-last.txt"
    [IO.File]::WriteAllText($rawDump, $rawText, (New-Object System.Text.UTF8Encoding($true)))
    Write-BridgeLog "raw dumped"
  } catch {}
}

try {
  & "$PSScriptRoot\notify.ps1" -Source "Codex" $payload | Out-Null
  Write-BridgeLog "notify sent"
} catch {
  Write-BridgeLog ("notify fail: " + $_.Exception.Message)
}
