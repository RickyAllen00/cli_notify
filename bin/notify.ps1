#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Source = "Task",
  [string]$Title,
  [string]$Body,
  [string]$WebhookUrl = $env:WECOM_WEBHOOK,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$PayloadArgs
)

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
  try { return [Environment]::GetEnvironmentVariable($name, "User") } catch { return $null }
}

$notifyConfig = Load-NotifyConfig

# Global mute: env var or disable file
$mute = Get-NotifySetting -name "NOTIFY_MUTE" -cfg $notifyConfig
$flagAll = Join-Path $PSScriptRoot "notify.disabled"
if ((Test-Path $flagAll) -or ($mute -and $mute -ne "0")) { exit 0 }

# Channel toggles
$flagWin = Join-Path $PSScriptRoot "notify.windows.disabled"
$flagWecom = Join-Path $PSScriptRoot "notify.wecom.disabled"
$flagTg = Join-Path $PSScriptRoot "notify.telegram.disabled"
$flagDebug = Join-Path $PSScriptRoot "notify.debug.enabled"
$debugEnabled = Test-Path $flagDebug

# Log setup (keep only 1 day) if debug enabled
$logDir = Join-Path $env:LOCALAPPDATA "notify"
$logFile = Join-Path $logDir ("notify-" + (Get-Date -Format 'yyyyMMdd') + ".log")
if ($debugEnabled) {
  try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
  try {
    Get-ChildItem -Path $logDir -Filter "notify-*.log" -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).Date.AddDays(-1) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {}
}

function Write-NotifyLog {
  param([string]$Channel, [string]$Status, [string]$Message)
  if (-not $debugEnabled) { return }
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "$ts [$Channel] $Status $Message"
  } catch {}
}

function Normalize-ProxyUrl {
  param([string]$proxy)
  if ([string]::IsNullOrWhiteSpace($proxy)) { return $null }
  $p = $proxy.Trim()
  if ($p -notmatch '://') {
    if ($p -match '^[^:]+:\d+$') { return ("http://" + $p) }
  }
  return $p
}

# Allow reading webhook from config/User env if not present
if (-not $WebhookUrl) { $WebhookUrl = Get-NotifySetting -name "WECOM_WEBHOOK" -cfg $notifyConfig }

# Telegram config from config/env
$tgToken = Get-NotifySetting -name "TELEGRAM_BOT_TOKEN" -cfg $notifyConfig
$tgChat = Get-NotifySetting -name "TELEGRAM_CHAT_ID" -cfg $notifyConfig
$tgProxy = Normalize-ProxyUrl (Get-NotifySetting -name "TELEGRAM_PROXY" -cfg $notifyConfig)

