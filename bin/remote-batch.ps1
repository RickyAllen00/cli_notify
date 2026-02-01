#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ServersPath,
  [string]$Url = $env:WINDOWS_NOTIFY_URL,
  [string]$Token = $env:WINDOWS_NOTIFY_TOKEN,
  [switch]$DryRun
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

function Escape-ForBashDoubleQuotes {
  param([string]$s)
  if (-not $s) { return $s }
  $t = $s -replace '\\','\\\\'
  $t = $t -replace '"','\\"'
  $t = $t -replace '\$','\\$'
  $t = $t -replace '`','\\`'
  return $t
}

$notifyConfig = Load-NotifyConfig
if (-not $Url) { $Url = Get-NotifySetting -name "WINDOWS_NOTIFY_URL" -cfg $notifyConfig }
if (-not $Token) { $Token = Get-NotifySetting -name "WINDOWS_NOTIFY_TOKEN" -cfg $notifyConfig }
if (-not $Token) { $Token = Get-NotifySetting -name "NOTIFY_SERVER_TOKEN" -cfg $notifyConfig }

if (-not $Url -or -not $Token) {
  Write-Error "Missing WINDOWS_NOTIFY_URL or WINDOWS_NOTIFY_TOKEN. Set in .env or pass -Url/-Token."
  exit 1
}

if (-not $ServersPath) {
  $candidates = @(
    (Join-Path $PSScriptRoot "servers.yml"),
    (Join-Path $PSScriptRoot "servers.yaml"),
    "servers.yml",
    "servers.yaml"
  )
  $ServersPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $ServersPath -or -not (Test-Path $ServersPath)) {
  Write-Error "servers.yml not found. Create one and pass -ServersPath."
  exit 1
}

$servers = Parse-ServersYaml -path $ServersPath
if (-not $servers -or $servers.Count -eq 0) {
  Write-Error "No servers found in $ServersPath."
  exit 1
}

$plink = Get-Command plink.exe -ErrorAction SilentlyContinue
$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh -and -not $plink) {
  Write-Error "ssh or plink not found in PATH."
  exit 1
}

foreach ($s in $servers) {
  $host = $s.host
  if (-not $host) { Write-Warning "Skip server with empty host."; continue }
  $user = $s.user
  if (-not $user -and $s.username) { $user = $s.username }
  $name = $s.name
  if (-not $name -and $s.label) { $name = $s.label }
  if (-not $name -and $s.remark) { $name = $s.remark }
  $port = $s.port
  $key = $s.key
  $password = $s.password

  $target = if ($user) { "$user@$host" } else { $host }

  $urlEsc = Escape-ForBashDoubleQuotes $Url
  $tokenEsc = Escape-ForBashDoubleQuotes $Token
  $hostEsc = Escape-ForBashDoubleQuotes $host
  $nameEsc = Escape-ForBashDoubleQuotes $name

  $installCmd = "curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- --url `"$urlEsc`" --token `"$tokenEsc`" --host `"$hostEsc`""
  if ($name) { $installCmd += " --name `"$nameEsc`"" }

  if ($DryRun) {
    Write-Host "[DRY] $target -> $installCmd"
    continue
  }

  if ($password -and $plink) {
    $args = @("-batch","-ssh",$target)
    if ($port) { $args += @("-P",$port) }
    if ($key) { $args += @("-i",$key) }
    $args += @("-pw",$password,$installCmd)
    & $plink @args
  } else {
    $args = @()
    if ($port) { $args += @("-p",$port) }
    if ($key) { $args += @("-i",$key) }
    $args += @($target, $installCmd)
    & $ssh @args
  }
}
