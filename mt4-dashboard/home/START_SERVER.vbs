'Starts Serve-Dashboard.ps1 without a window. Used by OPEN_DASHBOARD.bat.
Option Explicit
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\Serve-Dashboard.ps1""", 0, False
