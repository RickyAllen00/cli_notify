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
$tgMapFile = Join-Path $logDir "telegram-map.json"

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

function Normalize-ProxyUri {
  param([string]$s)
  if (-not $s) { return $null }
  $t = $s.Trim()
  if (-not $t) { return $null }
  if ($t -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $t = "http://$t" }
  try {
    $u = [uri]$t
    if ($u.Scheme -ne "http" -and $u.Scheme -ne "https") { return $null }
    return $u
  } catch { return $null }
}

$notifyConfig = Load-NotifyConfig
$token = Get-NotifySetting -name "TELEGRAM_BOT_TOKEN" -cfg $notifyConfig
$chatId = Get-NotifySetting -name "TELEGRAM_CHAT_ID" -cfg $notifyConfig
$tgProxyUri = Normalize-ProxyUri (Get-NotifySetting -name "TELEGRAM_PROXY" -cfg $notifyConfig)

if (-not $token -or -not $chatId) {
  Write-BridgeLog "missing token/chat_id; exit"
  exit 1
}

function Send-Tg {
  param([string]$text, [string]$threadId)
  try {
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $payload = @{ chat_id = $chatId; text = $text }
    if ($threadId) {
      try { $payload.message_thread_id = [int]$threadId } catch {}
    }
    $body = $payload | ConvertTo-Json
    $irm = @{
      Method      = "Post"
      Uri         = $uri
      ContentType = 'application/json; charset=utf-8'
      Body        = $body
    }
    if ($tgProxyUri) { $irm.Proxy = $tgProxyUri }
    Invoke-RestMethod @irm | Out-Null
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

function Update-SessionThreadId {
  param([string]$sessionId, [string]$threadId)
  if (-not $sessionId -or -not $threadId) { return }
  $map = Load-TelegramMap
  if (-not $map) { return }
  if (-not $map.sessions) { $map | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{}) -Force }
  $prop = $map.sessions.PSObject.Properties[$sessionId]
  if ($prop) {
    $prop.Value | Add-Member -MemberType NoteProperty -Name thread_id -Value $threadId -Force
  } else {
    $entry = [pscustomobject]@{ thread_id = $threadId }
    $map.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $entry -Force
  }
  Save-TelegramMap -state $map
}

function Get-ReplyContext {
  param([string]$replyMessageId)
  $map = Load-TelegramMap
  if (-not $map -or -not $map.messages) { return $null }
  $msgProp = $map.messages.PSObject.Properties[$replyMessageId]
  if (-not $msgProp) { return $null }
  $msg = $msgProp.Value
  $sessionId = $msg.session_id
  $sess = $null
  if ($map.sessions -and $sessionId) {
    $sessProp = $map.sessions.PSObject.Properties[$sessionId]
    if ($sessProp) { $sess = $sessProp.Value }
  }
  return [pscustomobject]@{
    session_id = $sessionId
    source = $msg.source
    cwd = $msg.cwd
    host = $msg.host
    host_name = $msg.host_name
    latest_message_id = if ($sess) { $sess.latest_message_id } else { $null }
    thread_id = if ($sess) { $sess.thread_id } else { $null }
  }
}

function Get-ReplyContextFromMessage {
  param($replyMsg)
  if (-not $replyMsg) { return $null }

  $text = $null
  if ($replyMsg.text) { $text = $replyMsg.text }
  elseif ($replyMsg.caption) { $text = $replyMsg.caption }
  if (-not $text) { return $null }

  $sessionId = $null
  if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
    $sessionId = $Matches[1]
  }
  if (-not $sessionId) { return $null }

  $cwd = $null
  $hostName = $null
  $hostRaw = $null
  foreach ($line in ($text -split "`r?`n")) {
    $t = $line.Trim()
    if (-not $t) { continue }
    if ($t -match '^主机\s*[:：]\s*(.+)$') {
      $hostName = $Matches[1].Trim()
      if (-not $hostRaw) { $hostRaw = $hostName }
      continue
    }
    if ($t -match '^(项目|project)\s*[:：]\s*(.+)$') {
      $cwd = $Matches[2].Trim()
      continue
    }
    if ($t -match '^host\s*[:：]\s*(.+)$') {
      $hostName = $Matches[1].Trim()
      if (-not $hostRaw) { $hostRaw = $hostName }
      continue
    }
  }

  return [pscustomobject]@{
    session_id = $sessionId
    source = $null
    cwd = $cwd
    host = $hostRaw
    host_name = $hostName
    latest_message_id = $null
    thread_id = $null
  }
}

