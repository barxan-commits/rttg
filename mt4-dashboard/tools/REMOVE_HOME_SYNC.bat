@echo off
schtasks /Delete /TN "MT4 HOME sync to Drive" /F
echo.
echo   The automatic HOME sync is off. Run the script by hand when you need it.
echo.
pause
