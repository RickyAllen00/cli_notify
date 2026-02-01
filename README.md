# Windows CLI Notify Bridge

把 Codex / Claude 的回复推送到 Windows 通知、企业微信或 Telegram。
支持 Telegram 端继续对话（/codex、/claude）。

本仓库不包含任何敏感信息（Webhook、Token、Chat ID）。

---

## Features
- Windows Toast 通知（BurntToast）
- 企业微信机器人 / Telegram Bot 推送
- Telegram 端闭环控制 Codex / Claude
- 托盘菜单：一键开关通道 + 调试日志
- 可选：HTTP 通知服务端，支持多台 Linux Codex 推送到 Windows

---

## Quick Start（新 Windows 设备）

### 1) 下载代码
```powershell
git clone https://github.com/RickyAllen00/cli_notify.git
cd cli_notify
```

### 2) 复制脚本到用户目录
```powershell
$bin = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item .\bin\* $bin -Force
```

### 3) 创建配置文件（推荐）
创建 `C:\Users\<User>\bin\.env`：
```
# 通知通道（按需填写）
WECOM_WEBHOOK=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...

# 远程通知服务端（远程 Linux 推送必填）
NOTIFY_SERVER_TOKEN=强随机字符串
NOTIFY_SERVER_PREFIX=http://+:9412/
NOTIFY_SERVER_PORT=9412
```
脚本读取配置优先级：
1) `NOTIFY_CONFIG_PATH` 指定路径  
2) 脚本同目录下的 `.env` / `notify.yml` / `notify.yaml`

**生成随机 Token（可选）**
```powershell
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
[Convert]::ToBase64String($bytes)
```

### 4) 安装 BurntToast（仅 Windows 通知需要）
```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Install-Module BurntToast -Scope CurrentUser -Force
```

### 5) 运行（手动）
```powershell
# 托盘菜单
wscript.exe "$env:USERPROFILE\bin\notify-tray.vbs"

# Telegram Bridge（仅需要 Telegram 控制时）
wscript.exe "$env:USERPROFILE\bin\telegram-bridge.vbs"

# 远程通知服务端（仅需要远程推送时）
wscript.exe "$env:USERPROFILE\bin\notify-server.vbs"
```

### 6) 验证
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify.ps1" -Source "Test" -Title "Hello" -Body "It works"
```

---

## Autostart（可选）
```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyTray" -Value "wscript.exe `"$env:USERPROFILE\bin\notify-tray.vbs`"" -PropertyType String -Force

New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyTelegramBridge" -Value "wscript.exe `"$env:USERPROFILE\bin\telegram-bridge.vbs`"" -PropertyType String -Force

New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyServer" -Value "wscript.exe `"$env:USERPROFILE\bin\notify-server.vbs`"" -PropertyType String -Force
```

---

## One-Click Restart
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify-restart.ps1"
```
说明：
- 默认重启托盘与 Telegram Bridge
- 如果存在 `CodexWatch` 计划任务会一并重启
- 如果已配置通知服务端会一并重启

---

## Remote Linux Codex → Windows
适用于：Linux 服务器上跑 Codex，但希望通知出现在 Windows。

### Windows 端准备
1) 确保 `NOTIFY_SERVER_TOKEN` 已配置  
2) 放行端口（管理员权限）
```powershell
netsh http add urlacl url=http://+:9412/ user=%USERNAME%
New-NetFirewallRule -DisplayName "Notify Server 9412" -Direction Inbound -Protocol TCP -LocalPort 9412 -Action Allow
```
3) 运行服务端
```powershell
wscript.exe "$env:USERPROFILE\bin\notify-server.vbs"
```
> 建议通过 VPN/内网穿透/反向代理访问，避免直接暴露公网端口。

### Linux 端一键安装
```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<你的Windows主机IP>:9412/notify" \
  --token "<与Windows端一致的Token>" \
  --host "<当前服务器标识>"
```
该命令会：
- 安装/更新 `~/bin/codex-notify.sh`
- 写入 `~/bin/.env`
- 自动配置 `~/.codex/config.toml` 的 `notify` 钩子

> 注意：`config.toml` 不会展开 `~`，脚本已写入绝对路径。

---

## 多台服务器快速配置
对每台服务器执行一次安装命令：
```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<你的Windows主机IP>:9412/notify" \
  --token "<你的Token>" \
  --host "<如 gpu-1 / prod-nyc / 192.168.1.23>"
```
需要密码的服务器：先 `ssh` 登录再执行命令。

**免密 SSH 批量配置（可选）**
```powershell
$servers = @(
  @{ user="zwb"; host="192.168.101.35"; label="lab-35" },
  @{ user="ubuntu"; host="1.2.3.4"; label="gpu-1" }
)

$cmd = 'curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- --url "http://<你的Windows主机IP>:9412/notify" --token "<你的Token>" --host "{0}"'

foreach ($s in $servers) {
  ssh "$($s.user)@$($s.host)" ($cmd -f $s.label)
}
```

---

## 迁移到新 Windows / 更换 IP
1) 新设备按 Quick Start 全部完成并启动 `notify-server.vbs`  
2) 所有 Linux 服务器重新执行一键安装命令，更新 `--url`  
3) 若更换 Token，确保新 Windows 与所有服务器一致

---

## 接入 Codex（Windows 本地）
在 `~\.codex\config.toml` 增加：
```
notify = ["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Users\\<User>\\bin\\notify.ps1","-Source","Codex"]
```

## 接入 Claude
在 `~\.claude\settings.json` 的 Stop Hook 里调用 `notify.ps1`。
确保最终执行的是：
```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<User>\bin\notify.ps1 -Source Claude
```

---

## Telegram 命令
```
/help
/codex <问题>
/codex <会话ID> <问题>
/codex last <问题>
/claude <问题>
/claude <会话ID> <问题>
/claude last <问题>
```

---

## 电源设置（后台运行必读）
如果需要 Codex / Claude 在后台持续运行，请避免系统睡眠：
- **允许关闭屏幕**（不影响后台）
- **避免睡眠/休眠**（会挂起进程）

推荐设置路径：
1) 设置 > 系统 > 电源（或“电源和睡眠”）  
   - 插电：睡眠 = 从不  
2) 控制面板 > 电源选项 > “关闭盖子时的功能”  
   - 插电：不执行任何操作  

> 笔记本合盖会导致睡眠时，后台任务会暂停。请根据你的使用场景调整。

---

## 开关与调试
- 全局关闭：`bin\notify.disabled`
- 单通道关闭：
  - `bin\notify.windows.disabled`
  - `bin\notify.wecom.disabled`
  - `bin\notify.telegram.disabled`
- 开启调试日志：创建 `bin\notify.debug.enabled`
- 命令行开关：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify-toggle.ps1" -Action on|off|status
```

---

## 日志位置
```
%LOCALAPPDATA%\notify\notify-YYYYMMDD.log
%LOCALAPPDATA%\notify\telegram-bridge.log
%LOCALAPPDATA%\notify\codex-bridge.log
%LOCALAPPDATA%\notify\claude-bridge.log
%LOCALAPPDATA%\notify\notify-server.log
```

---

## Troubleshooting
- 没有 Windows 通知：确认 BurntToast 已安装、系统通知未关闭  
- Telegram 无响应：确认 Bot Token / Chat ID 正确  
- 端口无法访问：检查 URL ACL 与防火墙规则  

---

## Security
- 仓库内不存放 Webhook / Token  
- 请使用环境变量或 `.env` 管理敏感信息  
- 请勿上传日志目录  

---

## License
MIT