# Read stdin when invoked as a hook (e.g., Claude Code sends JSON)
$raw = ""
if ([Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd() }

$payload = $null
$payloadJson = $null
if ($PayloadArgs -and $PayloadArgs.Count -gt 0) { $payloadJson = ($PayloadArgs -join " ") }
if (-not $payloadJson -and $raw) { $payloadJson = $raw }

function Try-ExtractJson {
  param([string]$s)
  if (-not $s) { return $null }
  $t = $s.Trim()
  if (($t.StartsWith('{') -and $t.EndsWith('}')) -or ($t.StartsWith('[') -and $t.EndsWith(']'))) { return $t }
  $i = $t.IndexOf('{')
  $j = $t.LastIndexOf('}')
  if ($i -ge 0 -and $j -gt $i) { return $t.Substring($i, $j - $i + 1) }
  return $null
}

if ($payloadJson) {
  $extracted = Try-ExtractJson $payloadJson
  if ($extracted) { $payloadJson = $extracted }
}

# Sometimes Codex passes JSON as the first unnamed argument (bound to Title/Body)
if (-not $payloadJson -and $Title) {
  $extracted = Try-ExtractJson $Title
  if ($extracted) { $payloadJson = $extracted; $Title = $null }
}
if (-not $payloadJson -and $Body) {
  $extracted = Try-ExtractJson $Body
  if ($extracted) { $payloadJson = $extracted; $Body = $null }
}

if ($payloadJson) {
  try { $payload = $payloadJson | ConvertFrom-Json } catch {
    try {
      $extracted = Try-ExtractJson $payloadJson
      if ($extracted) { $payload = $extracted | ConvertFrom-Json }
    } catch {}
  }
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

function Get-LastAssistantText {
  param($p)
  if (-not $p) { return $null }

  # direct fields
  if ($p.'last-assistant-message') { return $p.'last-assistant-message' }
  if ($p.output_text) { return $p.output_text }

  $containers = @()
  if ($p.messages -is [System.Collections.IEnumerable]) { $containers += ,$p.messages }
  if ($p.output -is [System.Collections.IEnumerable]) { $containers += ,$p.output }
  if ($p.items -is [System.Collections.IEnumerable]) { $containers += ,$p.items }
  if ($p.events -is [System.Collections.IEnumerable]) { $containers += ,$p.events }
  if ($p.turns -is [System.Collections.IEnumerable]) { $containers += ,$p.turns }
  if ($p.data -and $p.data.messages -is [System.Collections.IEnumerable]) { $containers += ,$p.data.messages }
  if ($p.response -and $p.response.output -is [System.Collections.IEnumerable]) { $containers += ,$p.response.output }

  foreach ($arr in $containers) {
    try { $list = @($arr) } catch { continue }
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
      $m = $list[$i]
      if (-not $m) { continue }
      $role = $null
      if ($m.role) { $role = $m.role }
      elseif ($m.author) { $role = $m.author }
      elseif ($m.type -and $m.type -eq 'assistant') { $role = 'assistant' }
      if ($role -ne 'assistant') { continue }

      $content = $null
      if ($m.content) { $content = $m.content }
      elseif ($m.message) { $content = $m.message }
      elseif ($m.text) { $content = $m.text }
      elseif ($m.output_text) { $content = $m.output_text }

      $txt = Get-TextFromContent -c $content
      if ($txt) { return $txt }
    }
  }

  return $null
}

function Get-SessionId {
  param($p)
  if (-not $p) { return "unknown" }
  foreach ($k in @("session_id","session-id","thread_id","thread-id","conversation_id","conversation-id","session")) {
    if ($p.$k) { return $p.$k }
  }
  return "unknown"
}

function Get-ProjectPath {
  param($p)
  if ($p) {
    foreach ($k in @("cwd","workdir","working_dir","project_dir","project_path","repo_root","project_root","workspace","path")) {
      if ($p.$k) { return $p.$k }
    }
  }
  if ($env:CODEX_WORKDIR) { return $env:CODEX_WORKDIR }
  try { return (Get-Location).Path } catch { return "unknown" }
}

function Get-HostName {
  param($p)
  if ($p) {
    foreach ($k in @("host_name","hostName","host_label","hostLabel","host_alias","hostAlias","host_remark","hostRemark")) {
      if ($p.$k) { return $p.$k }
    }
    foreach ($k in @("host","hostname","machine","node","computer")) {
      if ($p.$k) { return $p.$k }
    }
  }
  return $null
}

function Get-HostRaw {
  param($p)
  if ($p) {
    foreach ($k in @("host","hostname","machine","node","computer")) {
      if ($p.$k) { return $p.$k }
    }
  }
  return $null
}

function Normalize-Reply {
  param([string]$text, [int]$max)
  if (-not $text) { return "(无内容)" }
  $t = $text.Trim()
  if ($max -le 0) { return $t }
  $oneLine = ($t -replace '\s+', ' ').Trim()
  if ($oneLine.Length -gt $max) { return $oneLine.Substring(0,$max) + "..." }
  return $oneLine
}

$stateFile = Join-Path $logDir "session-map.json"
function Update-SessionMap {
  param([string]$sessionId, [string]$projectPath, [string]$source, [string]$time)
  if (-not $sessionId -or $sessionId -eq "unknown") { return }
  try {
    $state = $null
    if (Test-Path $stateFile) {
      try { $state = (Get-Content -Path $stateFile -Raw) | ConvertFrom-Json } catch {}
    }
    if (-not $state) { $state = [pscustomobject]@{} }

    if (-not $state.sessions) { $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{}) }
    if (-not $state.codex) { $state | Add-Member -MemberType NoteProperty -Name codex -Value ([pscustomobject]@{}) }
    if (-not $state.claude) { $state | Add-Member -MemberType NoteProperty -Name claude -Value ([pscustomobject]@{}) }

    $entry = [pscustomobject]@{ cwd = $projectPath; source = $source; time = $time }
    $state.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $entry -Force

    if ($source -match 'Codex') { $state.codex = $entry }
    elseif ($source -match 'Claude') { $state.claude = $entry }

    # keep only last 50 sessions
    $entries = @()
    foreach ($p in $state.sessions.PSObject.Properties) {
      $entries += [pscustomobject]@{ Name = $p.Name; Time = $p.Value.time }
    }
    $entries = $entries | Sort-Object Time -Descending
    if ($entries.Count -gt 50) {
      $entries | Select-Object -Skip 50 | ForEach-Object {
        $state.sessions.PSObject.Properties.Remove($_.Name)
      }
    }

    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $stateFile -Encoding UTF8
  } catch {}
}
$tgMapFile = Join-Path $logDir "telegram-map.json"
function Load-TelegramMap {
  if (Test-Path $tgMapFile) {
    try { return (Get-Content -Path $tgMapFile -Raw) | ConvertFrom-Json } catch {}
  }
  $state = [pscustomobject]@{}
  $state | Add-Member -MemberType NoteProperty -Name messages -Value ([pscustomobject]@{})
  $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{})
  return $state
}

