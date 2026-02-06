#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$ApplyRemoteConfig,
  [int]$Port,
  [string]$Prefix,
  [string]$RuleName,
  [string]$InstallDir
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$EmbeddedFiles = @{}

function Test-IsAdmin {
  try {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  } catch { return $false }
}

function Get-SelfPath {
  if ($PSCommandPath) { return $PSCommandPath }
  if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
  try { return (Get-Process -Id $PID).Path } catch { return $null }
}

function New-RandomToken {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return [Convert]::ToBase64String($bytes)
}

function Get-LocalIPv4 {
  try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254*" } |
      Sort-Object -Property InterfaceMetric
    if ($ips -and $ips.Count -gt 0) { return $ips[0].IPAddress }
  } catch {}
  try {
    $ip = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
      Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne "127.0.0.1" } |
      Select-Object -First 1
    if ($ip) { return $ip.ToString() }
  } catch {}
  return $null
}

function Build-NotifyUrl {
  param([int]$port, [string]$ip)
  if (-not $ip) { return "" }
  return ("http://{0}:{1}/notify" -f $ip, $port)
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

function Format-EnvValue {
  param([string]$val)
  if ($null -eq $val) { return "" }
  $v = [string]$val
  if ($v -match '\s|#') { return '"' + $v + '"' }
  return $v
}

function Update-EnvFile {
  param([string]$path, [hashtable]$updates)
  $lines = @()
  if (Test-Path $path) { $lines = Get-Content -Path $path -ErrorAction SilentlyContinue }
  $seen = @{}
  $out = @()
  foreach ($line in $lines) {
    if ($line -match '^\s*([^=]+?)\s*=' ) {
      $k = $Matches[1].Trim()
      if ($updates.ContainsKey($k)) {
        $out += ($k + "=" + (Format-EnvValue $updates[$k]))
        $seen[$k] = $true
        continue
      }
    }
    $out += $line
  }
  foreach ($k in $updates.Keys) {
    if (-not $seen.ContainsKey($k)) {
      $out += ($k + "=" + (Format-EnvValue $updates[$k]))
    }
  }
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -Path $path -Value $out -Encoding UTF8
}

function Ensure-EnvTemplate {
  param([string]$path)
  if (Test-Path $path) { return }
  $content = @(
    "# Notify config (do not commit secrets)",
    "WECOM_WEBHOOK=",
    "TELEGRAM_BOT_TOKEN=",
    "TELEGRAM_CHAT_ID=",
    "NOTIFY_SERVER_TOKEN=",
    "NOTIFY_SERVER_PREFIX=",
    "NOTIFY_SERVER_PORT=",
    "WINDOWS_NOTIFY_URL=",
    "WINDOWS_NOTIFY_TOKEN="
  )
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -Path $path -Value $content -Encoding UTF8
}

function Test-PortAvailable {
  param([int]$port)
  try {
    $x = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($x) { return $false }
  } catch {}
  return $true
}

function Ensure-UrlAcl {
  param([string]$url)
  if (-not $url.EndsWith("/")) { $url = $url + "/" }
  $existing = (& netsh http show urlacl) -join "`n"
  if ($existing -match [regex]::Escape($url)) { return }
  & netsh http add urlacl url=$url user=$env:USERNAME | Out-Null
}

function Ensure-FirewallRule {
  param([int]$port, [string]$name)
  $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
  if (-not $rule) {
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any | Out-Null
  }
}

if ($ApplyRemoteConfig) {
  if (-not $Prefix) { $Prefix = "http://+:$Port/" }
  if (-not $RuleName) { $RuleName = "Notify Server $Port" }
  if (-not (Test-IsAdmin)) { exit 1 }
  Ensure-UrlAcl -url $Prefix
  Ensure-FirewallRule -port $Port -name $RuleName
  exit 0
}

function Apply-RemoteConfig {
  param([int]$port, [string]$prefix)
  if (-not $prefix) { $prefix = "http://+:$port/" }
  $rule = "Notify Server $port"
  if (Test-IsAdmin) {
    Ensure-UrlAcl -url $prefix
    Ensure-FirewallRule -port $port -name $rule
    return $true
  }
  $self = Get-SelfPath
  if (-not $self) { return $false }
  $args = @("-ApplyRemoteConfig","-Port",$port,"-Prefix",$prefix,"-RuleName",$rule)
  if ([IO.Path]::GetExtension($self).ToLower() -eq ".ps1") {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList (@("-NoProfile","-ExecutionPolicy","Bypass","-File",$self) + $args) -Wait | Out-Null
  } else {
    Start-Process -FilePath $self -Verb RunAs -ArgumentList $args -Wait | Out-Null
  }
  return $true
}

function Set-Autostart {
  param([string]$name, [string]$value, [bool]$enable)
  $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  if ($enable) {
    New-ItemProperty -Path $runKey -Name $name -Value $value -PropertyType String -Force | Out-Null
  } else {
    Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
  }
}

function Write-EmbeddedFiles {
  param([string]$targetDir)
  foreach ($k in $EmbeddedFiles.Keys) {
    $dest = Join-Path $targetDir $k
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = [Convert]::FromBase64String($EmbeddedFiles[$k])
    [System.IO.File]::WriteAllBytes($dest, $bytes)
  }
}

function Install-Payload {
  param([string]$targetDir)
  if ($EmbeddedFiles.Count -gt 0) {
    Write-EmbeddedFiles -targetDir $targetDir
    return
  }
  $sourceDir = $PSScriptRoot
  if (-not $sourceDir) {
    $self = Get-SelfPath
    if ($self) { $sourceDir = Split-Path -Parent $self }
  }
  if (-not $sourceDir) { throw "无法定位安装源目录。" }
  $hasLocal = Test-Path (Join-Path $sourceDir "notify.ps1")
  if ($hasLocal) {
    Get-ChildItem -Path $sourceDir -File | Where-Object { $_.Name -ne "notify-setup.ps1" } | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination (Join-Path $targetDir $_.Name) -Force
    }
    return
  }
  throw "无法找到安装文件。"
}

