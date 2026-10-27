<#
  Runs in the background on the VPS (started at logon by INSTALL_BUILD_BUTTON.bat).
  The dashboard's "Build now" button puts a file BUILD_NOW_<time>.txt into this folder (through Google Drive).
  When this watcher sees one, it deletes it and runs Build-DashboardData.ps1 -Force. If a build is already
  running, the request stays and is served when that build is done.
  It also writes BUTTON_WATCHER.txt every 5 minutes so the dashboard can show that the watcher is alive.
#>
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$pc = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
$runLog = Join-Path $here ('last_build_' + $pc + '.txt')
$buildScript = Join-Path $here 'Build-DashboardData.ps1'
$beat = Join-Path $here 'BUTTON_WATCHER.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# one watcher per PC
$own = $false
$single = New-Object System.Threading.Mutex($false, $(if ($IsLinux -or $IsMacOS) { 'MT4DashboardBuildWatcher' } else { 'Global\MT4DashboardBuildWatcher' }))
try { $own = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
if (-not $own) { exit 0 }

$ps = (Get-Process -Id $PID).Path
$lastBeat = [datetime]::MinValue
while ($true) {
  try {
    if (((Get-Date) - $lastBeat).TotalMinutes -ge 5) {
      [System.IO.File]::WriteAllText($beat, ('alive ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' on ' + $pc + "`r`n"), $utf8)
      $lastBeat = Get-Date
    }
    $req = @(Get-ChildItem -LiteralPath $here -Filter 'BUILD_NOW*' -File -ErrorAction SilentlyContinue)
    if ($req.Count) {
      # is a build running right now (the 30-minute task, or an earlier request)?
      $m = New-Object System.Threading.Mutex($false, $(if ($IsLinux -or $IsMacOS) { 'MT4DashboardBuild' } else { 'Global\MT4DashboardBuild' }))
      $free = $false
      try { $free = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
      if ($free) { $m.ReleaseMutex() }
      $m.Dispose()
      if ($free) {
        $req | Remove-Item -Force -ErrorAction SilentlyContinue
        $started = Get-Date
        $lines = @(('MT4 Dashboard build on ' + $pc), ('Started:  ' + $started.ToString('yyyy-MM-dd HH:mm:ss')), 'Result:   RUNNING - started by the dashboard Build now button')
        [System.IO.File]::WriteAllText($runLog, ($lines -join "`r`n") + "`r`n", $utf8)
        # Windows PowerShell 5.1 does not quote the items of an -ArgumentList array: "I:\My Drive\..." was split at the space,
        # the builder died at once and this note stayed on RUNNING for ever. One string with the path in quotes avoids that.
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $buildScript + '" -Force'
        $code = $null
        try {
          if ($IsLinux -or $IsMacOS) { $pr = Start-Process -FilePath $ps -ArgumentList $argLine -Wait -PassThru }
          else { $pr = Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden -Wait -PassThru }
          $code = $pr.ExitCode
        } catch { $code = 'could not start: ' + $_.Exception.Message }
        # the builder rewrites this note itself; if it is still the watcher's note, the builder ended without a word
        $now = @(Get-Content -LiteralPath $runLog -TotalCount 3 -ErrorAction SilentlyContinue)
        if (($now -join ' ') -match 'RUNNING - started by the dashboard Build now button') {
          $lines = @(('MT4 Dashboard build on ' + $pc), ('Started:  ' + $started.ToString('yyyy-MM-dd HH:mm:ss')), ('Finished: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
            ('Result:   FAILED - the build process ended without writing a result (exit code ' + $code + '). Another build may have been running; press Build now again.'))
          [System.IO.File]::WriteAllText($runLog, ($lines -join "`r`n") + "`r`n", $utf8)
        }
      }
    }
  } catch { }
  Start-Sleep -Seconds 10
}
