#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$NoBuild,
  [switch]$NoPush
)

$root = Split-Path -Parent $PSScriptRoot
$prev = Get-Location
Set-Location -Path $root
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
  function Get-GitHubToken {
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    return $null
  }

  function Get-GitHubRepo {
    $url = (git remote get-url origin) 2>$null
    if (-not $url) { return $null }
    $url = $url.Trim()
    # https://github.com/OWNER/REPO.git
    if ($url -match '^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
      return @{ owner = $Matches[1]; repo = $Matches[2] }
    }
    # git@github.com:OWNER/REPO.git
    if ($url -match '^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$') {
      return @{ owner = $Matches[1]; repo = $Matches[2] }
    }
    return $null
  }

  function Get-ReleaseNotesFromChangelog {
    param([string]$path, [string]$version)
    if (-not (Test-Path $path)) { return "" }
    $lines = Get-Content -Path $path -ErrorAction SilentlyContinue
    if (-not $lines) { return "" }
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match ('^##\s+' + [regex]::Escape($version) + '\s*$')) { $start = $i; break }
    }
    if ($start -lt 0) { return ($lines -join "`n") }
    $out = @()
    for ($j = $start; $j -lt $lines.Count; $j++) {
      if ($j -gt $start -and $lines[$j] -match '^##\s+') { break }
      $out += $lines[$j]
    }
    return ($out -join "`n")
  }

  function Invoke-GitHubApi {
    param(
      [string]$Method,
      [string]$Uri,
      [string]$Token,
      [object]$Body,
      [string]$InFile,
      [string]$ContentType
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $headers = @{
      Authorization = ("Bearer {0}" -f $Token)
      "User-Agent" = "cli-notify-release"
      Accept = "application/vnd.github+json"
      "X-GitHub-Api-Version" = "2022-11-28"
    }

    $args = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($ContentType) { $args.ContentType = $ContentType }
    if ($InFile) { $args.InFile = $InFile }
    if ($null -ne $Body) {
      if ($Body -is [string]) {
        $args.Body = $Body
      } else {
        $args.Body = ($Body | ConvertTo-Json -Depth 10)
        if (-not $ContentType) { $args.ContentType = "application/json" }
      }
    }
    return (Invoke-RestMethod @args)
  }

  function Ensure-GitHubRelease {
    param([string]$Owner, [string]$Repo, [string]$Tag, [string]$Token, [string]$Notes)
    $base = "https://api.github.com/repos/$Owner/$Repo"
    $createUri = "$base/releases"
    $body = @{ tag_name = $Tag; name = $Tag; body = $Notes; draft = $false; prerelease = $false }
    try {
      return (Invoke-GitHubApi -Method Post -Uri $createUri -Token $Token -Body $body)
    } catch {
      try {
        # already exists -> fetch by tag
        $getUri = "$base/releases/tags/$Tag"
        return (Invoke-GitHubApi -Method Get -Uri $getUri -Token $Token)
      } catch {
        throw
      }
    }
  }

  function Remove-ExistingAssetIfAny {
    param([string]$Owner, [string]$Repo, [int]$ReleaseId, [string]$Token, [string]$AssetName)
    $base = "https://api.github.com/repos/$Owner/$Repo"
    $assetsUri = "$base/releases/$ReleaseId/assets"
    $items = Invoke-GitHubApi -Method Get -Uri $assetsUri -Token $Token
    foreach ($a in $items) {
      if ($a.name -eq $AssetName) {
        $delUri = "$base/releases/assets/$($a.id)"
        Invoke-GitHubApi -Method Delete -Uri $delUri -Token $Token | Out-Null
      }
    }
  }

  function Upload-ReleaseAsset {
    param(
      [string]$Owner,
      [string]$Repo,
      [object]$Release,
      [string]$Token,
      [string]$FilePath
    )
    if (-not (Test-Path $FilePath)) { throw "Asset not found: $FilePath" }
    $name = [IO.Path]::GetFileName($FilePath)

    Remove-ExistingAssetIfAny -Owner $Owner -Repo $Repo -ReleaseId ([int]$Release.id) -Token $Token -AssetName $name

    $uploadBase = [string]$Release.upload_url
    $uploadBase = $uploadBase -replace '\{.*\}$',''
    $encoded = [System.Uri]::EscapeDataString($name)
    $uploadUri = "$uploadBase?name=$encoded"
    Invoke-GitHubApi -Method Post -Uri $uploadUri -Token $Token -InFile $FilePath -ContentType "application/octet-stream" | Out-Null
  }

  $token = Get-GitHubToken
  if (-not $token) {
    Write-Host "gh CLI not found, and GH_TOKEN/GITHUB_TOKEN is not set."
    Write-Host "请设置环境变量 GH_TOKEN 或 GITHUB_TOKEN（需要 repo 权限），然后重新运行 tools/release.ps1。"
    Set-Location -Path $prev
    exit 1
  }

  $repoInfo = Get-GitHubRepo
  if (-not $repoInfo) {
    Write-Host "无法从 git remote origin 解析 GitHub 仓库信息。"
    Set-Location -Path $prev
    exit 1
  }

  $assets = @(
    (Join-Path $root "dist\\NotifySetup.exe"),
    (Join-Path $root ("dist\\NotifySetup-{0}.exe" -f $version))
  )
  $notes = Get-ReleaseNotesFromChangelog -path (Join-Path $root "CHANGELOG.md") -version $version
  $release = Ensure-GitHubRelease -Owner $repoInfo.owner -Repo $repoInfo.repo -Tag $tag -Token $token -Notes $notes
  foreach ($a in $assets) {
    Upload-ReleaseAsset -Owner $repoInfo.owner -Repo $repoInfo.repo -Release $release -Token $token -FilePath $a
  }

  Write-Host "Release created/updated: $tag"
}

Set-Location -Path $prev