function Get-MessageText {
  param($msg)
  if ($msg.text) { return $msg.text.Trim() }
  if ($msg.caption) { return $msg.caption.Trim() }
  return ""
}

function Get-MessageImageFileId {
  param($msg)
  try {
    if ($msg.photo -and $msg.photo.Count -gt 0) {
      return $msg.photo[-1].file_id
    }
    if ($msg.document -and $msg.document.mime_type -and $msg.document.mime_type -like "image/*") {
      return $msg.document.file_id
    }
  } catch {}
  return $null
}

function Get-TgFilePath {
  param([string]$fileId)
  if (-not $fileId) { return $null }
  try {
    $uri = "https://api.telegram.org/bot$token/getFile?file_id=$fileId"
    $irm = @{ Method = "Get"; Uri = $uri }
    if ($tgProxyUri) { $irm.Proxy = $tgProxyUri }
    $resp = Invoke-RestMethod @irm
    if ($resp -and $resp.result -and $resp.result.file_path) { return $resp.result.file_path }
  } catch {}
  return $null
}

function Save-MessageImage {
  param($msg, [string]$cwd, [switch]$ForceLocal)
  $fileId = Get-MessageImageFileId -msg $msg
  if (-not $fileId) { return $null }
  $filePath = Get-TgFilePath -fileId $fileId
  if (-not $filePath) { return $null }
  $ext = [IO.Path]::GetExtension($filePath)
  if (-not $ext) { $ext = ".jpg" }

  $targetRoot = $cwd
  $useRelative = $true
  if ($ForceLocal -or -not $targetRoot -or -not (Test-Path $targetRoot)) {
    $targetRoot = $logDir
    $useRelative = $false
  }
  $dir = Join-Path $targetRoot ".notify"
  try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch {
    $dir = $targetRoot
    $useRelative = $false
  }
  $name = "tg_" + $msg.message_id + $ext
  $dest = Join-Path $dir $name
  $downloadUrl = "https://api.telegram.org/file/bot$token/$filePath"
  try {
    $iwr = @{ Uri = $downloadUrl; OutFile = $dest }
    if ($tgProxyUri) { $iwr.Proxy = $tgProxyUri }
    Invoke-WebRequest @iwr | Out-Null
  } catch { return $null }

  $ref = $dest
  if ($useRelative) { $ref = (".notify\\" + $name) }
  return [pscustomobject]@{
    local_path = $dest
    ref = $ref
    remote_ref = (".notify/" + $name)
    file_name = $name
  }
}

function Escape-ForBashDoubleQuotes {
  param([string]$s)
  if (-not $s) { return $s }
  $t = $s -replace '\\','\\\\'
  $t = $t -replace '"','\\"'
  $t = $t -replace '\$','\\$'
  $t = $t -replace '`','\\`'
  return $t
}

function Trim-Value {
  param([string]$s)
  if (-not $s) { return $null }
  $t = $s.Trim()
  if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) {
    if ($t.Length -ge 2) { return $t.Substring(1, $t.Length - 2) }
  }
  return $t
}

