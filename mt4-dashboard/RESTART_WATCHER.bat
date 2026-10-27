@echo off
rem Restarts the "Build now" helper on this PC so it runs the newest Watch-BuildRequests.ps1.
rem Double-click this file from the _DASHBOARD_BUILD folder. Nothing to type or paste.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%Watch-BuildRequests.ps1" goto :missing
if not exist "%HERE%WATCH_BUILD.vbs" goto :missing

echo Stopping the old helper ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'Watch-BuildRequests' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

echo Starting the new helper ...
wscript.exe //B "%HERE%WATCH_BUILD.vbs"
timeout /t 12 /nobreak >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$n = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'Watch-BuildRequests' -and $_.ProcessId -ne $PID }).Count; if ($n -ge 1) { Write-Host 'OK - the Build now helper is running. You can press Build now in the dashboard.' -ForegroundColor Green } else { Write-Host 'NOT running. Wait a minute for Google Drive to finish syncing this folder, then run this file again.' -ForegroundColor Red }"
echo.
pause
exit /b 0

:missing
echo Watch-BuildRequests.ps1 and WATCH_BUILD.vbs must be in the same folder as this file (_DASHBOARD_BUILD).
pause
exit /b 1
