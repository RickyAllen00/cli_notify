#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$ApplyRemoteConfig,
  [int]$Port,
  [string]$Prefix,
  [string]$RuleName
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Normalize-ProxyUrl {
  param([string]$proxy)
  if ([string]::IsNullOrWhiteSpace($proxy)) { return "" }
  $p = $proxy.Trim()
  if ($p -notmatch '://') {
    if ($p -match '^[^:]+:\d+$') { return ("http://" + $p) }
  }
  return $p
}

function Get-ConfigPath {
  if ($env:NOTIFY_CONFIG_PATH) { return $env:NOTIFY_CONFIG_PATH }
  return (Join-Path $PSScriptRoot ".env")
}

function Get-Value {
  param([string]$name, [hashtable]$cfg)
  $v = [Environment]::GetEnvironmentVariable($name, "Process")
  if ($v) { return $v }
  if ($cfg -and $cfg.ContainsKey($name)) { return $cfg[$name] }
  try { return [Environment]::GetEnvironmentVariable($name, "User") } catch { return "" }
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

function Get-AutostartEnabled {
  param([string]$name)
  $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  $v = Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
  return ($null -ne $v)
}

function New-RandomToken {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return [Convert]::ToBase64String($bytes)
}

$configPath = Get-ConfigPath
$cfg = Read-EnvFile -path $configPath

$form = New-Object System.Windows.Forms.Form
$form.Text = "Notify 配置"
$form.Size = New-Object System.Drawing.Size(640, 740)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$gbChannel = New-Object System.Windows.Forms.GroupBox
$gbChannel.Text = "通知通道"
$gbChannel.SetBounds(12, 12, 600, 220)

$lblWecom = New-Object System.Windows.Forms.Label
$lblWecom.Text = "企微 Webhook"
$lblWecom.AutoSize = $true
$lblWecom.Location = New-Object System.Drawing.Point(16, 32)

$tbWecom = New-Object System.Windows.Forms.TextBox
$tbWecom.SetBounds(140, 28, 430, 24)
$tbWecom.Text = (Get-Value -name "WECOM_WEBHOOK" -cfg $cfg)

$lblTgToken = New-Object System.Windows.Forms.Label
$lblTgToken.Text = "Telegram Bot Token"
$lblTgToken.AutoSize = $true
$lblTgToken.Location = New-Object System.Drawing.Point(16, 70)

$tbTgToken = New-Object System.Windows.Forms.TextBox
$tbTgToken.SetBounds(140, 66, 430, 24)
$tbTgToken.Text = (Get-Value -name "TELEGRAM_BOT_TOKEN" -cfg $cfg)

$lblTgChat = New-Object System.Windows.Forms.Label
$lblTgChat.Text = "Telegram Chat ID"
$lblTgChat.AutoSize = $true
$lblTgChat.Location = New-Object System.Drawing.Point(16, 108)

$tbTgChat = New-Object System.Windows.Forms.TextBox
$tbTgChat.SetBounds(140, 104, 430, 24)
$tbTgChat.Text = (Get-Value -name "TELEGRAM_CHAT_ID" -cfg $cfg)

$lblTgProxy = New-Object System.Windows.Forms.Label
$lblTgProxy.Text = "Proxy(可选)"
$lblTgProxy.AutoSize = $true
$lblTgProxy.Location = New-Object System.Drawing.Point(16, 146)

$tbTgProxy = New-Object System.Windows.Forms.TextBox
$tbTgProxy.SetBounds(140, 142, 430, 24)
$tbTgProxy.Text = (Get-Value -name "TELEGRAM_PROXY" -cfg $cfg)

$lnkTgHelp = New-Object System.Windows.Forms.LinkLabel
$lnkTgHelp.Text = "如何获取 Bot Token / Chat ID"
$lnkTgHelp.AutoSize = $true
$lnkTgHelp.Location = New-Object System.Drawing.Point(140, 176)

$gbChannel.Controls.AddRange(@(
  $lblWecom,$tbWecom,
  $lblTgToken,$tbTgToken,
  $lblTgChat,$tbTgChat,
  $lblTgProxy,$tbTgProxy,
  $lnkTgHelp
))

$gbRemote = New-Object System.Windows.Forms.GroupBox
$gbRemote.Text = "远程通知服务端"
$gbRemote.SetBounds(12, 245, 600, 210)

$cbRemote = New-Object System.Windows.Forms.CheckBox
$cbRemote.Text = "启用远程通知服务端"
$cbRemote.AutoSize = $true
$cbRemote.Location = New-Object System.Drawing.Point(16, 28)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "端口"
$lblPort.AutoSize = $true
$lblPort.Location = New-Object System.Drawing.Point(16, 60)

$nudPort = New-Object System.Windows.Forms.NumericUpDown
$nudPort.SetBounds(140, 56, 100, 24)
$nudPort.Minimum = 1
$nudPort.Maximum = 65535
$portVal = (Get-Value -name "NOTIFY_SERVER_PORT" -cfg $cfg)
if (-not $portVal) { $portVal = 9412 }
$nudPort.Value = [decimal]$portVal

$lblPrefix = New-Object System.Windows.Forms.Label
$lblPrefix.Text = "Prefix"
$lblPrefix.AutoSize = $true
$lblPrefix.Location = New-Object System.Drawing.Point(16, 95)

$tbPrefix = New-Object System.Windows.Forms.TextBox
$tbPrefix.SetBounds(140, 92, 430, 24)
$tbPrefix.ReadOnly = $true

$lblToken = New-Object System.Windows.Forms.Label
$lblToken.Text = "Token"
$lblToken.AutoSize = $true
$lblToken.Location = New-Object System.Drawing.Point(16, 130)

$tbToken = New-Object System.Windows.Forms.TextBox
$tbToken.SetBounds(140, 126, 320, 24)
$tbToken.Text = (Get-Value -name "NOTIFY_SERVER_TOKEN" -cfg $cfg)

$btnGenToken = New-Object System.Windows.Forms.Button
$btnGenToken.Text = "生成随机 Token"
$btnGenToken.SetBounds(470, 124, 100, 28)

$btnApplyRemote = New-Object System.Windows.Forms.Button
$btnApplyRemote.Text = "应用防火墙/URLACL(管理员)"
$btnApplyRemote.SetBounds(140, 162, 230, 28)

$lblRemoteTip = New-Object System.Windows.Forms.Label
$lblRemoteTip.Text = "用于远程 Linux 推送"
$lblRemoteTip.AutoSize = $true
$lblRemoteTip.Location = New-Object System.Drawing.Point(380, 168)

$gbRemote.Controls.AddRange(@(
  $cbRemote,$lblPort,$nudPort,$lblPrefix,$tbPrefix,$lblToken,$tbToken,$btnGenToken,$btnApplyRemote,$lblRemoteTip
))

$gbAuto = New-Object System.Windows.Forms.GroupBox
$gbAuto.Text = "开机自启"
$gbAuto.SetBounds(12, 465, 600, 120)

$cbAutoTray = New-Object System.Windows.Forms.CheckBox
$cbAutoTray.Text = "托盘菜单"
$cbAutoTray.AutoSize = $true
$cbAutoTray.Location = New-Object System.Drawing.Point(16, 30)
$cbAutoTray.Checked = (Get-AutostartEnabled -name "NotifyTray")

$cbAutoTg = New-Object System.Windows.Forms.CheckBox
$cbAutoTg.Text = "Telegram Bridge"
$cbAutoTg.AutoSize = $true
$cbAutoTg.Location = New-Object System.Drawing.Point(200, 30)
$cbAutoTg.Checked = (Get-AutostartEnabled -name "NotifyTelegramBridge")

$cbAutoServer = New-Object System.Windows.Forms.CheckBox
$cbAutoServer.Text = "远程通知服务端"
$cbAutoServer.AutoSize = $true
$cbAutoServer.Location = New-Object System.Drawing.Point(400, 30)
$cbAutoServer.Checked = (Get-AutostartEnabled -name "NotifyServer")

$gbAuto.Controls.AddRange(@($cbAutoTray,$cbAutoTg,$cbAutoServer))

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "保存"
$btnSave.SetBounds(430, 605, 80, 30)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "取消"
$btnCancel.SetBounds(520, 605, 80, 30)

$form.Controls.AddRange(@($gbChannel,$gbRemote,$gbAuto,$btnSave,$btnCancel))

function Update-Prefix {
  $port = [int]$nudPort.Value
  $tbPrefix.Text = "http://+:$port/"
}

$nudPort.Add_ValueChanged({ Update-Prefix })
$cbRemote.Add_CheckedChanged({
  $enabled = $cbRemote.Checked
  $nudPort.Enabled = $enabled
  $tbToken.Enabled = $enabled
  $btnGenToken.Enabled = $enabled
  $btnApplyRemote.Enabled = $enabled
})

$btnGenToken.Add_Click({
  $tbToken.Text = New-RandomToken
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

$btnApplyRemote.Add_Click({
  if (-not $cbRemote.Checked) {
    [System.Windows.Forms.MessageBox]::Show("请先勾选启用远程通知服务端。", "提示")
    return
  }
  $port = [int]$nudPort.Value
  if (-not (Test-PortAvailable -port $port)) {
    [System.Windows.Forms.MessageBox]::Show("端口 $port 已被占用，请更换端口。", "端口冲突")
    return
  }
  Apply-RemoteConfig -port $port -prefix $tbPrefix.Text | Out-Null
  [System.Windows.Forms.MessageBox]::Show("已应用防火墙/URLACL。", "完成")
})

$btnSave.Add_Click({
  $updates = @{}
  $updates["WECOM_WEBHOOK"] = $tbWecom.Text.Trim()
  $updates["TELEGRAM_BOT_TOKEN"] = $tbTgToken.Text.Trim()
  $updates["TELEGRAM_CHAT_ID"] = $tbTgChat.Text.Trim()
  $updates["TELEGRAM_PROXY"] = (Normalize-ProxyUrl $tbTgProxy.Text)

  if ($cbRemote.Checked) {
    $port = [int]$nudPort.Value
    if (-not (Test-PortAvailable -port $port)) {
      [System.Windows.Forms.MessageBox]::Show("端口 $port 已被占用，请更换端口。", "端口冲突")
      return
    }
    $token = $tbToken.Text.Trim()
    if (-not $token) { $token = New-RandomToken; $tbToken.Text = $token }
    $updates["NOTIFY_SERVER_TOKEN"] = $token
    $updates["NOTIFY_SERVER_PREFIX"] = $tbPrefix.Text
    $updates["NOTIFY_SERVER_PORT"] = "$port"
  }

  Update-EnvFile -path $configPath -updates $updates

  $bin = $PSScriptRoot
  Set-Autostart -name "NotifyTray" -value ("wscript.exe `"$bin\notify-tray.vbs`"") -enable $cbAutoTray.Checked
  Set-Autostart -name "NotifyTelegramBridge" -value ("wscript.exe `"$bin\telegram-bridge.vbs`"") -enable $cbAutoTg.Checked
  Set-Autostart -name "NotifyServer" -value ("wscript.exe `"$bin\notify-server.vbs`"") -enable $cbAutoServer.Checked

  [System.Windows.Forms.MessageBox]::Show("配置已保存。", "完成")
  $form.Close()
})

$btnCancel.Add_Click({ $form.Close() })

Update-Prefix
$cbRemote.Checked = ([string]::IsNullOrWhiteSpace((Get-Value -name "NOTIFY_SERVER_TOKEN" -cfg $cfg)) -eq $false)
$cbRemote.Checked = $cbRemote.Checked -or ([string]::IsNullOrWhiteSpace((Get-Value -name "NOTIFY_SERVER_PREFIX" -cfg $cfg)) -eq $false)
$cbRemote.Checked = $cbRemote.Checked -or ([string]::IsNullOrWhiteSpace((Get-Value -name "NOTIFY_SERVER_PORT" -cfg $cfg)) -eq $false)
$nudPort.Enabled = $cbRemote.Checked
$tbToken.Enabled = $cbRemote.Checked
$btnGenToken.Enabled = $cbRemote.Checked
$btnApplyRemote.Enabled = $cbRemote.Checked

[void]$form.ShowDialog()