function Save-TelegramMap {
  param($state)
  try { $state | ConvertTo-Json -Depth 8 | Set-Content -Path $tgMapFile -Encoding UTF8 } catch {}
}

function Get-TelegramThreadId {
  param([string]$sessionId)
  if (-not $sessionId) { return $null }
  if (-not (Test-Path $tgMapFile)) { return $null }
  try {
    $state = (Get-Content -Path $tgMapFile -Raw) | ConvertFrom-Json
    if (-not $state -or -not $state.sessions) { return $null }
    $prop = $state.sessions.PSObject.Properties[$sessionId]
    if ($prop -and $prop.Value.thread_id) { return $prop.Value.thread_id }
  } catch {}
  return $null
}

function Update-TelegramMap {
  param(
    [string]$sessionId,
    [string]$source,
    [string]$cwd,
    [string]$hostRaw,
    [string]$hostName,
    [string]$messageId,
    [string]$time
  )
  if (-not $sessionId -or -not $messageId) { return }
  $state = Load-TelegramMap
  if (-not $state.messages) { $state | Add-Member -MemberType NoteProperty -Name messages -Value ([pscustomobject]@{}) -Force }
  if (-not $state.sessions) { $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{}) -Force }

  $entry = [pscustomobject]@{ session_id = $sessionId; source = $source; cwd = $cwd; host = $hostRaw; host_name = $hostName; time = $time }
  $state.messages | Add-Member -MemberType NoteProperty -Name $messageId -Value $entry -Force

  $threadId = $null
  try {
    $existing = $state.sessions.PSObject.Properties[$sessionId]
    if ($existing -and $existing.Value.thread_id) { $threadId = $existing.Value.thread_id }
  } catch {}
  $sentry = [pscustomobject]@{
    latest_message_id = $messageId
    source = $source
    cwd = $cwd
    host = $hostRaw
    host_name = $hostName
    time = $time
    thread_id = $threadId
  }
  $state.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $sentry -Force

  # keep only last 200 messages
  try {
    $entries = @()
    foreach ($p in $state.messages.PSObject.Properties) {
      $entries += [pscustomobject]@{ Name = $p.Name; Time = $p.Value.time }
    }
    $entries = $entries | Sort-Object Time -Descending
    if ($entries.Count -gt 200) {
      $entries | Select-Object -Skip 200 | ForEach-Object {
        $state.messages.PSObject.Properties.Remove($_.Name)
      }
    }
  } catch {}

  Save-TelegramMap -state $state
}
$sessionId = Get-SessionId -p $payload
$projectPath = Get-ProjectPath -p $payload
$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Update-SessionMap -sessionId $sessionId -projectPath $projectPath -source $Source -time $endTime

