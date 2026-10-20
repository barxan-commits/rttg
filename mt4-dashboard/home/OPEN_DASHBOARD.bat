@echo off
setlocal
rem Opens the MT4 Dashboard on this PC. No Claude needed.
rem 1. Downloads the newest index.html (if the PC is online; otherwise keeps the copy it has).
rem 2. Opens it in Microsoft Edge (Chrome also works: open index.html with it).
set "HERE=%~dp0"
set "URL=https://raw.githubusercontent.com/barxan-commits/rttg/claude/session-dxnzui/mt4-dashboard/index.html"
echo.
echo   MT4 Dashboard - checking for a newer version...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%HERE%index.new' -TimeoutSec 30; if ((Get-Item '%HERE%index.new').Length -gt 100000) { if (Test-Path '%HERE%index.html') { Copy-Item '%HERE%index.html' '%HERE%index.previous.html' -Force }; Move-Item '%HERE%index.new' '%HERE%index.html' -Force; Write-Host '  Updated to the newest version.' } else { Remove-Item '%HERE%index.new' -Force; Write-Host '  Download looked wrong, keeping your copy.' } } catch { Write-Host '  Offline: using the copy you have.' }"
start "" msedge "%HERE%index.html"
if errorlevel 1 start "" "%HERE%index.html"
timeout /t 3 >nul
