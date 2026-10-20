@echo off
setlocal
rem Opens the MT4 Dashboard on this PC. No Claude needed. It needs Google Drive for desktop (I:\My Drive\MT4_Terminals).
rem Starts the local dashboard server hidden and opens the dashboard in Microsoft Edge.
rem Everything is read from the Google Drive folder on this PC; nothing is downloaded from the internet.
set "HERE=%~dp0"
echo.
echo   MT4 Dashboard
echo   =============
echo   Starting...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*Serve-Dashboard.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
if exist "%HERE%server_url.txt" del "%HERE%server_url.txt" >nul 2>&1
wscript.exe //B //Nologo "%HERE%START_SERVER.vbs"
set "URL="
for /l %%i in (1,1,15) do if not defined URL (
  if exist "%HERE%server_url.txt" set /p URL=<"%HERE%server_url.txt"
  if not defined URL timeout /t 1 >nul
)
if not defined URL goto :failed
echo %URL% | find "ERROR" >nul && goto :failed
echo   Opening %URL%
start "" msedge "%URL%"
if errorlevel 1 start "" "%URL%"
timeout /t 3 >nul
goto :end
:failed
echo.
echo   The local dashboard server did not start.
if exist "%HERE%server_url.txt" type "%HERE%server_url.txt"
echo   Check that Google Drive for desktop is running and that Serve-Dashboard.ps1 is in this folder.
pause
:end
