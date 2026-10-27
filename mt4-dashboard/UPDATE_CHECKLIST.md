# After an update: what to do on each PC

One rule: **never paste a script's contents into a terminal.** Files are double-clicked; only commands in a code block are pasted.

| What changed | Put the file here | Then |
|---|---|---|
| `Build-DashboardData.ps1` (the build) | VPS: `I:\My Drive\MT4_Terminals\_DASHBOARD_BUILD\` | Nothing. The next 30-minute build uses it. |
| `Watch-BuildRequests.ps1` (Build now helper) | VPS: `_DASHBOARD_BUILD\` | Double-click `RESTART_WATCHER.bat` in that folder. It says OK or NOT running. |
| `VPS-SyncToDrive_v37.ps1` | VPS: the folder the sync task runs from (as `SyncToDrive.ps1`) | Run it once, open `Terminal_*\_sync_status.txt`: it must say `STATUS: OK`. |
| `HOME-SyncToDrive_v36.ps1` | Home PC, same folder as `INSTALL_HOME_SYNC.bat` | Double-click `INSTALL_HOME_SYNC.bat` once. |
| `index.html` / dashboard | Published online from here | Reload the dashboard. The offline copy is refreshed once a day, or when you say "update offline". |

## Before you trust a run
- Google Drive must have finished syncing: file sizes on the PC must match what was sent.
- `last_build_<PC>.txt` should say `OK` after a build. `FAILED - ...` now always carries the reason.
- `_sync_status_<PC>.txt` per PC should say `STATUS: OK` for every terminal. If a terminal says `SOURCE NOT DISCOVERED`, the file lists every terminal folder it looked at and why.

## If something does not work
Send the **last 3 lines of the status file**, not a screenshot of the whole desktop. They say what failed.