function Yaml-Quote {
  param([string]$s)
  if ($null -eq $s) { return "" }
  $t = $s -replace '"','\"'
  return '"' + $t + '"'
}

function Configure-RemoteLinux {
  param(
    [string]$targetDir,
    [string]$url,
    [string]$token,
    [object[]]$servers
  )
  $remoteScript = Join-Path $targetDir "remote-batch.ps1"
  if (-not (Test-Path $remoteScript)) { throw "缺少 remote-batch.ps1，无法配置远程服务器。" }

  $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
  $ssh = Get-Command ssh -ErrorAction SilentlyContinue
  if (-not $ssh -and -not $plink) { throw "未检测到 ssh 或 plink。" }
  if (-not $servers -or $servers.Count -eq 0) { throw "未填写任何服务器。" }
  if ($servers | Where-Object { $_.password } | Select-Object -First 1) {
    if (-not $plink) { throw "已填写密码但未找到 PuTTY/plink，请安装 PuTTY 或改用 SSH Key。" }
  }

  $lines = @("servers:")
  foreach ($s in $servers) {
    if (-not $s.host) { continue }
    $lines += "  - host: $(Yaml-Quote $s.host)"
    if ($s.user) { $lines += "    user: $(Yaml-Quote $s.user)" }
    if ($s.name) { $lines += "    name: $(Yaml-Quote $s.name)" }
    if ($s.port) { $lines += "    port: $($s.port)" }
    if ($s.key) { $lines += "    key: $(Yaml-Quote $s.key)" }
    if ($s.password) { $lines += "    password: $(Yaml-Quote $s.password)" }
  }

  $tmp = Join-Path $env:TEMP ("notify-servers-" + [guid]::NewGuid().ToString("N") + ".yml")
  Set-Content -Path $tmp -Value $lines -Encoding UTF8

  $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$remoteScript,"-ServersPath",$tmp,"-Url",$url,"-Token",$token)
  Start-Process -FilePath "powershell.exe" -ArgumentList $args -Wait | Out-Null

  Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Notify 安装向导"
