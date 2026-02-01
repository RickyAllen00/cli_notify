#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Prefix = $env:NOTIFY_SERVER_PREFIX,
  [int]$Port = $(if ($env:NOTIFY_SERVER_PORT) { [int]$env:NOTIFY_SERVER_PORT } else { 9412 }),
  [string]$Token = $env:NOTIFY_SERVER_TOKEN,
  [switch]$AllowAnonymous
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
if (-not $PSBoundParameters.ContainsKey("Prefix")) { $Prefix = Get-NotifySetting -name "NOTIFY_SERVER_PREFIX" -cfg $notifyConfig }
if (-not $PSBoundParameters.ContainsKey("Port")) {
  $p = Get-NotifySetting -name "NOTIFY_SERVER_PORT" -cfg $notifyConfig
  if ($p) { $Port = [int]$p }
}
if (-not $PSBoundParameters.ContainsKey("Token")) { $Token = Get-NotifySetting -name "NOTIFY_SERVER_TOKEN" -cfg $notifyConfig }

Add-Type -AssemblyName System.Web

$bin = Split-Path -Parent $MyInvocation.MyCommand.Path
$notifyScript = Join-Path $bin "notify.ps1"

$logDir = Join-Path $env:LOCALAPPDATA "notify"
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
$logFile = Join-Path $logDir "notify-server.log"
function Write-ServerLog {
  param([string]$msg)
  try { Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " " + $msg) } catch {}
}

# Single-instance guard (per-user)
$mutex = $null
$mutexCreated = $false
try {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutexName = "Local\\NotifyServer-" + $sid
  $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
} catch {
  $mutexCreated = $true
}
if (-not $mutexCreated) {
  Write-ServerLog "server already running"
  return
}

if (-not $Prefix) {
  $Prefix = "http://127.0.0.1:$Port/"
}

if (-not $AllowAnonymous -and -not $Token) {
  Write-ServerLog "missing NOTIFY_SERVER_TOKEN; exit"
  return
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
try {
  $listener.Start()
  Write-ServerLog ("listening on " + $Prefix)
} catch {
  Write-ServerLog ("failed to start listener: " + $_.Exception.Message)
  return
}

function Get-QueryValue {
  param([System.Net.HttpListenerRequest]$req, [string]$name)
  try {
    $qs = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
    return $qs.Get($name)
  } catch { return $null }
}

function Write-Response {
  param([System.Net.HttpListenerResponse]$resp, [int]$code, [string]$text)
  try {
    $resp.StatusCode = $code
    $resp.ContentType = "application/json; charset=utf-8"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch {}
  try { $resp.OutputStream.Close() } catch {}
}

try {
  while ($true) {
    $context = $listener.GetContext()
    $req = $context.Request
    $resp = $context.Response

    if ($req.HttpMethod -ne "POST") {
      Write-Response $resp 405 "{""ok"":false,""error"":""method_not_allowed""}"
      continue
    }

    $path = $req.Url.AbsolutePath
    if ($path -ne "/" -and $path -ne "/notify") {
      Write-Response $resp 404 "{""ok"":false,""error"":""not_found""}"
      continue
    }

    $reqToken = $req.Headers["X-Notify-Token"]
    if (-not $reqToken) { $reqToken = Get-QueryValue -req $req -name "token" }
    $auth = $req.Headers["Authorization"]
    if (-not $reqToken -and $auth -and $auth -match '^Bearer\s+(.+)$') { $reqToken = $Matches[1] }

    if (-not $AllowAnonymous -and $Token -and $reqToken -ne $Token) {
      Write-Response $resp 401 "{""ok"":false,""error"":""unauthorized""}"
      continue
    }

    $source = $req.Headers["X-Notify-Source"]
    if (-not $source) { $source = Get-QueryValue -req $req -name "source" }
    if (-not $source) { $source = "Remote" }

    $remoteHost = $req.Headers["X-Notify-Host"]
    if (-not $remoteHost) { $remoteHost = Get-QueryValue -req $req -name "host" }

    $remoteHostName = $req.Headers["X-Notify-Host-Name"]
    if (-not $remoteHostName) { $remoteHostName = Get-QueryValue -req $req -name "host_name" }

    $encoding = if ($req.ContentEncoding) { $req.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader = New-Object IO.StreamReader($req.InputStream, $encoding)
    $body = $reader.ReadToEnd()

    $payload = $null
    if ($body) {
      try { $payload = $body | ConvertFrom-Json } catch {}
    }
    if ($payload) {
      if ($remoteHost) { $payload | Add-Member -MemberType NoteProperty -Name host -Value $remoteHost -Force }
      if ($remoteHostName) { $payload | Add-Member -MemberType NoteProperty -Name host_name -Value $remoteHostName -Force }
      if ($source) { $payload | Add-Member -MemberType NoteProperty -Name source -Value $source -Force }
      $body = $payload | ConvertTo-Json -Depth 10
    }

    try {
      if ($body) {
        & $notifyScript -Source $source $body
      } else {
        & $notifyScript -Source $source -Title "$source" -Body "empty payload"
      }
      Write-Response $resp 200 "{""ok"":true}"
    } catch {
      Write-ServerLog ("notify failed: " + $_.Exception.Message)
      Write-Response $resp 500 "{""ok"":false,""error"":""notify_failed""}"
    }
  }
} catch {
  Write-ServerLog ("listener error: " + $_.Exception.Message)
} finally {
  try { $listener.Stop() } catch {}
  if ($mutex -and $mutexCreated) {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
  }
}
