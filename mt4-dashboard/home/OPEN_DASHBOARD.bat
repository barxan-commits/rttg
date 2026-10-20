@echo off
setlocal
rem Opens the MT4 Dashboard on this PC. No Claude needed. It needs Google Drive for desktop (I:\My Drive\MT4_Terminals).
rem 1. Stops an older local dashboard server, 2. downloads the newest dashboard files (when online),
rem 3. starts the local server hidden, 4. opens the dashboard in Microsoft Edge.
set "HERE=%~dp0"
echo.
echo   MT4 Dashboard
echo   =============
echo   Checking for a newer version...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*Serve-Dashboard.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; $b='https://raw.githubusercontent.com/barxan-commits/rttg/claude/session-dxnzui/mt4-dashboard/'; $h='%HERE%'; $ok=0; foreach ($f in @(@('index.html',100000,'index.html'), @('home/dashboard-shim.js',500,'dashboard-shim.js'), @('home/Serve-Dashboard.ps1',500,'Serve-Dashboard.ps1'))) { try { $t = $h + $f[2] + '.new'; Invoke-WebRequest -UseBasicParsing -Uri ($b + $f[0]) -OutFile $t -TimeoutSec 30; if ((Get-Item $t).Length -gt $f[1]) { if ($f[2] -eq 'index.html' -and (Test-Path ($h + 'index.html'))) { Copy-Item ($h + 'index.html') ($h + 'index.previous.html') -Force }; Move-Item $t ($h + $f[2]) -Force; $ok++ } else { Remove-Item $t -Force } } catch { Remove-Item ($h + $f[2] + '.new') -Force -ErrorAction SilentlyContinue } }; if ($ok -eq 3) { Write-Host '  Updated to the newest version.' } else { Write-Host '  Could not update everything (offline?): using the files you have.' }"
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