function Parse-ServersYaml {
  param([string]$path)
  $servers = @()
  $current = $null
  foreach ($line in Get-Content -Path $path -ErrorAction SilentlyContinue) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    if ($t -match '^\s*servers\s*:') { continue }
    if ($t -match '^\s*-\s*(.*)$') {
      if ($current) { $servers += $current }
      $current = @{}
      $rest = $Matches[1].Trim()
      if ($rest -match '^\s*([^:#]+?)\s*:\s*(.*?)\s*$') {
        $key = $Matches[1].Trim()
        $val = Trim-Value $Matches[2]
        if ($key) { $current[$key] = $val }
      }
      continue
    }
    if (-not $current) { continue }
    if ($t -match '^\s*([^:#]+?)\s*:\s*(.*?)\s*$') {
      $key = $Matches[1].Trim()
      $val = Trim-Value $Matches[2]
      if ($key) { $current[$key] = $val }
    }
  }
  if ($current) { $servers += $current }
  return $servers
}

function Load-Servers {
  $candidates = @(
    (Join-Path $PSScriptRoot "servers.yml"),
    (Join-Path $PSScriptRoot "servers.yaml"),
    "servers.yml",
    "servers.yaml"
  )
  $path = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $path) { return $null }
  return Parse-ServersYaml -path $path
}

function Find-Server {
  param($ctx, $servers)
  if (-not $servers) { return $null }
  foreach ($s in $servers) {
    if ($ctx.host -and $s.host -and ($s.host -ieq $ctx.host)) { return $s }
    if ($ctx.host_name) {
      if ($s.name -and ($s.name -ieq $ctx.host_name)) { return $s }
      if ($s.label -and ($s.label -ieq $ctx.host_name)) { return $s }
      if ($s.remark -and ($s.remark -ieq $ctx.host_name)) { return $s }
    }
    if ($ctx.host -and $s.name -and ($s.name -ieq $ctx.host)) { return $s }
  }
  return $null
}

function Is-LocalHost {
  param([string]$hostRaw, [string]$hostName)
  $local = $env:COMPUTERNAME
  if (-not $hostRaw -and -not $hostName) { return $true }
  if ($hostRaw -and $local -and ($hostRaw -ieq $local)) { return $true }
  if ($hostName -and $local -and ($hostName -ieq $local)) { return $true }
  if ($hostRaw -and ($hostRaw -eq "127.0.0.1" -or $hostRaw -eq "localhost")) { return $true }
  return $false
}