$maxReply = 0  # 0 = no truncation
try {
  $v = Get-NotifySetting -name "NOTIFY_MAX_REPLY" -cfg $notifyConfig
  if ($v) { $maxReply = [int]$v }
} catch {}

$rawSnippet = Get-LastAssistantText -p $payload
$snippet = Normalize-Reply -text $rawSnippet -max $maxReply

if ($payload) {
  if ($Source -match 'Codex') { $Title = "Codex 已回复" }
  elseif ($Source -match 'Claude') { $Title = "Claude 已回复" }
  elseif (-not $Title) { $Title = "$Source 已回复" }
} else {
  if (-not $Title -or $Title -match '^\s*[{[]' -or $Title -match '"type"\s*:') {
    if ($Source -match 'Codex') { $Title = "Codex 已回复" }
    elseif ($Source -match 'Claude') { $Title = "Claude 已回复" }
    else { $Title = "$Source 已回复" }
  }
}

# Only push host (optional) + session id + project path + end time + last reply
$hostRaw = Get-HostRaw -p $payload
$hostLabel = Get-HostName -p $payload
if (-not $hostRaw) {
  $hostRaw = Get-NotifySetting -name "NOTIFY_HOST" -cfg $notifyConfig
  if (-not $hostRaw -and $env:COMPUTERNAME) { $hostRaw = $env:COMPUTERNAME }
}
if (-not $hostLabel) {
  $hostLabel = Get-NotifySetting -name "NOTIFY_HOST_NAME" -cfg $notifyConfig
}
$hostName = $hostLabel
if (-not $hostName) { $hostName = $hostRaw }
$hostLine = $null
if ($hostName) { $hostLine = "主机: $hostName" }

$bodyLines = @()
if ($hostLine) { $bodyLines += $hostLine }
$bodyLines += "会话ID: $sessionId"
$bodyLines += "项目: $projectPath"
$bodyLines += "结束: $endTime"
$bodyLines += "回复: $snippet"
$Body = $bodyLines -join "`n"

Write-NotifyLog -Channel "invoke" -Status "ok" -Message "$Source"

