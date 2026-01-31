# Windows Codex/Claude Notify Bridge

可在 Windows 本地将 Codex / Claude 的回复推送到：
- Windows 通知
- 企业微信机器人
- Telegram Bot
并支持 Telegram 端闭环控制 `/codex` 与 `/claude`。

> 本仓库不包含任何敏感信息（Webhook、Token、Chat ID）。

---

## 目录结构
```
.
├─ bin
│  ├─ notify.ps1              # 通知入口（Windows/企微/Telegram）
│  ├─ notify-tray.ps1         # 托盘 GUI
│  ├─ notify-tray.vbs         # 托盘无窗口启动
│  ├─ telegram-bridge.ps1     # Telegram 控制桥
│  ├─ telegram-bridge.vbs     # Telegram 控制桥无窗口启动
│  ├─ codex-bridge-run.ps1    # Telegram -> Codex 执行桥
│  ├─ claude-bridge-run.ps1   # Telegram -> Claude 执行桥
│  └─ notify-toggle.ps1       # 通知开关脚本
├─ .env.example
└─ README.md
```

---

## 安装步骤（每台机器）

### 1) 安装 BurntToast（Windows 通知）
```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
Install-Module BurntToast -Scope CurrentUser -Force
```

### 2) 复制脚本
把整个仓库复制到：
```
%USERPROFILE%\bin
```

### 3) 配置环境变量（建议使用 User 级别）
```powershell
setx WECOM_WEBHOOK "你的企微Webhook"
setx TELEGRAM_BOT_TOKEN "你的Telegram Bot Token"
setx TELEGRAM_CHAT_ID "你的Chat ID"
```

### 4) 设置开机启动（托盘 + Telegram 桥）
```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" \
  -Name "NotifyTray" -Value "wscript.exe `"%USERPROFILE%\bin\notify-tray.vbs`"" -PropertyType String -Force

New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" \
  -Name "NotifyTelegramBridge" -Value "wscript.exe `"%USERPROFILE%\bin\telegram-bridge.vbs`"" -PropertyType String -Force
```

### 5) 配置 Codex / Claude

**Codex：** 在 `~\.codex\config.toml` 增加：
```
notify = ["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Users\\<User>\\bin\\notify.ps1","-Source","Codex"]
```

**Claude Code：** 在 `~\.claude\settings.json` 的 Stop Hook 指向 `notify.ps1`。

---

## Telegram 端命令
```
/help
/codex <问题>
/codex <会话ID> <问题>
/claude <问题>
/claude <会话ID> <问题>
```

说明：
- `/codex <问题>` 会继续最近的 Codex 会话
- `/codex <会话ID> <问题>` 会继续指定会话
- Telegram 只发送本次提示词；历史上下文来自 Codex 会话本身

---

## 日志位置
```
%LOCALAPPDATA%\notify\notify-YYYYMMDD.log
%LOCALAPPDATA%\notify\telegram-bridge.log
%LOCALAPPDATA%\notify\codex-bridge.log
```

---

## 安全说明
- 仓库内不存放 Webhook / Token
- 请自行设置环境变量
- 请勿上传日志目录

---

## License
MIT