function Build-RemoteCommand {
  param([string]$tool, [string]$sessionId, [string]$prompt, [string]$cwd)
  $promptEsc = Escape-ForBashDoubleQuotes $prompt
  $cmd = ""
  if ($tool -eq "claude") {
    $cmd = "claude --resume $sessionId --print `"$promptEsc`""
  } else {
    $cmd = "codex exec resume $sessionId --skip-git-repo-check --json -c 'notify=[]' `"$promptEsc`""
  }
  if ($cwd) {
    $cwdEsc = Escape-ForBashDoubleQuotes $cwd
    $cmd = "cd `"$cwdEsc`" && $cmd"
  }
  return "bash -lc `"$cmd`""
}

function Build-BashLc {
  param([string]$cmd)
  $cmdEsc = Escape-ForBashDoubleQuotes $cmd
  return "bash -lc `"$cmdEsc`""
}

function Invoke-RemoteCommandSync {
  param($server, [string]$command)
  $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
  $ssh = Get-Command ssh -ErrorAction SilentlyContinue
  $hostAddr = $server.host
  $user = $server.user
  if (-not $user -and $server.username) { $user = $server.username }
  $target = if ($user) { "$user@$hostAddr" } else { $hostAddr }
  $port = $server.port
  $key = $server.key
  $password = $server.password

  if ($password -and $plink) {
    $args = @("-batch","-ssh",$target)
    if ($port) { $args += @("-P",$port) }
    if ($key) { $args += @("-i",$key) }
    $args += @("-pw",$password,$command)
    & $plink.Source @args | Out-Null
    return
  }
  if (-not $ssh) { throw "ssh not found in PATH." }
  $args = @()
  if ($port) { $args += @("-p",$port) }
  if ($key) { $args += @("-i",$key) }
  $args += @($target, $command)
  & $ssh.Source @args | Out-Null
}

function Upload-RemoteFile {
  param($server, [string]$localPath, [string]$remotePath)
  $pscp = Get-Command pscp.exe -ErrorAction SilentlyContinue
  $scp = Get-Command scp -ErrorAction SilentlyContinue
  $hostAddr = $server.host
  $user = $server.user
  if (-not $user -and $server.username) { $user = $server.username }
  $target = if ($user) { "$user@$hostAddr" } else { $hostAddr }
  $port = $server.port
  $key = $server.key
  $password = $server.password

  if ($password -and $pscp) {
    $args = @("-batch","-pw",$password)
    if ($port) { $args += @("-P",$port) }
    if ($key) { $args += @("-i",$key) }
    $args += @($localPath, ("{0}:{1}" -f $target, $remotePath))
    & $pscp.Source @args | Out-Null
    return
  }
  if ($password -and -not $pscp) { throw "pscp not found in PATH (password upload requires PuTTY/pscp)." }
  if (-not $scp) { throw "scp not found in PATH." }
  $args = @()
  if ($port) { $args += @("-P",$port) }
  if ($key) { $args += @("-i",$key) }
  $args += @($localPath, ("{0}:{1}" -f $target, $remotePath))
  & $scp.Source @args | Out-Null
}

function Start-RemoteCommand {
  param($server, [string]$command)
  $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
  $ssh = Get-Command ssh -ErrorAction SilentlyContinue
  $hostAddr = $server.host
  $user = $server.user
  if (-not $user -and $server.username) { $user = $server.username }
  $target = if ($user) { "$user@$hostAddr" } else { $hostAddr }
  $port = $server.port
  $key = $server.key
  $password = $server.password

  if ($password -and $plink) {
    $args = @("-batch","-ssh",$target)
    if ($port) { $args += @("-P",$port) }
    if ($key) { $args += @("-i",$key) }
    $args += @("-pw",$password,$command)
    Start-Process -FilePath $plink.Source -ArgumentList $args -WindowStyle Hidden | Out-Null
    return
  }
  if (-not $ssh) { throw "ssh not found in PATH." }
  $args = @()
  if ($port) { $args += @("-p",$port) }
  if ($key) { $args += @("-i",$key) }
  $args += @($target, $command)
  Start-Process -FilePath $ssh.Source -ArgumentList $args -WindowStyle Hidden | Out-Null
}

function Explain-RemoteUploadError {
  param([string]$message)
  if (-not $message) { return "远程图片上传失败，请检查远程配置与网络。" }
  if ($message -match 'pscp') {
    return "远程图片上传需要 PuTTY 的 pscp.exe（已填写密码时必须）。请安装 PuTTY 并将 pscp.exe 加入 PATH。"
  }
  if ($message -match 'scp') {
    return "远程图片上传需要 scp（OpenSSH Client）或 PuTTY 的 pscp.exe。请安装其中之一并加入 PATH。"
  }
  return "远程图片上传失败: $message"
}

function Continue-Session {
  param($ctx, [string]$prompt, $imageInfo, [string]$ThreadId)
  $sessionId = $ctx.session_id
  if (-not $sessionId -or $sessionId -eq "unknown") {
    Send-Tg "无法定位会话，请使用 /codex 或 /claude 命令。" $ThreadId
    return
  }
  $isClaude = $false
  if ($ctx.source -and ($ctx.source -match 'Claude')) { $isClaude = $true }
  $tool = if ($isClaude) { "claude" } else { "codex" }
  $isLocal = Is-LocalHost -hostRaw $ctx.host -hostName $ctx.host_name

  if ($imageInfo) {
    if ($isLocal) {
      if ($prompt) { $prompt = "@$($imageInfo.ref) $prompt" } else { $prompt = "@$($imageInfo.ref)" }
    }
  }

  if ($isLocal) {
    if ($isClaude) {
      Start-Claude -sessionId $sessionId -prompt $prompt -ThreadId $ThreadId
    } else {
      Start-Codex -sessionId $sessionId -prompt $prompt -ThreadId $ThreadId
    }
    return
  }
  $servers = Load-Servers
  $server = Find-Server -ctx $ctx -servers $servers
  if (-not $server) {
    Send-Tg "未找到远程服务器配置，请在 servers.yml 中添加对应主机。" $ThreadId
    return
  }
  if ($imageInfo) {
    try {
      if (-not $ctx.cwd) { throw "远程会话缺少工作目录，无法上传图片。" }
      $remoteDir = ($ctx.cwd.TrimEnd("/") + "/.notify")
      $mkdirCmd = Build-BashLc ("mkdir -p `"$remoteDir`"")
      Invoke-RemoteCommandSync -server $server -command $mkdirCmd
      $remotePath = ($remoteDir + "/" + $imageInfo.file_name)
      Upload-RemoteFile -server $server -localPath $imageInfo.local_path -remotePath $remotePath
      if ($prompt) { $prompt = "@$($imageInfo.remote_ref) $prompt" } else { $prompt = "@$($imageInfo.remote_ref)" }
    } catch {
      $msg = Explain-RemoteUploadError -message $_.Exception.Message
      Send-Tg $msg $ThreadId
      return
    }
  }
  $cmd = Build-RemoteCommand -tool $tool -sessionId $sessionId -prompt $prompt -cwd $ctx.cwd
  try {
    Start-RemoteCommand -server $server -command $cmd
    Send-Tg "已提交: 远程执行中…结果会自动推送" $ThreadId
  } catch {
    Send-Tg "远程执行失败: $($_.Exception.Message)" $ThreadId
  }
}