$form.Size = New-Object System.Drawing.Size(680, 950)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$gbInstall = New-Object System.Windows.Forms.GroupBox
$gbInstall.Text = "安装位置"
$gbInstall.SetBounds(12, 12, 640, 90)

$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Text = "目录"
$lblDir.AutoSize = $true
$lblDir.Location = New-Object System.Drawing.Point(16, 35)

$tbDir = New-Object System.Windows.Forms.TextBox
$tbDir.SetBounds(80, 32, 450, 24)
$defaultBase = $null
try { $defaultBase = [Environment]::GetFolderPath("UserProfile") } catch {}
if (-not $defaultBase) { $defaultBase = $env:USERPROFILE }
if (-not $defaultBase -and $env:HOMEDRIVE -and $env:HOMEPATH) { $defaultBase = "$($env:HOMEDRIVE)$($env:HOMEPATH)" }
if (-not $defaultBase) { $defaultBase = "C:\\Users\\Public" }
$defaultInstall = Join-Path $defaultBase "bin"
if ($InstallDir) { $defaultInstall = $InstallDir }
$tbDir.Text = $defaultInstall

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "浏览..."
$btnBrowse.SetBounds(540, 30, 80, 28)

$gbInstall.Controls.AddRange(@($lblDir,$tbDir,$btnBrowse))

$gbWecom = New-Object System.Windows.Forms.GroupBox
$gbWecom.Text = "企业微信"
$gbWecom.SetBounds(12, 110, 640, 110)

$cbWecom = New-Object System.Windows.Forms.CheckBox
$cbWecom.Text = "现在配置企业微信机器人"
$cbWecom.AutoSize = $true
$cbWecom.Location = New-Object System.Drawing.Point(16, 28)

$lblWecom = New-Object System.Windows.Forms.Label
$lblWecom.Text = "Webhook"
$lblWecom.AutoSize = $true
$lblWecom.Location = New-Object System.Drawing.Point(16, 62)

$tbWecom = New-Object System.Windows.Forms.TextBox
$tbWecom.SetBounds(100, 58, 520, 24)
$tbWecom.Enabled = $false

$gbWecom.Controls.AddRange(@($cbWecom,$lblWecom,$tbWecom))

$gbTg = New-Object System.Windows.Forms.GroupBox
$gbTg.Text = "Telegram"
$gbTg.SetBounds(12, 230, 640, 150)

$cbTg = New-Object System.Windows.Forms.CheckBox
$cbTg.Text = "现在配置 Telegram"
$cbTg.AutoSize = $true
$cbTg.Location = New-Object System.Drawing.Point(16, 28)

$lnkTgHelp = New-Object System.Windows.Forms.LinkLabel
$lnkTgHelp.Text = "获取方式"
$lnkTgHelp.AutoSize = $true
$lnkTgHelp.Location = New-Object System.Drawing.Point(140, 28)

$lblTgToken = New-Object System.Windows.Forms.Label
$lblTgToken.Text = "Bot Token"
$lblTgToken.AutoSize = $true
$lblTgToken.Location = New-Object System.Drawing.Point(16, 62)

$tbTgToken = New-Object System.Windows.Forms.TextBox
$tbTgToken.SetBounds(100, 58, 520, 24)
$tbTgToken.Enabled = $false

$lblTgChat = New-Object System.Windows.Forms.Label
$lblTgChat.Text = "Chat ID"
$lblTgChat.AutoSize = $true
$lblTgChat.Location = New-Object System.Drawing.Point(16, 98)

$tbTgChat = New-Object System.Windows.Forms.TextBox
$tbTgChat.SetBounds(100, 94, 520, 24)
$tbTgChat.Enabled = $false

