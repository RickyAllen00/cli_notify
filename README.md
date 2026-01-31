# Windows CLI Notify Bridge (Codex / Claude / WeCom / Telegram)

把 Codex / Claude 的回复推送到 Windows 通知、企业微信、Telegram，
并支持 Telegram 端继续对话（/codex、/claude）。

> 本仓库不包含任何敏感信息（Webhook、Token、Chat ID）。

---

## 功能亮点
- Windows Toast 通知（BurntToast）
- 企业微信机器人 / Telegram Bot 推送
- Telegram 端闭环控制 Codex / Claude
- 托盘菜单一键开关各通道 + 调试日志

---

## 快速开始（5 分钟）

### 0) 前置条件
- Windows 10/11
- PowerShell 5.1+
- （可选）Windows 通知模块 BurntToast
- （可选）已安装 Codex / Claude CLI

### 1) 获取代码
```powershell
git clone https://github.com/RickyAllen00/cli_notify.git
cd cli_notify
```

### 2) 放置脚本（推荐做法）
把 `bin` 目录下的脚本放到用户的 `bin` 目录，便于后续配置：
```powershell
$bin = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item .\bin\* $bin -Force
```
> 也可以放到任意目录，但后续所有路径要对应修改。

### 3) 安装 BurntToast（仅 Windows 通知需要）
```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Install-Module BurntToast -Scope CurrentUser -Force
```

### 4) 配置环境变量（只用到哪个就配哪个）
```powershell
setx WECOM_WEBHOOK "你的企微Webhook"
setx TELEGRAM_BOT_TOKEN "你的Telegram Bot Token"
setx TELEGRAM_CHAT_ID "你的Chat ID"
```

### 5) 立即测试
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify.ps1" -Source "Test" -Title "Hello" -Body "It works"
```

### 6) 开机自启（可选）
托盘菜单 + Telegram 控制桥：
```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" \
  -Name "NotifyTray" -Value "wscript.exe `"$env:USERPROFILE\bin\notify-tray.vbs`"" -PropertyType String -Force

New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" \
  -Name "NotifyTelegramBridge" -Value "wscript.exe `"$env:USERPROFILE\bin\telegram-bridge.vbs`"" -PropertyType String -Force
```

---

## 接入 Codex
在 `~\.codex\config.toml` 增加（路径按实际调整）：
```
notify = ["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Users\\<User>\\bin\\notify.ps1","-Source","Codex"]
```

## 接入 Claude
在 `~\.claude\settings.json` 的 Stop Hook 里调用 `notify.ps1`。不同版本字段可能略有差异，
确保最终执行的是：
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
