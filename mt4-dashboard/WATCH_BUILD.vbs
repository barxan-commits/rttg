'Starts Watch-BuildRequests.ps1 without a window. Used by the scheduled task "MT4 Dashboard build button".
Option Explicit
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\Watch-BuildRequests.ps1""", 0, False
