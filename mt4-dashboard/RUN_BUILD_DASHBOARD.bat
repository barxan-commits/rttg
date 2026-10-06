@echo off
setlocal
rem Builds the compact files the online MT4 Dashboard reads (MT4_Terminals\_DASHBOARD).
rem Read-only for MT4 data. Edit PROJECT_ROOT if your Drive letter differs.
set "PROJECT_ROOT=I:\My Drive\MT4_Terminals"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-DashboardData.ps1" -ProjectRoot "%PROJECT_ROOT%"
exit /b %ERRORLEVEL%