$gbTg.Controls.AddRange(@($cbTg,$lnkTgHelp,$lblTgToken,$tbTgToken,$lblTgChat,$tbTgChat))

$gbRemote = New-Object System.Windows.Forms.GroupBox
$gbRemote.Text = "远程通知服务端 / 远程服务器"
$gbRemote.SetBounds(12, 390, 640, 200)
$remoteBaseHeight = 190
$serversPanelHeight = 190

$cbRemote = New-Object System.Windows.Forms.CheckBox
$cbRemote.Text = "启用远程通知服务端（用于 Linux 推送）"
$cbRemote.AutoSize = $true
$cbRemote.Location = New-Object System.Drawing.Point(16, 28)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "端口"
$lblPort.AutoSize = $true
$lblPort.Location = New-Object System.Drawing.Point(16, 60)

$nudPort = New-Object System.Windows.Forms.NumericUpDown
$nudPort.SetBounds(100, 56, 100, 24)
$nudPort.Minimum = 1
$nudPort.Maximum = 65535
$nudPort.Value = 9412
$nudPort.Enabled = $false

$lblToken = New-Object System.Windows.Forms.Label
$lblToken.Text = "Token"
$lblToken.AutoSize = $true
$lblToken.Location = New-Object System.Drawing.Point(16, 92)

$tbToken = New-Object System.Windows.Forms.TextBox
$tbToken.SetBounds(100, 88, 400, 24)
$tbToken.Enabled = $false

$btnGenToken = New-Object System.Windows.Forms.Button
$btnGenToken.Text = "生成随机 Token"
$btnGenToken.SetBounds(510, 86, 110, 28)
$btnGenToken.Enabled = $false

$lblWinUrl = New-Object System.Windows.Forms.Label
$lblWinUrl.Text = "Windows 访问地址"
$lblWinUrl.AutoSize = $true
$lblWinUrl.Location = New-Object System.Drawing.Point(16, 124)

$tbWinUrl = New-Object System.Windows.Forms.TextBox
$tbWinUrl.SetBounds(140, 120, 380, 24)
$tbWinUrl.Enabled = $false

$btnDetectIp = New-Object System.Windows.Forms.Button
$btnDetectIp.Text = "自动填充"
$btnDetectIp.SetBounds(530, 118, 90, 28)
$btnDetectIp.Enabled = $false

$cbLinux = New-Object System.Windows.Forms.CheckBox
$cbLinux.Text = "安装时配置远程服务器（最多5台）"
$cbLinux.AutoSize = $true
$cbLinux.Location = New-Object System.Drawing.Point(16, 156)
$cbLinux.Enabled = $false

$lnkToggleServers = New-Object System.Windows.Forms.LinkLabel
$lnkToggleServers.Text = "展开服务器配置 ▼"
$lnkToggleServers.AutoSize = $true
$lnkToggleServers.Location = New-Object System.Drawing.Point(260, 156)
$lnkToggleServers.Enabled = $false

$panelServers = New-Object System.Windows.Forms.Panel
$panelServers.SetBounds(16, 180, 600, $serversPanelHeight)
$panelServers.Visible = $false
$panelServers.Enabled = $false

$lblServersTip = New-Object System.Windows.Forms.Label
$lblServersTip.Text = "最多 5 台；Host 为空的行会忽略；Key 为空可用密码（明文）或命令行提示输入"
$lblServersTip.AutoSize = $true
$lblServersTip.Location = New-Object System.Drawing.Point(0, 0)

