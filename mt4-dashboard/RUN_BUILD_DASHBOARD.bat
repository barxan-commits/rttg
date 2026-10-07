@echo off
setlocal
rem Builds the files the online MT4 Dashboard reads (MT4_Terminals\_DASHBOARD) once, now.
rem Read-only for MT4 data. In MT4_Terminals\_DASHBOARD_BUILD it finds the data by itself;
rem anywhere else it uses I:\My Drive\MT4_Terminals unless you set PROJECT_ROOT below.
set "PROJECT_ROOT="
set "ARGS="
if defined PROJECT_ROOT set ARGS=-ProjectRoot "%PROJECT_ROOT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-DashboardData.ps1" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
