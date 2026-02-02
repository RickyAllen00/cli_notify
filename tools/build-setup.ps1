#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OutDir = "dist",
  [switch]$NoExe
)

$root = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $root "bin"
$template = Join-Path $binDir "notify-setup.ps1"
$versionFile = Join-Path $root "VERSION"
$version = "0.0.0"
if (Test-Path $versionFile) {
  $version = (Get-Content -Path $versionFile -Raw).Trim()
}

if (-not (Test-Path $template)) { throw "Missing: $template" }

$payload = @{}
Get-ChildItem -Path $binDir -File | Where-Object { $_.Name -ne "notify-setup.ps1" } | ForEach-Object {
  $rel = $_.Name
  $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
  $payload[$rel] = [Convert]::ToBase64String($bytes)
}

$lines = @()
$lines += '$EmbeddedFiles = @{'
foreach ($k in $payload.Keys) {
  $lines += '  "' + $k + '" = "' + $payload[$k] + '"'
}
$lines += '}'
$payloadBlock = $lines -join "`r`n"

$src = Get-Content -Path $template -Raw -Encoding UTF8
$src = [System.Text.RegularExpressions.Regex]::Replace(
  $src,
  '\$EmbeddedFiles\s*=\s*@\{\}',
  [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $payloadBlock }
)

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outPs1 = Join-Path $OutDir "notify-setup.ps1"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outPs1, $src, $utf8Bom)

if ($NoExe) { return }

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
  Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -ErrorAction Stop

$outExe = Join-Path $OutDir "NotifySetup.exe"
Invoke-PS2EXE -InputFile $outPs1 -OutputFile $outExe -NoConsole
if ($version) {
  $outExeVersioned = Join-Path $OutDir ("NotifySetup-{0}.exe" -f $version)
  Copy-Item -Path $outExe -Destination $outExeVersioned -Force
}