$gridServers = New-Object System.Windows.Forms.DataGridView
$gridServers.SetBounds(0, 20, 600, 140)
$gridServers.AllowUserToAddRows = $false
$gridServers.AllowUserToResizeRows = $false
$gridServers.RowHeadersVisible = $false
$gridServers.ColumnHeadersHeightSizeMode = "DisableResizing"
$gridServers.ScrollBars = "None"
$gridServers.ColumnCount = 6
$gridServers.Columns[0].Name = "Host"
$gridServers.Columns[1].Name = "用户"
$gridServers.Columns[2].Name = "端口"
$gridServers.Columns[3].Name = "备注"
$gridServers.Columns[4].Name = "私钥"
$gridServers.Columns[5].Name = "密码"
$gridServers.Columns[0].Width = 120
$gridServers.Columns[1].Width = 70
$gridServers.Columns[2].Width = 50
$gridServers.Columns[3].Width = 80
$gridServers.Columns[4].Width = 140
$gridServers.Columns[5].Width = 120
$gridServers.RowCount = 5
for ($i = 0; $i -lt 5; $i++) { $gridServers.Rows[$i].Cells[2].Value = 22 }

$panelServers.Controls.AddRange(@($lblServersTip,$gridServers))

$gbRemote.Controls.AddRange(@(
  $cbRemote,$lblPort,$nudPort,$lblToken,$tbToken,$btnGenToken,
  $lblWinUrl,$tbWinUrl,$btnDetectIp,$cbLinux,$lnkToggleServers,$panelServers
))

$gbAuto = New-Object System.Windows.Forms.GroupBox
$gbAuto.Text = "开机自启"
$gbAuto.SetBounds(12, 0, 640, 90)

$cbAutoTray = New-Object System.Windows.Forms.CheckBox
$cbAutoTray.Text = "托盘菜单"
$cbAutoTray.AutoSize = $true
$cbAutoTray.Location = New-Object System.Drawing.Point(16, 32)
$cbAutoTray.Checked = $true

$cbAutoServer = New-Object System.Windows.Forms.CheckBox
$cbAutoServer.Text = "远程通知服务端"
$cbAutoServer.AutoSize = $true
$cbAutoServer.Location = New-Object System.Drawing.Point(400, 32)
$cbAutoServer.Enabled = $false

$lblAutoTg = New-Object System.Windows.Forms.Label
$lblAutoTg.Text = "Telegram Bridge：随 Telegram 配置自动开启"
$lblAutoTg.AutoSize = $true
$lblAutoTg.Location = New-Object System.Drawing.Point(200, 34)

$gbAuto.Controls.AddRange(@($cbAutoTray,$lblAutoTg,$cbAutoServer))

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "安装"
$btnInstall.SetBounds(470, 0, 80, 30)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "取消"
$btnCancel.SetBounds(560, 0, 80, 30)

$form.Controls.AddRange(@(
  $gbInstall,$gbWecom,$gbTg,$gbRemote,$gbAuto,$btnInstall,$btnCancel
))

$localIp = Get-LocalIPv4
function Refresh-WinUrl {
  if (-not $localIp) { $localIp = Get-LocalIPv4 }
  $url = Build-NotifyUrl -port ([int]$nudPort.Value) -ip $localIp
  if ($url) { $tbWinUrl.Text = $url }
}

function Update-RemoteSettings {
  $port = [int]$nudPort.Value
  if ($tbWinUrl.Text -match '^(https?://[^:/]+):\d+/notify$') {
    $tbWinUrl.Text = ("{0}:{1}/notify" -f $Matches[1], $port)
  } elseif (-not $tbWinUrl.Text) {
    Refresh-WinUrl
  }
}

function Refresh-Layout {
  $gbAuto.Top = $gbRemote.Bottom + 10
  $btnInstall.Top = $gbAuto.Bottom + 10
  $btnCancel.Top = $btnInstall.Top
  $form.ClientSize = New-Object System.Drawing.Size(680, ($btnInstall.Bottom + 20))
}

function Set-ServersPanel {
  param([bool]$expanded)
  if ($expanded) {
    $panelServers.Visible = $true
    $gbRemote.Height = $remoteBaseHeight + $serversPanelHeight
    $lnkToggleServers.Text = "收起服务器配置 ▲"
  } else {
    $panelServers.Visible = $false
    $gbRemote.Height = $remoteBaseHeight
    $lnkToggleServers.Text = "展开服务器配置 ▼"
  }
  Refresh-Layout
}