# Windows toast
if (Test-Path $flagWin) {
  Write-NotifyLog -Channel "windows" -Status "skip" -Message "disabled"
} else {
  try {
    if (Get-Module -ListAvailable -Name BurntToast) {
      Import-Module BurntToast -ErrorAction Stop
      $cmd = Get-Command -Name New-BurntToastNotification -ErrorAction Stop
      $params = $cmd.Parameters.Keys
      $expire = (Get-Date).AddSeconds(5)
      if ($params -contains 'Duration' -and $params -contains 'ExpirationTime') {
        New-BurntToastNotification -Text $Title, $Body -Duration Short -ExpirationTime $expire | Out-Null
      } elseif ($params -contains 'Duration') {
        New-BurntToastNotification -Text $Title, $Body -Duration Short | Out-Null
      } elseif ($params -contains 'ExpirationTime') {
        New-BurntToastNotification -Text $Title, $Body -ExpirationTime $expire | Out-Null
      } else {
        New-BurntToastNotification -Text $Title, $Body | Out-Null
      }
      Write-NotifyLog -Channel "windows" -Status "ok" -Message $Title
    } else {
      function Send-NativeToast {
        param([string]$Title, [string]$Body)
        try {
          [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
          $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
          $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
          $nodes = $xml.GetElementsByTagName("text")
          if ($nodes.Count -ge 1) { $nodes.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null }
          if ($nodes.Count -ge 2) { $nodes.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null }
          $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
          $toast.ExpirationTime = (Get-Date).AddSeconds(5)
          $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Windows PowerShell")
          $notifier.Show($toast)
          return $true
        } catch {
          return $false
        }
      }

      if (Send-NativeToast -Title $Title -Body $Body) {
        Write-NotifyLog -Channel "windows" -Status "ok" -Message $Title
      } else {
        Write-NotifyLog -Channel "windows" -Status "skip" -Message "BurntToast not installed"
      }
    }
  } catch {
    Write-NotifyLog -Channel "windows" -Status "fail" -Message $_.Exception.Message
  }
}

# WeCom Markdown
if (Test-Path $flagWecom) {
  Write-NotifyLog -Channel "wecom" -Status "skip" -Message "disabled"
} else {
  if ($WebhookUrl) {
    $wecomLines = @()
    if ($hostLine) { $wecomLines += $hostLine }
    $wecomLines += "会话ID: $sessionId"
    $wecomLines += "项目: $projectPath"
    $wecomLines += "结束: $endTime"
    $wecomLines += "回复: $snippet"
    $content = $wecomLines -join "`n"
    $payloadOut = @{ msgtype = "markdown"; markdown = @{ content = $content } } | ConvertTo-Json -Depth 5
    try {
      Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json; charset=utf-8' -Body $payloadOut | Out-Null
      Write-NotifyLog -Channel "wecom" -Status "ok" -Message $Title
    } catch {
      Write-NotifyLog -Channel "wecom" -Status "fail" -Message $_.Exception.Message
    }
  } else {
    Write-NotifyLog -Channel "wecom" -Status "skip" -Message "Webhook not set"
  }
}

# Telegram
if (Test-Path $flagTg) {
  Write-NotifyLog -Channel "telegram" -Status "skip" -Message "disabled"
} else {
  if ($tgToken -and $tgChat) {
    $tgText = if ($hostLine) { "$hostLine`n会话ID: $sessionId`n项目: $projectPath`n结束: $endTime`n回复: $snippet" } else { "会话ID: $sessionId`n项目: $projectPath`n结束: $endTime`n回复: $snippet" }
    $tgUri = "https://api.telegram.org/bot$tgToken/sendMessage"
    $tgThreadId = Get-TelegramThreadId -sessionId $sessionId

    function Send-TgChunk {
      param([string]$text)
      $tgPayload = @{ chat_id = $tgChat; text = $text }
      if ($tgThreadId) {
        try { $tgPayload.message_thread_id = [int]$tgThreadId } catch {}
      }
      $tgPayload = $tgPayload | ConvertTo-Json
      $irmArgs = @{ Method = 'Post'; Uri = $tgUri; ContentType = 'application/json; charset=utf-8'; Body = $tgPayload }
      if ($tgProxy) { $irmArgs.Proxy = $tgProxy }
      $resp = Invoke-RestMethod @irmArgs
      try {
        if ($resp -and $resp.result -and $resp.result.message_id) { return [string]$resp.result.message_id }
      } catch {}
      return $null
    }

    try {
      $maxLen = 3500
      if ($tgText.Length -le $maxLen) {
        $mid = Send-TgChunk -text $tgText
        if ($mid) { Update-TelegramMap -sessionId $sessionId -source $Source -cwd $projectPath -hostRaw $hostRaw -hostName $hostName -messageId $mid -time $endTime }
      } else {
        for ($i = 0; $i -lt $tgText.Length; $i += $maxLen) {
          $len = [Math]::Min($maxLen, $tgText.Length - $i)
          $part = $tgText.Substring($i, $len)
          $mid = Send-TgChunk -text $part
          if ($mid) { Update-TelegramMap -sessionId $sessionId -source $Source -cwd $projectPath -hostRaw $hostRaw -hostName $hostName -messageId $mid -time $endTime }
        }
      }
      Write-NotifyLog -Channel "telegram" -Status "ok" -Message $Title
    } catch {
      Write-NotifyLog -Channel "telegram" -Status "fail" -Message $_.Exception.Message
    }
  } else {
    Write-NotifyLog -Channel "telegram" -Status "skip" -Message "Token or chat id not set"
  }
}
