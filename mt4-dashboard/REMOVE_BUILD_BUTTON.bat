@echo off
rem Turns the dashboard's "Build now" button off on THIS PC and stops the watcher.
schtasks /Delete /TN "MT4 Dashboard build button" /F
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*Watch-BuildRequests*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo.
echo   The Build now button is off. The 30 minute automatic build is not affected.
echo.
pause
