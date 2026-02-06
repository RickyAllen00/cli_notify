#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Win32 -Name ConsoleWindow -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@

# Hide/detach any console window to prevent taskbar flashes
try {
  $hwnd = [Win32.ConsoleWindow]::GetConsoleWindow()
  if ($hwnd -ne [IntPtr]::Zero) {
    [Win32.ConsoleWindow]::ShowWindow($hwnd, 0) | Out-Null
    [Win32.ConsoleWindow]::FreeConsole() | Out-Null
  }
} catch {}

$bin = Split-Path -Parent $MyInvocation.MyCommand.Path
$flagAll = Join-Path $bin "notify.disabled"
$flagWin = Join-Path $bin "notify.windows.disabled"
$flagWecom = Join-Path $bin "notify.wecom.disabled"
$flagTg = Join-Path $bin "notify.telegram.disabled"
$flagDebug = Join-Path $bin "notify.debug.enabled"
$notifyScript = Join-Path $bin "notify.ps1"
$configScript = Join-Path $bin "notify-config.ps1"

$logDir = Join-Path $env:LOCALAPPDATA "notify"
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
$logFile = Join-Path $logDir "tray.log"
function Write-TrayLog {
  param([string]$msg)
  try { Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " " + $msg) } catch {}
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
  try {
    $reg = Get-ItemProperty -Path "HKCU:\Environment" -Name "NOTIFY_CONFIG_PATH" -ErrorAction SilentlyContinue
    if ($reg -and $reg.NOTIFY_CONFIG_PATH) { return $reg.NOTIFY_CONFIG_PATH }
  } catch {}
  return (Join-Path $bin ".env")
}

function Show-TgProxyDialog {
  param([System.Windows.Forms.NotifyIcon]$NotifyIcon)

  $cfgPath = Get-ConfigPath
  $cfg = Read-EnvFile -path $cfgPath
  $current = ""
  if ($cfg -and $cfg.ContainsKey("TELEGRAM_PROXY")) { $current = [string]$cfg["TELEGRAM_PROXY"] }

  $f = New-Object System.Windows.Forms.Form
  $f.Text = "Telegram 代理"
  $f.Size = New-Object System.Drawing.Size(520, 190)
  $f.StartPosition = "CenterScreen"
  $f.FormBorderStyle = "FixedDialog"
  $f.MaximizeBox = $false

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = "Proxy URL（留空=直连）"
  $lbl.AutoSize = $true
  $lbl.Location = New-Object System.Drawing.Point(16, 20)

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.SetBounds(16, 45, 470, 24)
  $tb.Text = $current

  $tip = New-Object System.Windows.Forms.Label
  $tip.Text = "示例：http://127.0.0.1:7890"
  $tip.AutoSize = $true
  $tip.Location = New-Object System.Drawing.Point(16, 75)

  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Text = "保存"
  $btnOk.SetBounds(320, 115, 80, 28)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = "取消"
  $btnCancel.SetBounds(406, 115, 80, 28)

  $btnOk.Add_Click({
    try {
      Update-EnvFile -path $cfgPath -updates @{ TELEGRAM_PROXY = (Normalize-ProxyUrl $tb.Text) }
      try { if ($NotifyIcon) { $NotifyIcon.ShowBalloonTip(3000, "已保存", "Telegram 代理已更新", [System.Windows.Forms.ToolTipIcon]::Info) } } catch {}
      Write-TrayLog "proxy updated"
    } catch {
      try { [System.Windows.Forms.MessageBox]::Show("保存失败：" + $_.Exception.Message, "错误") } catch {}
      Write-TrayLog ("proxy save fail: " + $_.Exception.Message)
      return
    }
    $f.Close()
  })
  $btnCancel.Add_Click({ $f.Close() })

  $f.Controls.AddRange(@($lbl,$tb,$tip,$btnOk,$btnCancel))
  [void]$f.ShowDialog()
}

# Single-instance guard (per-user)
$mutex = $null
$mutexCreated = $false
try {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutexName = "Local\\NotifyTray-" + $sid
  $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
} catch {
  # If mutex can't be created, proceed without single-instance protection
  $mutexCreated = $true
}
if (-not $mutexCreated) {
  Write-TrayLog "tray already running"
  return
}