function Get-ServersFromGrid {
  $servers = @()
  foreach ($row in $gridServers.Rows) {
    $host = [string]$row.Cells[0].Value
    if ([string]::IsNullOrWhiteSpace($host)) { continue }
    $server = @{ host = $host.Trim() }

    $user = [string]$row.Cells[1].Value
    if (-not [string]::IsNullOrWhiteSpace($user)) { $server.user = $user.Trim() }

    $portVal = [string]$row.Cells[2].Value
    if ($portVal -match '^\d+$') { $server.port = [int]$portVal }

    $name = [string]$row.Cells[3].Value
    if (-not [string]::IsNullOrWhiteSpace($name)) { $server.name = $name.Trim() }

    $key = [string]$row.Cells[4].Value
    if (-not [string]::IsNullOrWhiteSpace($key)) { $server.key = $key.Trim() }

    $pwd = [string]$row.Cells[5].Value
    if (-not [string]::IsNullOrWhiteSpace($pwd)) { $server.password = $pwd }

    $servers += $server
  }
  return $servers
}

$cbWecom.Add_CheckedChanged({ $tbWecom.Enabled = $cbWecom.Checked })
$cbTg.Add_CheckedChanged({
  $tbTgToken.Enabled = $cbTg.Checked
  $tbTgChat.Enabled = $cbTg.Checked
})
$lnkTgHelp.Add_Click({
  $msg = @(
    "1) 打开 Telegram，搜索 @BotFather 创建机器人，拿到 Bot Token。"
    "2) 给你的机器人发送 /start。"
    "3) 在浏览器访问："
    "   https://api.telegram.org/bot<你的Token>/getUpdates"
    "   找到 chat.id 作为 Chat ID。"
  ) -join "`n"
  [System.Windows.Forms.MessageBox]::Show($msg, "Telegram 配置帮助")
})
$cbRemote.Add_CheckedChanged({
  $enabled = $cbRemote.Checked
  $nudPort.Enabled = $enabled
  $tbToken.Enabled = $enabled
  $btnGenToken.Enabled = $enabled
  $tbWinUrl.Enabled = $enabled
  $btnDetectIp.Enabled = $enabled
  $cbLinux.Enabled = $enabled
  $lnkToggleServers.Enabled = $enabled
  $cbAutoServer.Enabled = $enabled
  if ($enabled) { $cbAutoServer.Checked = $true } else { $cbAutoServer.Checked = $false }
  if (-not $enabled) {
    $cbLinux.Checked = $false
    Set-ServersPanel -expanded:$false
  }
  if ($enabled) { Update-RemoteSettings }
})
$cbLinux.Add_CheckedChanged({
  $enabled = $cbLinux.Checked
  $panelServers.Enabled = $enabled
  $gridServers.Enabled = $enabled
  if ($enabled -and -not $cbRemote.Checked) { $cbRemote.Checked = $true }
  if ($enabled) { Set-ServersPanel -expanded:$true } else { Set-ServersPanel -expanded:$false }
  if ($enabled -and -not $tbWinUrl.Text) { Refresh-WinUrl }
})
$lnkToggleServers.Add_Click({
  if (-not $cbLinux.Checked) { return }
  Set-ServersPanel -expanded:(-not $panelServers.Visible)
})
$nudPort.Add_ValueChanged({ Update-RemoteSettings })
$btnGenToken.Add_Click({ $tbToken.Text = New-RandomToken })
$btnDetectIp.Add_Click({ Refresh-WinUrl })

$btnBrowse.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.SelectedPath = $tbDir.Text
  if ($dlg.ShowDialog() -eq "OK") { $tbDir.Text = $dlg.SelectedPath }
})

