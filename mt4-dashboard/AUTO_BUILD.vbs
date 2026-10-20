'Runs Build-DashboardData.ps1 without opening a window. Used by the scheduled
'task "MT4 Dashboard build" that INSTALL_AUTO_UPDATE.bat creates.
Option Explicit
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
'keep the Build now helper alive: it exits at once when it is already running
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\Watch-BuildRequests.ps1""", 0, False
WScript.Quit sh.Run("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\Build-DashboardData.ps1""", 0, True)
