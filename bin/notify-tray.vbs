Set oShell = CreateObject("WScript.Shell")
oShell.Run "powershell -STA -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\Administrator\bin\notify-tray.ps1""", 0, False