function Start-Codex {
  param([string]$sessionId, [string]$prompt, [switch]$UseLast, [string]$ThreadId)
  if (-not $prompt) { Send-Tg "用法: /codex <问题>  或  /codex <会话ID> <问题>" $ThreadId; return }

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
    Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Send-Tg "已提交: Codex 执行中…结果会自动推送" $ThreadId
  } catch {
    Write-BridgeLog ("codex start fail: " + $_.Exception.Message)
    Send-Tg "启动 Codex 失败: $($_.Exception.Message)" $ThreadId
  }
}

function Start-Claude {
  param([string]$sessionId, [string]$prompt, [switch]$UseLast, [string]$ThreadId)
  if (-not $prompt) { Send-Tg "用法: /claude <问题>  或  /claude <会话ID> <问题>" $ThreadId; return }

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
    Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Send-Tg "已提交: Claude 执行中…结果会自动推送" $ThreadId
  } catch {
    Write-BridgeLog ("claude start fail: " + $_.Exception.Message)
    Send-Tg "启动 Claude 失败: $($_.Exception.Message)" $ThreadId
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
    $irm = @{ Method = "Get"; Uri = $uri; TimeoutSec = 35 }
    if ($tgProxyUri) { $irm.Proxy = $tgProxyUri }
    $resp = Invoke-RestMethod @irm
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
    $threadId = $null
    if ($msg.message_thread_id) { $threadId = [string]$msg.message_thread_id }
    $text = Get-MessageText -msg $msg
    $hasText = -not [string]::IsNullOrWhiteSpace($text)
    $replyId = $null
    if ($msg.reply_to_message -and $msg.reply_to_message.message_id) { $replyId = [string]$msg.reply_to_message.message_id }
    $hasImage = $false
    if (Get-MessageImageFileId -msg $msg) { $hasImage = $true }
    if (-not $hasText -and -not $hasImage) { continue }

    $isCommand = $false
    if ($hasText -and $text -match '^(?i)/(help|codex|claude)\b') { $isCommand = $true }
    if ($hasText -and $text -match '^(?i)/help') {
      Send-Tg "/codex <问题>  或  /codex <会话ID> <问题>\n/claude <问题>  或  /claude <会话ID> <问题>\n/codex last <问题> | /claude last <问题>" $threadId
      continue
    }

    if ($replyId -and -not $isCommand) {
      $ctx = Get-ReplyContext -replyMessageId $replyId
      if (-not $ctx) {
        $ctx = Get-ReplyContextFromMessage -replyMsg $msg.reply_to_message
        if ($ctx -and $ctx.session_id) {
          $stateEntry = Get-SessionState -sessionId $ctx.session_id
          if ($stateEntry) {
            if (-not $ctx.cwd -and $stateEntry.cwd) { $ctx.cwd = $stateEntry.cwd }
            if (-not $ctx.source -and $stateEntry.source) { $ctx.source = $stateEntry.source }
          }
          if (-not $ctx.latest_message_id) {
            try {
              $map = Load-TelegramMap
              if ($map -and $map.sessions) {
                $prop = $map.sessions.PSObject.Properties[$ctx.session_id]
                if ($prop -and $prop.Value.latest_message_id) { $ctx.latest_message_id = $prop.Value.latest_message_id }
              }
            } catch {}
          }
        }
      }
      if (-not $ctx) {
        Write-BridgeLog ("reply context missing: replyId=" + $replyId)
        Send-Tg "请回复机器人推送消息（包含会话信息）。" $threadId
        continue
      }
      if ($ctx.latest_message_id -and ([string]$ctx.latest_message_id -ne $replyId)) {
        Send-Tg "仅支持回复该会话中最新的模型回复。" $threadId
        continue
      }
      if (-not $ctx.session_id -or $ctx.session_id -eq "unknown") {
        Send-Tg "无法定位会话，请使用 /codex 或 /claude 命令。" $threadId
        continue
      }

      $isRemote = -not (Is-LocalHost -hostRaw $ctx.host -hostName $ctx.host_name)

      $cwd = $ctx.cwd
      if (-not $cwd) { $cwd = (Get-Location).Path }
      $imageInfo = $null
      if ($hasImage) {
        if ($isRemote) {
          $imageInfo = Save-MessageImage -msg $msg -cwd $logDir -ForceLocal
        } else {
          $imageInfo = Save-MessageImage -msg $msg -cwd $cwd
        }
      }

      $prompt = $text
      if (-not $prompt -and -not $imageInfo) {
        Send-Tg "请输入文字或图片。" $threadId
        continue
      }

      if ($threadId) {
        $ctx | Add-Member -MemberType NoteProperty -Name thread_id -Value $threadId -Force
        Update-SessionThreadId -sessionId $ctx.session_id -threadId $threadId
      }
      Continue-Session -ctx $ctx -prompt $prompt -imageInfo $imageInfo -ThreadId $threadId
      continue
    }

    if ($hasText -and $text -match '^(?i)/codex\b(.*)$') {
      $rest = $Matches[1].Trim()
      if (-not $rest) { Send-Tg "用法: /codex <问题>  或  /codex <会话ID> <问题>" $threadId; continue }
      if ($rest -match '^(?i)last\s+(.+)$') {
        Start-Codex -UseLast -prompt $Matches[1] -ThreadId $threadId
      } elseif ($rest -match '^([0-9a-fA-F\-]{36})\s+(.+)$') {
        Start-Codex -sessionId $Matches[1] -prompt $Matches[2] -ThreadId $threadId
      } else {
        Start-Codex -UseLast -prompt $rest -ThreadId $threadId
      }
      continue
    }

    if ($hasText -and $text -match '^(?i)/claude\b(.*)$') {
      $rest = $Matches[1].Trim()
      if (-not $rest) { Send-Tg "用法: /claude <问题>  或  /claude <会话ID> <问题>" $threadId; continue }
      if ($rest -match '^(?i)last\s+(.+)$') {
        Start-Claude -UseLast -prompt $Matches[1] -ThreadId $threadId
      } elseif ($rest -match '^([0-9a-fA-F\-]{36})\s+(.+)$') {
        Start-Claude -sessionId $Matches[1] -prompt $Matches[2] -ThreadId $threadId
      } else {
        Start-Claude -UseLast -prompt $rest -ThreadId $threadId
      }
      continue
    }

    Send-Tg "未知命令，发送 /help 查看用法"
  }

  Start-Sleep -Seconds $PollSeconds
}

