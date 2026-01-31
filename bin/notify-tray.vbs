Set oShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
oShell.Run "powershell -STA -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\notify-tray.ps1""", 0, False
