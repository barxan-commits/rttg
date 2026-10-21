@echo off
setlocal
rem Makes the HOME sync run by itself: every 30 minutes, hidden, while you are logged in.
rem Put this file, HOME_SYNC.vbs and HOME-SyncToDrive_v36.ps1 in ONE folder on the home PC, then double-click this file.
rem REMOVE_HOME_SYNC.bat turns it off again.
set "HERE=%~dp0"
set "TASK=MT4 HOME sync to Drive"
echo.
echo   MT4 HOME sync - automatic
echo   =========================
echo   This PC:  %COMPUTERNAME%
echo   Folder:   %HERE%
echo.
if not exist "%HERE%HOME-SyncToDrive_v36.ps1" goto :missing
if not exist "%HERE%HOME_SYNC.vbs" goto :missing
echo   Other scheduled tasks on this PC that mention "sync" (for your information, they are not touched):
schtasks /Query /FO LIST 2>nul | findstr /i /c:"TaskName" | findstr /i "sync"
echo.
set "RUN=wscript.exe //B //Nologo \"%HERE%HOME_SYNC.vbs\""
schtasks /Create /TN "%TASK%" /SC MINUTE /MO 30 /TR "%RUN%" /F
if errorlevel 1 goto :failed
echo.
echo   Running the sync once now so you can see it works...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%HOME-SyncToDrive_v36.ps1"
echo.
echo   Done. The HOME terminals now sync to Google Drive every 30 minutes while this PC is on and you are logged in.
echo   Check I:\My Drive\MT4_Terminals\_sync_status_HOME.txt: the Run time should be recent.
goto :end

:missing
echo   HOME-SyncToDrive_v36.ps1 and HOME_SYNC.vbs must be in the same folder as this file.
goto :end

:failed
echo.
echo   Could not create the scheduled task. Right-click this file, choose "Run as administrator" and try again.

:end
echo.
pause
