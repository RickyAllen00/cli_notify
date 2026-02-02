#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$NoBuild,
  [switch]$NoPush
)

$root = Split-Path -Parent $PSScriptRoot
$versionFile = Join-Path $root "VERSION"
if (-not (Test-Path $versionFile)) { throw "Missing VERSION file." }
$version = (Get-Content -Path $versionFile -Raw).Trim()
if (-not $version) { throw "VERSION is empty." }
$tag = "v$version"

if (-not $NoBuild) {
  & (Join-Path $root "tools\\build-setup.ps1")
}

$existingTag = git tag --list $tag
if (-not $existingTag) {
  git tag -a $tag -m "Release $tag"
}

if (-not $NoPush) {
  git push origin $tag
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh) {
  $assets = @(
    (Join-Path $root "dist\\NotifySetup.exe"),
    (Join-Path $root ("dist\\NotifySetup-{0}.exe" -f $version))
  )
  $notesFile = Join-Path $root "CHANGELOG.md"
  gh release create $tag @assets --title $tag --notes-file $notesFile
} else {
  Write-Host "gh CLI not found. Install GitHub CLI or create the release manually."
}
