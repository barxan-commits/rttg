@echo off
setlocal
rem Turns on the automatic MT4 Dashboard data build on THIS PC (run it once, on the VPS).
rem Creates the scheduled task "MT4 Dashboard build": every 10 minutes, hidden, low priority,
rem while you are logged in. BUILD_PC.txt makes every other PC skip the build.
rem REMOVE_AUTO_UPDATE.bat turns it off again.
set "HERE=%~dp0"
set "TASK=MT4 Dashboard build"
set "OLDPC="
echo.
echo   MT4 Dashboard - automatic data build
echo   ====================================
echo   This PC:  %COMPUTERNAME%
echo   Folder:   %HERE%
echo.
if not exist "%HERE%Build-DashboardData.ps1" goto :missing
if not exist "%HERE%AUTO_BUILD.vbs" goto :missing
if exist "%HERE%BUILD_PC.txt" set /p OLDPC=<"%HERE%BUILD_PC.txt"
if not defined OLDPC goto :install
if /i "%OLDPC%"=="%COMPUTERNAME%" goto :install
echo   The data is built on %OLDPC% now. Run this file there instead,
echo   unless you want to move the build to this PC.
echo.
choice /c YN /m "  Move the build to %COMPUTERNAME%"
if errorlevel 2 goto :end

:install
>"%HERE%BUILD_PC.txt" echo %COMPUTERNAME%
set "RUN=wscript.exe \"%HERE%AUTO_BUILD.vbs\""
if not exist "%SystemRoot%\System32\vbscript.dll" set "RUN=powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%HERE%Build-DashboardData.ps1\""
schtasks /Create /TN "%TASK%" /SC MINUTE /MO 10 /TR "%RUN%" /F
if errorlevel 1 goto :failed
echo.
echo   Building the data once now so you can see it works (about a minute)...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%Build-DashboardData.ps1"
echo.
echo   Done. The dashboard data now rebuilds every 10 minutes while this PC is on
echo   and you are logged in (a disconnected Remote Desktop session is fine).
echo   Each run is noted in last_build_%COMPUTERNAME%.txt in this folder.
goto :end

:missing
echo   Build-DashboardData.ps1 and AUTO_BUILD.vbs must be in the same folder as this file.
goto :end

:failed
echo.
echo   Could not create the scheduled task. Right-click INSTALL_AUTO_UPDATE.bat,
echo   choose "Run as administrator" and try again.

:end
echo.
pause