function Get-NotifyStatus {
  if (Test-Path $flagAll) { return "OFF" }
  return "ON"
}

function Get-FlagState($path) { return -not (Test-Path $path) }

function New-NotifyIcon {
  # Notification-style icon: blue gradient + white bell + amber dot
  $size = 64
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  $rect = New-Object System.Drawing.Rectangle 0,0,($size-1),($size-1)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
    [System.Drawing.Color]::FromArgb(35,110,255),
    [System.Drawing.Color]::FromArgb(0,205,210),
    45)
  $g.FillEllipse($brush, $rect)
  $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(190,255,255,255)), 2), 2,2,($size-5),($size-5))

  # Bell shadow
  $shadow = New-Object System.Drawing.Drawing2D.GraphicsPath
  $shadow.AddArc(18,14,32,28,180,180)
  $shadow.AddLine(50,28,50,40)
  $shadow.AddArc(30,36,24,20,0,180)
  $shadow.AddLine(30,46,30,28)
  $shadow.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60,0,0,0))), $shadow)

  # Bell body
  $bell = New-Object System.Drawing.Drawing2D.GraphicsPath
  $bell.AddArc(16,12,32,28,180,180)
  $bell.AddLine(48,26,48,40)
  $bell.AddArc(28,34,24,20,0,180)
  $bell.AddLine(28,44,28,26)
  $bell.CloseFigure()
  $g.FillPath([System.Drawing.Brushes]::White, $bell)
  $g.FillEllipse([System.Drawing.Brushes]::Gainsboro, 30,46,6,6)

  # Notification dot
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,255,178,0))), 41,7,16,16)
  $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::White, 2)), 41,7,16,16)

  $iconHandle = $bmp.GetHicon()
  return [System.Drawing.Icon]::FromHandle($iconHandle)
}

