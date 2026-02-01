# Windows CLI Notify Bridge (Codex / Claude / WeCom / Telegram)

将 Codex / Claude 的回复推送到 Windows 通知、企业微信或 Telegram，
并支持在 Telegram 端继续对话（/codex、/claude）。

> 本仓库不包含任何敏感信息（Webhook、Token、Chat ID）。

---

## 功能
- Windows Toast 通知（BurntToast）
- 企业微信机器人 / Telegram Bot 推送
- Telegram 端闭环控制 Codex / Claude
- 托盘菜单：一键开关通道 + 调试日志

---

## 环境要求
- Windows 10/11
- PowerShell 5.1+
- （可选）Windows 通知模块 BurntToast
- （可选）已安装 Codex / Claude CLI

---

## 安装与配置

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

### 3) 安装 BurntToast（仅 Windows 通知需要）
```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Install-Module BurntToast -Scope CurrentUser -Force
```

### 4) 配置环境变量（按需）
```powershell
setx WECOM_WEBHOOK "你的企微Webhook"
setx TELEGRAM_BOT_TOKEN "你的Telegram Bot Token"
setx TELEGRAM_CHAT_ID "你的Chat ID"
```
也可以使用 `.env` 或 `notify.yml` 配置（脚本会自动读取），例如：
```
WECOM_WEBHOOK=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```
放置位置优先级：
1) `NOTIFY_CONFIG_PATH` 指定的路径  
2) 脚本同目录下的 `.env` / `notify.yml` / `notify.yaml`
> 当脚本位于 `~/bin` 但配置文件在项目目录时，可用 `NOTIFY_CONFIG_PATH` 指向该文件。

---

## 快速验证
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

## 远程 Codex 完成后也推送到 Windows / Telegram
适用于：你在 Linux 云服务器上运行 Codex，但希望通知出现在 Windows（Toast + Telegram/企微）。

### Windows 端：启动通知服务端
1) 设置服务端 Token（必填）
```powershell
setx NOTIFY_SERVER_TOKEN "强随机字符串"
```

2)（可选）指定监听地址/端口  
默认只监听本机 `127.0.0.1:9412`。如果需要远程访问，请设置为 `http://+:9412/`：
```powershell
setx NOTIFY_SERVER_PREFIX "http://+:9412/"
setx NOTIFY_SERVER_PORT "9412"
```

3) 运行服务端（隐藏窗口）
```powershell
wscript.exe "$env:USERPROFILE\bin\notify-server.vbs"
```

> 远程访问通常需要额外的 URL ACL 与防火墙放行（管理员权限）：
> ```powershell
> netsh http add urlacl url=http://+:9412/ user=%USERNAME%
> New-NetFirewallRule -DisplayName "Notify Server 9412" -Direction Inbound -Protocol TCP -LocalPort 9412 -Action Allow
> ```
> 建议通过 VPN/内网穿透/反向代理等方式访问，避免直接暴露公网端口。

### Linux 端：配置 Codex 通知钩子
1) 复制脚本到服务器
```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/main/remote/codex-notify.sh -o ~/bin/codex-notify.sh
chmod +x ~/bin/codex-notify.sh
```

2) 配置环境变量（或写入 `.env` / `notify.yml`）
```bash
export WINDOWS_NOTIFY_URL="http://<你的Windows主机IP>:9412/notify"
export WINDOWS_NOTIFY_TOKEN="与Windows端一致的Token"
# 可选：指定通知中显示的主机名/IP
export CODEX_NOTIFY_HOST="192.168.101.35"
```
如果你使用配置文件，可通过 `NOTIFY_CONFIG_PATH` 指定路径。

3) 在 `~/.codex/config.toml` 增加：
```toml
notify = ["/bin/bash","-lc","~/bin/codex-notify.sh"]
```

完成后，Linux 上的 Codex 每轮结束都会推送到 Windows，并复用你现有的 Telegram/企微配置。

---

## 多台服务器快速配置
已安装 Codex 的服务器可以执行以下一条命令完成安装与配置：
```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/main/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<你的Windows主机IP>:9412/notify" \
  --token "<你的Token>" \
  --host "<当前服务器标识>"
```
该命令会：
- 安装/更新 `~/bin/codex-notify.sh`
- 写入 `~/bin/.env`
- 自动配置 `~/.codex/config.toml` 的 `notify` 钩子

如果你不想写入钩子，可加 `--skip-hook`。

---

## 接入 Codex
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
