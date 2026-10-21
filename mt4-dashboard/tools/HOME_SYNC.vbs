'Runs HOME-SyncToDrive_v36.ps1 without opening a window. Used by the scheduled task "MT4 HOME sync to Drive".
'The script itself exits at once when a previous run is still going.
Option Explicit
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
WScript.Quit sh.Run("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\HOME-SyncToDrive_v36.ps1""", 0, True)