try {
  $icon = New-Object System.Windows.Forms.NotifyIcon
  $icon.Icon = New-NotifyIcon
  $icon.Visible = $true
  $icon.Text = "Notify: " + (Get-NotifyStatus)

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $menu.ShowImageMargin = $true
  $menu.ShowCheckMargin = $true

  $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $toggleAllItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $winItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $wecomItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $tgItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $debugItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $testItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $configItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $proxyItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem

  $statusItem.Enabled = $false
  $winItem.CheckOnClick = $true
  $wecomItem.CheckOnClick = $true
  $tgItem.CheckOnClick = $true
  $debugItem.CheckOnClick = $true

  $statusItem.Text = "状态"
  $toggleAllItem.Text = "总开关"
  $winItem.Text = "推送到 Windows"
  $wecomItem.Text = "推送到手机(企微)"
  $tgItem.Text = "推送到 Telegram"
  $debugItem.Text = "调试日志"
  $testItem.Text = "发送测试"
  $configItem.Text = "打开配置"
  $proxyItem.Text = "Telegram 代理"
  $exitItem.Text = "退出"

  function Refresh-UI {
    $status = Get-NotifyStatus
    $icon.Text = ("Notify: " + $status)
    if ($status -eq "ON") {
      $statusItem.Text = "状态: 已开启"
      $toggleAllItem.Text = "关闭全部通知"
    } else {
      $statusItem.Text = "状态: 已关闭"
      $toggleAllItem.Text = "开启全部通知"
    }

    $winItem.Checked = Get-FlagState $flagWin
    $wecomItem.Checked = Get-FlagState $flagWecom
    $tgItem.Checked = Get-FlagState $flagTg
    $debugItem.Checked = Test-Path $flagDebug
  }

  $toggleAllItem.Add_Click({
    if (Test-Path $flagAll) { Remove-Item $flagAll -Force } else { New-Item -ItemType File -Path $flagAll -Force | Out-Null }
    Refresh-UI
  })

  $winItem.Add_Click({
    if ($winItem.Checked) {
      if (Test-Path $flagWin) { Remove-Item $flagWin -Force }
    } else {
      New-Item -ItemType File -Path $flagWin -Force | Out-Null
    }
    Refresh-UI
  })

  $wecomItem.Add_Click({
    if ($wecomItem.Checked) {
      if (Test-Path $flagWecom) { Remove-Item $flagWecom -Force }
    } else {
      New-Item -ItemType File -Path $flagWecom -Force | Out-Null
    }
    Refresh-UI
  })

  $tgItem.Add_Click({
    if ($tgItem.Checked) {
      if (Test-Path $flagTg) { Remove-Item $flagTg -Force }
    } else {
      New-Item -ItemType File -Path $flagTg -Force | Out-Null
    }
    Refresh-UI
  })

  $debugItem.Add_Click({
    if ($debugItem.Checked) {
      if (-not (Test-Path $flagDebug)) { New-Item -ItemType File -Path $flagDebug -Force | Out-Null }
    } else {
      if (Test-Path $flagDebug) { Remove-Item $flagDebug -Force }
    }
    Refresh-UI
  })

  $testItem.Add_Click({
    $testPayload = @{
      "thread-id" = "tray-test"
      "cwd" = (Get-Location).Path
      "last-assistant-message" = "来自托盘开关"
    } | ConvertTo-Json -Depth 5
    & $notifyScript -Source "GUI" $testPayload
  })

  $configItem.Add_Click({
    if (Test-Path $configScript) {
      Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$configScript) -WindowStyle Hidden | Out-Null
    }
  })

  $proxyItem.Add_Click({
    Show-TgProxyDialog -NotifyIcon $icon
  })

  function Quit-Tray {
    try { $icon.Visible = $false } catch {}
    try { $menuTimer.Stop(); $menuTimer.Dispose() } catch {}
    try { $menu.Dispose() } catch {}
    try { $icon.Dispose() } catch {}
    try { $form.Close(); $form.Dispose() } catch {}
    try { [System.Windows.Forms.Application]::ExitThread() } catch {}
  }

  $exitItem.Add_Click({ Quit-Tray })

  $menu.Items.AddRange(@(
    $statusItem,
    $toggleAllItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $winItem,
    $wecomItem,
    $tgItem,
    $debugItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $testItem,
    $configItem,
    $proxyItem,
    $exitItem
  ))

  # Hidden form to own the menu; ensures it closes when losing focus
  $form = New-Object System.Windows.Forms.Form
  $form.ShowInTaskbar = $false
  $form.FormBorderStyle = 'None'
  $form.WindowState = 'Minimized'
  $form.Opacity = 0
  $form.Size = New-Object System.Drawing.Size(1,1)
  $form.Show()
  $form.Hide()
  $null = $form.Handle

  $menuTimer = New-Object System.Windows.Forms.Timer
  $menuTimer.Interval = 200
  $menuTimer.Add_Tick({
    if ($menu.Visible) {
      $pos = [System.Windows.Forms.Cursor]::Position
      if (-not $menu.Bounds.Contains($pos)) {
        if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) { $menu.Close() }
      }
    }
  })

  $menu.Add_Opened({ $menuTimer.Start() })
  $menu.Add_Closed({ $menuTimer.Stop(); $form.Hide() })
  $form.Add_Deactivate({ if ($menu.Visible) { $menu.Close() }; $form.Hide() })

  function Show-Menu {
    try {
      $pos = [System.Windows.Forms.Cursor]::Position
      $form.Location = $pos
      $menu.Show($pos)
    } catch {}
  }

  # Open menu on right click or left double click
  $icon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-Menu }
  })
  $icon.Add_MouseDoubleClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Menu }
  })

  Refresh-UI
  Write-TrayLog "tray started"
  try { $icon.ShowBalloonTip(3000, "通知已启动", "双击图标打开菜单", [System.Windows.Forms.ToolTipIcon]::Info) } catch {}

  [System.Windows.Forms.Application]::Run($form)
} catch {
  Write-TrayLog ("tray error: " + $_.Exception.Message)
} finally {
  if ($mutex -and $mutexCreated) {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
  }
}
