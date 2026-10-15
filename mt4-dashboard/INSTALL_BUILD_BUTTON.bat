@echo off
setlocal
rem Turns on the dashboard's "Build now" button on THIS PC (run it once, on the VPS).
rem Creates the scheduled task "MT4 Dashboard build button": a hidden watcher that starts when you log in.
rem REMOVE_BUILD_BUTTON.bat turns it off again.
set "HERE=%~dp0"
set "TASK=MT4 Dashboard build button"
echo.
echo   MT4 Dashboard - Build now button
echo   ================================
echo   This PC:  %COMPUTERNAME%
echo   Folder:   %HERE%
echo.
if not exist "%HERE%Watch-BuildRequests.ps1" goto :missing
if not exist "%HERE%WATCH_BUILD.vbs" goto :missing
if not exist "%HERE%Build-DashboardData.ps1" goto :missing
set "RUN=wscript.exe //B //Nologo \"%HERE%WATCH_BUILD.vbs\""
if not exist "%SystemRoot%\System32\vbscript.dll" set "RUN=conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"%HERE%Watch-BuildRequests.ps1\""
echo   Task command: %RUN%
schtasks /Create /TN "%TASK%" /SC ONLOGON /TR "%RUN%" /F
if errorlevel 1 goto :failed
schtasks /Run /TN "%TASK%" >nul 2>&1
echo.
echo   Done. The watcher is running now (hidden) and starts again every time you log in.
echo   The dashboard's "Build now" button starts a build within about a minute.
goto :end

:missing
echo   Watch-BuildRequests.ps1, WATCH_BUILD.vbs and Build-DashboardData.ps1 must be in the same folder as this file.
goto :end

:failed
echo.
echo   Could not create the scheduled task. Right-click INSTALL_BUILD_BUTTON.bat,
echo   choose "Run as administrator" and try again.

:end
echo.
pause
