#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw "ASSERT: $Message" }
}

function New-TempDir {
  param([string]$Prefix = "cli_notify_test")
  $base = [IO.Path]::GetTempPath()
  $dir = Join-Path $base ($Prefix + "_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  return $dir
}

function Invoke-Pwsh {
  param([Parameter(Mandatory = $true)][string]$Command)
  & pwsh -NoProfile -ExecutionPolicy Bypass -Command $Command
  return $LASTEXITCODE
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $repoRoot "bin"
$notifyPath = Join-Path $binDir "notify.ps1"
$notifySetupPath = Join-Path $binDir "notify-setup.ps1"

Assert-True -Condition (Test-Path $notifyPath) -Message "Missing: $notifyPath"
Assert-True -Condition (Test-Path $notifySetupPath) -Message "Missing: $notifySetupPath"

# Disable side effects (toast/network) during tests
$disableFlags = @(
  (Join-Path $binDir "notify.windows.disabled"),
  (Join-Path $binDir "notify.wecom.disabled"),
  (Join-Path $binDir "notify.telegram.disabled")
)
$createdFlags = @()
foreach ($f in $disableFlags) {
  if (-not (Test-Path $f)) {
    New-Item -ItemType File -Path $f -Force | Out-Null
    $createdFlags += $f
  }
}

try {
  Write-Host "TEST: notify.ps1 handles empty LOCALAPPDATA"
  $notifyPathEsc = $notifyPath.Replace("'", "''")
  $cmd = @'
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = ''
$env:TELEGRAM_BOT_TOKEN = ''
$env:TELEGRAM_CHAT_ID = ''
try {
  & '__NOTIFY_PATH__' -Source 'Test'
  exit 0
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
'@
  $cmd = $cmd.Replace("__NOTIFY_PATH__", $notifyPathEsc)
  $exit = Invoke-Pwsh -Command $cmd
  Assert-True -Condition ($exit -eq 0) -Message "notify.ps1 crashed with empty LOCALAPPDATA (exit $exit)"

  Write-Host "TEST: notify.ps1 passes TELEGRAM_PROXY to Invoke-RestMethod"
  $tgDisabled = Join-Path $binDir "notify.telegram.disabled"
  $hadTgDisabled = Test-Path $tgDisabled
  if ($hadTgDisabled) { Remove-Item -Path $tgDisabled -Force -ErrorAction SilentlyContinue }
  try {
    $cmdProxy = @'
$ErrorActionPreference = 'Stop'

$global:irmCalled = $false
$global:proxySeen = $false
function global:Invoke-RestMethod {
  [CmdletBinding()]
  param(
    [string]$Method,
    [string]$Uri,
    [string]$ContentType,
    $Body,
    $Proxy
  )
  $global:irmCalled = $true
  if ($PSBoundParameters.ContainsKey('Proxy') -and $Proxy) { $global:proxySeen = $true }
  return [pscustomobject]@{ result = [pscustomobject]@{ message_id = 1 } }
}

$env:TELEGRAM_BOT_TOKEN = 'dummy'
$env:TELEGRAM_CHAT_ID = '123'
$env:TELEGRAM_PROXY = 'http://127.0.0.1:7890'

& '__NOTIFY_PATH__' -Source 'Test' -Title 'T' -Body 'B'

if (-not $global:irmCalled) { Write-Error 'Invoke-RestMethod not called'; exit 1 }
if (-not $global:proxySeen) { Write-Error 'missing -Proxy'; exit 1 }
exit 0
'@
    $cmdProxy = $cmdProxy.Replace("__NOTIFY_PATH__", $notifyPathEsc)
    $exitProxy = Invoke-Pwsh -Command $cmdProxy
    Assert-True -Condition ($exitProxy -eq 0) -Message "notify.ps1 did not pass TELEGRAM_PROXY (exit $exitProxy)"
  } finally {
    if ($hadTgDisabled) { New-Item -ItemType File -Path $tgDisabled -Force | Out-Null }
  }

  Write-Host "TEST: notify-setup.ps1 Install-Payload works when PSScriptRoot empty"
  $srcDir = New-TempDir -Prefix "cli_notify_payload_src"
  $dstDir = New-TempDir -Prefix "cli_notify_payload_dst"
  Set-Content -Path (Join-Path $srcDir "notify.ps1") -Value "# dummy" -Encoding UTF8
  Set-Content -Path (Join-Path $srcDir "remote-batch.ps1") -Value "# dummy" -Encoding UTF8
  Set-Content -Path (Join-Path $srcDir "notify-setup.ps1") -Value "# dummy" -Encoding UTF8

  $notifySetupPathEsc = $notifySetupPath.Replace("'", "''")
  $srcDirEsc = $srcDir.Replace("'", "''")
  $dstDirEsc = $dstDir.Replace("'", "''")
  $cmd2 = @'
$ErrorActionPreference = 'Stop'
$notifySetup = '__SETUP_PATH__'
$srcDir = '__SRC_DIR__'
$dstDir = '__DST_DIR__'

$content = Get-Content -Path $notifySetup -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
  throw ('Parse errors: ' + ($errors | ForEach-Object { $_.Message } | Out-String))
}

$f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-Payload' }, $true) | Select-Object -First 1
if (-not $f) { throw "Missing function: Install-Payload" }
Invoke-Expression $f.Extent.Text

$EmbeddedFiles = @{}
function Get-SelfPath { return (Join-Path $srcDir 'notify-setup.ps1') }

Install-Payload -targetDir $dstDir

$copied = Join-Path $dstDir 'notify.ps1'
if (-not (Test-Path $copied)) { throw 'notify.ps1 not copied' }
exit 0
'@
  $cmd2 = $cmd2.Replace("__SETUP_PATH__", $notifySetupPathEsc).Replace("__SRC_DIR__", $srcDirEsc).Replace("__DST_DIR__", $dstDirEsc)
  $exit2 = Invoke-Pwsh -Command $cmd2
  Assert-True -Condition ($exit2 -eq 0) -Message "Install-Payload failed when PSScriptRoot empty (exit $exit2)"

  Write-Host "ALL TESTS PASSED"
} finally {
  foreach ($f in $createdFlags) {
    Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
  }
}
