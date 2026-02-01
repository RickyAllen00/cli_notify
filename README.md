# Windows CLI Notify Bridge (Codex / Claude / WeCom / Telegram)

将 Codex / Claude 的回复推送到 Windows 通知、企业微信或 Telegram，
并支持从 Telegram 端继续对话（/codex、/claude）。

本仓库不包含任何敏感信息（Webhook、Token、Chat ID）。

---

## 功能
- Windows Toast 通知（BurntToast）
- 企业微信机器人 / Telegram Bot 推送
- Telegram 端闭环控制 Codex / Claude
- 托盘菜单：一键开关通道 + 调试日志
- 可选：HTTP 通知服务端，支持多台 Linux Codex 推送到 Windows

---

## 新 Windows 设备从零部署（推荐流程）

### 0) 环境要求
- Windows 10/11
- PowerShell 5.1+
- （可选）Windows 通知模块 BurntToast
- （可选）已安装 Codex / Claude CLI

### 1) 获取代码
```powershell
git clone https://github.com/RickyAllen00/cli_notify.git
cd cli_notify
```

### 2) 放置脚本（推荐）
将 `bin` 目录下脚本复制到用户的 `bin` 目录，便于后续配置：
```powershell
$bin = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item .\bin\* $bin -Force
```
> 也可以放到任意目录，但后续所有路径需对应修改。

### 3) 配置（推荐放在 `~\bin\.env`）
创建 `C:\Users\<User>\bin\.env`，示例：
```
# 通知通道（按需填写）
WECOM_WEBHOOK=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...

# 远程通知服务端（需要远程 Linux Codex 推送时必填）
NOTIFY_SERVER_TOKEN=强随机字符串
NOTIFY_SERVER_PREFIX=http://+:9412/
NOTIFY_SERVER_PORT=9412
```
脚本读取配置优先级：
1) `NOTIFY_CONFIG_PATH` 指定的路径  
2) 脚本同目录下的 `.env` / `notify.yml` / `notify.yaml`

**生成随机 Token（可选）**
```powershell
# 生成 32 字节随机 Token（Base64）
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
[Convert]::ToBase64String($bytes)
```

### 4) 安装 BurntToast（仅 Windows 通知需要）
```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Install-Module BurntToast -Scope CurrentUser -Force
```

### 5) 启动托盘与桥接（手动运行）
```powershell
# 托盘菜单
wscript.exe "$env:USERPROFILE\bin\notify-tray.vbs"

# Telegram Bridge（仅需要 Telegram 控制时）
wscript.exe "$env:USERPROFILE\bin\telegram-bridge.vbs"

# 远程通知服务端（仅需要远程推送时）
wscript.exe "$env:USERPROFILE\bin\notify-server.vbs"
```

### 6) 快速验证
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify.ps1" -Source "Test" -Title "Hello" -Body "It works"
```

---

## 开机自启（可选）
托盘菜单 + Telegram 控制桥：
```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyTray" -Value "wscript.exe `"$env:USERPROFILE\bin\notify-tray.vbs`"" -PropertyType String -Force

New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyTelegramBridge" -Value "wscript.exe `"$env:USERPROFILE\bin\telegram-bridge.vbs`"" -PropertyType String -Force
```
如果需要远程通知服务端随开机启动：
```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "NotifyServer" -Value "wscript.exe `"$env:USERPROFILE\bin\notify-server.vbs`"" -PropertyType String -Force
```

---

## 一键重启（托盘 + Telegram Bridge + CodexWatch）
提供便捷的重启脚本：如果已运行会先停止，再重新启动；未运行则直接启动。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify-restart.ps1"
```
说明：
- 默认会重启托盘与 Telegram Bridge
- 如果系统中存在 `CodexWatch` 计划任务，会一并重启
- 如果已配置通知服务端（见下文），也会一并重启

---

## 远程 Linux Codex 推送到 Windows
适用于：你在 Linux 云服务器上运行 Codex，但希望通知出现在 Windows（Toast + Telegram/企微）。

### Windows 端：启动通知服务端
1) 确保 `NOTIFY_SERVER_TOKEN` 已配置（见上文 `.env`）。

2) 远程访问需要 URL ACL 与防火墙放行（管理员权限）：
```powershell
netsh http add urlacl url=http://+:9412/ user=%USERNAME%
New-NetFirewallRule -DisplayName "Notify Server 9412" -Direction Inbound -Protocol TCP -LocalPort 9412 -Action Allow
```

3) 运行服务端（隐藏窗口）：
```powershell
wscript.exe "$env:USERPROFILE\bin\notify-server.vbs"
```

> 建议通过 VPN/内网穿透/反向代理等方式访问，避免直接暴露公网端口。

### Linux 端：一键安装（推荐）
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
对每台服务器执行一次安装命令，建议 `--host` 使用可读标识：
```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<你的Windows主机IP>:9412/notify" \
  --token "<你的Token>" \
  --host "<如 gpu-1 / prod-nyc / 192.168.1.23>"
```
如果服务器需要密码，请先 `ssh` 登录再执行上述命令。

### 批量配置（免密 SSH）
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

## 迁移到新 Windows / 更换 Windows IP
如果你更换了通知主机（或 IP 变化）：
1) 在新 Windows 设备完成“从零部署”的全部步骤，并启动 `notify-server.vbs`。
2) 所有 Linux 服务器重新执行一键安装命令，更新 `--url`：
```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<新Windows主机IP>:9412/notify" \
  --token "<你的Token>" \
  --host "<当前服务器标识>"
```
3) 如果你更新了 Token，确保新 Windows 与所有服务器的 Token 保持一致。

---

## 接入 Codex（Windows 本地）
在 `~\.codex\config.toml` 增加（路径按实际调整）：
```
notify = ["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Users\\<User>\\bin\\notify.ps1","-Source","Codex"]
```

## 接入 Claude
在 `~\.claude\settings.json` 的 Stop Hook 里调用 `notify.ps1`。
不同版本字段可能略有差异，请确保最终执行的是：
```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<User>\bin\notify.ps1 -Source Claude
```

---

## Telegram 端命令
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

## 常见问题
- 没有 Windows 通知：确认 BurntToast 已安装、系统通知未被关闭。
- Telegram 无响应：确认 Bot Token / Chat ID 正确，且只接受指定 Chat ID。
- 想换路径：更新所有配置中的 `notify.ps1` 路径即可。

---

## 安全说明
- 仓库内不存放 Webhook / Token
- 请使用环境变量或其它安全方式配置
- 请勿上传日志目录

---

## License
MIT