$btnInstall.Add_Click({
  $targetDir = $tbDir.Text.Trim()
  if (-not $targetDir) {
    [System.Windows.Forms.MessageBox]::Show("请选择安装目录。", "提示")
    return
  }
  try { if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null } }
  catch { [System.Windows.Forms.MessageBox]::Show("无法创建目录：$targetDir", "错误"); return }

  try { Install-Payload -targetDir $targetDir }
  catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "错误"); return }

  $envPath = Join-Path $targetDir ".env"
  Ensure-EnvTemplate -path $envPath
  $updates = @{}

  if ($cbWecom.Checked) { $updates["WECOM_WEBHOOK"] = $tbWecom.Text.Trim() }
  if ($cbTg.Checked) {
    $updates["TELEGRAM_BOT_TOKEN"] = $tbTgToken.Text.Trim()
    $updates["TELEGRAM_CHAT_ID"] = $tbTgChat.Text.Trim()
  }

  $remotePort = [int]$nudPort.Value
  $remotePrefix = "http://+:$remotePort/"
  $notifyToken = $null
  $servers = @()
  if ($cbRemote.Checked) {
    if (-not (Test-PortAvailable -port $remotePort)) {
      [System.Windows.Forms.MessageBox]::Show("端口 $remotePort 已被占用，请更换端口。", "端口冲突")
      return
    }
    $token = $tbToken.Text.Trim()
    if (-not $token) { $token = New-RandomToken; $tbToken.Text = $token }
    $notifyToken = $token
    $updates["NOTIFY_SERVER_TOKEN"] = $token
    $updates["NOTIFY_SERVER_PREFIX"] = $remotePrefix
    $updates["NOTIFY_SERVER_PORT"] = "$remotePort"

    $winUrl = $tbWinUrl.Text.Trim()
    if (-not $winUrl) {
      if (-not $localIp) { $localIp = Get-LocalIPv4 }
      $winUrl = Build-NotifyUrl -port $remotePort -ip $localIp
    }
    if ($winUrl) { $updates["WINDOWS_NOTIFY_URL"] = $winUrl }
    $updates["WINDOWS_NOTIFY_TOKEN"] = $token
  }

  if ($cbLinux.Checked) {
    if (-not $notifyToken) {
      [System.Windows.Forms.MessageBox]::Show("请先启用远程通知服务端并生成 Token。", "提示")
      return
    }
    $linuxUrl = $tbWinUrl.Text.Trim()
    if (-not $linuxUrl) {
      [System.Windows.Forms.MessageBox]::Show("请填写 Windows 访问地址。", "提示")
      return
    }
    $servers = Get-ServersFromGrid
    if (-not $servers -or $servers.Count -eq 0) {
      [System.Windows.Forms.MessageBox]::Show("请至少填写一台远程服务器（Host）。", "提示")
      return
    }
  }

  if ($updates.Count -gt 0) { Update-EnvFile -path $envPath -updates $updates }

  Set-Autostart -name "NotifyTray" -value ("wscript.exe `"$targetDir\notify-tray.vbs`"") -enable $cbAutoTray.Checked
  Set-Autostart -name "NotifyTelegramBridge" -value ("wscript.exe `"$targetDir\telegram-bridge.vbs`"") -enable $cbTg.Checked
  Set-Autostart -name "NotifyServer" -value ("wscript.exe `"$targetDir\notify-server.vbs`"") -enable $cbAutoServer.Checked

  if ($cbRemote.Checked) {
    Apply-RemoteConfig -port $remotePort -prefix $remotePrefix | Out-Null
  }

  if ($cbLinux.Checked) {
    try {
      Configure-RemoteLinux -targetDir $targetDir `
        -url $tbWinUrl.Text.Trim() -token $notifyToken -servers $servers
    } catch {
      [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "远程配置失败")
      return
    }
  }

  [System.Windows.Forms.MessageBox]::Show("安装完成。你可以从托盘菜单打开配置。", "完成")
  $form.Close()
})

$btnCancel.Add_Click({ $form.Close() })

Update-RemoteSettings
if (-not $tbWinUrl.Text) { Refresh-WinUrl }
Set-ServersPanel -expanded:$false

[void]$form.ShowDialog()

