# Windows CLI Notify Bridge

把 Codex / Claude 的回复推送到 Windows 通知、企业微信或 Telegram，并支持在 Telegram 直接回复继续会话（仅允许回复该会话最新消息，支持图文）。

## 功能
- Windows Toast 通知（BurntToast）
- 企业微信机器人 / Telegram Bot 推送
- Telegram 端闭环控制 Codex / Claude（/codex、/claude）
- Telegram 直接回复继续会话（支持图文、支持话题/Thread）
- 托盘菜单：一键开关通道、调试日志
- 可选：HTTP 通知服务端，支持多台 Linux Codex 推送到 Windows

## 一键安装（推荐）
1) 在 GitHub Releases 下载最新 `NotifySetup.exe`
2) 双击运行安装向导
3) 按需勾选：Telegram/企业微信/远程通知服务端/开机自启
4) 安装完成即可使用

> 安装向导会自动处理端口冲突提示、防火墙与 URL ACL 配置（如选择远程通知服务端）。

## 3 分钟上手
### 1) 配置 Telegram（可选）
安装向导中选择“现在配置 Telegram”，填入：
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

### 2) 接入 Codex / Claude（本地）
**Codex**：在 `~\.codex\config.toml` 里添加
```
notify = ["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Users\\<User>\\bin\\notify.ps1","-Source","Codex"]
```

**Claude**：在 `~\.claude\settings.json` 的 Stop Hook 里调用
```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<User>\bin\notify.ps1 -Source Claude
```

### 3) 验证
```
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\notify.ps1" -Source "Test" -Title "Hello" -Body "It works"
```

## Telegram 继续对话说明
- 必须 **回复机器人推送的最新消息**（否则会提示“不支持回复”）
- 支持话题/Thread：会自动记住并在同一 Thread 内回复
- 支持图文：图片会保存到项目 `.notify` 下并自动注入提示词
- 远程会话图文：需要 `scp`（OpenSSH Client）或 PuTTY `pscp.exe`

## 远程 Linux → Windows 推送（可选）
当 Linux 服务器跑 Codex，希望通知回到 Windows：
```
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<Windows_IP>:9412/notify" \
  --token "<与 Windows 一致的 Token>" \
  --host "<服务器标识/IP>" \
  --name "<备注名>"
```

Windows 侧在安装向导中勾选“远程通知服务端”即可。

## 常用命令（Telegram）
```
/help
/codex <问题>
/codex <会话ID> <问题>
/codex last <问题>
/claude <问题>
/claude <会话ID> <问题>
/claude last <问题>
```

## 日志位置
```
%LOCALAPPDATA%\notify\notify-YYYYMMDD.log
%LOCALAPPDATA%\notify\telegram-bridge.log
%LOCALAPPDATA%\notify\codex-bridge.log
%LOCALAPPDATA%\notify\claude-bridge.log
%LOCALAPPDATA%\notify\notify-server.log
```

## Troubleshooting
- Windows 通知无效：确认 BurntToast 安装、系统通知未关闭
- Telegram 无响应：确认 Bot Token / Chat ID 正确
- 远程图片失败：请安装 OpenSSH Client 或 PuTTY（pscp）并加入 PATH

## 维护者：构建与发布
构建安装包：
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-setup.ps1
```
输出：
```
dist\NotifySetup.exe
dist\NotifySetup-<version>.exe
```
发布：更新 `VERSION` 与 `CHANGELOG.md` 后运行
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\release.ps1
```

## License
MIT
