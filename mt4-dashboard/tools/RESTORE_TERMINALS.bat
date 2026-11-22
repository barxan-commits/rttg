@echo off
setlocal
rem Restores the backed-up MT4 terminals on THIS machine (portable installs under C:\MT4_Terminals). Run from inside the backup folder.
rem Options after the file name, for example:  RESTORE_TERMINALS.bat -Verify   or   -ListOnly   or   -InstallRoot D:\MT4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-Terminals.ps1" %*
echo.
pause
