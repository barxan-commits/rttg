@echo off
setlocal
rem Turns off the automatic MT4 Dashboard data build on THIS PC.
set "HERE=%~dp0"
set "OLDPC="
schtasks /Delete /TN "MT4 Dashboard build" /F
if exist "%HERE%BUILD_PC.txt" set /p OLDPC=<"%HERE%BUILD_PC.txt"
if /i "%OLDPC%"=="%COMPUTERNAME%" del "%HERE%BUILD_PC.txt"
echo.
echo   The automatic build is off on %COMPUTERNAME%. The dashboard keeps the last data.
echo.
pause
