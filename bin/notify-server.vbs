Set oShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
oShell.Run "powershell -STA -NoLogo -NonInteractive -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\notify-server.ps1""", 0, False
