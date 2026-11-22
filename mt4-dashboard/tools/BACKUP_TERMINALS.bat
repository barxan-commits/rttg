@echo off
setlocal
rem Backs up the ACTIVE MT4 terminals (programs + data) to a folder on the Desktop. Run on the machine that has the terminals.
rem Add options after the file name in a command window, for example:  BACKUP_TERMINALS.bat -ListOnly   or   -IncludeHistory   or   -CloseTerminalsFirst
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-ActiveTerminals.ps1" %*
echo.
pause
