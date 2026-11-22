# Backup-ActiveTerminals.ps1  -  full backup of the ACTIVE MetaTrader 4 terminals, to deploy on a new machine
# Run this ON THE MACHINE THAT HAS THE TERMINALS (the VPS), as the Windows user that runs them.
# Windows PowerShell 5.1 compatible. Read-only on the terminals: it only COPIES (robocopy); nothing is deleted or changed.
#
# What a terminal is here: one MT4 program folder (terminal.exe) + its data folder (MQL4 EAs/presets/files, charts/profiles,
# templates, config). A terminal is ACTIVE when it is running now, or any of its logs / MQL4\Files / profiles changed within -ActiveDays.
#
# Examples
#   .\Backup-ActiveTerminals.ps1 -ListOnly                       (only show what would be backed up, copy nothing)
#   .\Backup-ActiveTerminals.ps1                                 (backup to Desktop\MT4_BACKUP_<date time>)
#   .\Backup-ActiveTerminals.ps1 -OutDir D:\Backups -ActiveDays 30 -IncludeHistory
[CmdletBinding()]
param(
    [string]$OutDir = '',                 # default: <Desktop>\MT4_BACKUP_<yyyyMMdd_HHmm>
    [int]$ActiveDays = 7,                 # active = running now OR something changed in this many days
    [switch]$AllTerminals,                # back up inactive ones too
    [switch]$IncludeHistory,              # also the downloaded price history (big; MT4 re-downloads it)
    [switch]$IncludeLogs,                 # also the terminal / Experts logs
    [switch]$SkipCollectorReports,        # leave out MQL4\Files\GPT_REPORTS (collector exports, regenerated, can be huge)
    [switch]$CloseTerminalsFirst,         # ask running terminals to close (clean copy); you can also close them by hand
    [switch]$ListOnly,
    [string[]]$ExtraPaths = @(),          # more folders to copy (for example the dashboard tools folder)
    [string[]]$ExtraDataPaths = @()       # portable terminal data folders that are not under %APPDATA%\MetaQuotes\Terminal
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date

function Write-Info($m) { Write-Host $m }
function Safe-Name([string]$s) { return ($s -replace '[^A-Za-z0-9_.-]', '_') }

# ---------- what is running ----------
$running = @()
try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='terminal.exe'" -ErrorAction Stop |
        Where-Object { $_.ExecutablePath } |
        ForEach-Object { [pscustomobject]@{ Pid = $_.ProcessId; Exe = $_.ExecutablePath; Dir = (Split-Path -Parent $_.ExecutablePath); Cmd = $_.CommandLine } })
} catch { Write-Warning "Could not read running processes: $($_.Exception.Message)" }

# ---------- find terminals: data folders under %APPDATA%\MetaQuotes\Terminal + portable installs + extra paths ----------
$terms = New-Object System.Collections.ArrayList
$seen = @{}
function Add-Terminal([string]$data, [string]$install, [bool]$portable, [string]$hash) {
    $key = $data.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $data 'MQL4'))) { return }
    $seen[$key] = $true
    [void]$terms.Add([pscustomobject]@{ Hash = $hash; DataPath = $data; InstallPath = $install; Portable = $portable })
}
$meta = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (Test-Path -LiteralPath $meta) {
    foreach ($d in (Get-ChildItem -LiteralPath $meta -Directory -ErrorAction SilentlyContinue)) {
        $install = ''
        $origin = Join-Path $d.FullName 'origin.txt'
        if (Test-Path -LiteralPath $origin) {
            try { $install = ((Get-Content -LiteralPath $origin -Raw -ErrorAction Stop) -replace "[\x00\uFEFF\r\n]", '').Trim() } catch { }
        }
        Add-Terminal $d.FullName $install $false $d.Name
    }
}
foreach ($x in $ExtraDataPaths) { if ($x -and (Test-Path -LiteralPath $x)) { Add-Terminal (Get-Item -LiteralPath $x).FullName '' $false (Split-Path -Leaf $x) } }
foreach ($r in $running) {   # portable installs keep MQL4 next to terminal.exe
    if (Test-Path -LiteralPath (Join-Path $r.Dir 'MQL4')) { Add-Terminal $r.Dir $r.Dir $true (Split-Path -Leaf $r.Dir) }
}

function Get-LastActivity($t) {
    $paths = @('MQL4\Logs', 'logs', 'MQL4\Files', 'profiles', 'config')
    $best = [datetime]::MinValue
    foreach ($p in $paths) {
        $full = Join-Path $t.DataPath $p
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $f = Get-ChildItem -LiteralPath $full -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f -and $f.LastWriteTime -gt $best) { $best = $f.LastWriteTime }
    }
    return $best
}
function Get-Account($t) {
    # 1) last login in config\terminal.ini / common.ini; 2) Statement_<account>.csv style file names in MQL4\Files
    foreach ($f in @('config\terminal.ini', 'config\common.ini')) {
        $p = Join-Path $t.DataPath $f
        if (Test-Path -LiteralPath $p) {
            $m = Select-String -LiteralPath $p -Pattern '^\s*Login\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
        }
    }
    $files = Join-Path $t.DataPath 'MQL4\Files'
    if (Test-Path -LiteralPath $files) {
        $f = Get-ChildItem -LiteralPath $files -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?:Statement|account|Quant)[_-]?.*?(\d{5,})' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f -and $f.Name -match '(\d{5,})') { return $Matches[1] }
    }
    return ''
}

$cut = (Get-Date).AddDays(-$ActiveDays)
$rows = @()
foreach ($t in $terms) {
    $dir = if ($t.Portable) { $t.DataPath } else { $t.InstallPath }
    $isRun = $false
    foreach ($r in $running) { if ($dir -and ($r.Dir.TrimEnd('\') -ieq $dir.TrimEnd('\'))) { $isRun = $true } }
    $last = Get-LastActivity $t
    $active = $isRun -or ($last -ge $cut)
    $installOk = [bool]($t.InstallPath -and (Test-Path -LiteralPath (Join-Path $t.InstallPath 'terminal.exe')))
    $rows += [pscustomobject]@{
        Hash = $t.Hash; Account = (Get-Account $t); Running = $isRun; Active = $active
        LastActivity = $(if ($last -gt [datetime]::MinValue) { $last.ToString('yyyy-MM-dd HH:mm') } else { '-' })
        Portable = $t.Portable; InstallPath = $t.InstallPath; InstallFound = $installOk; DataPath = $t.DataPath
    }
}
Write-Info ''
Write-Info "Terminals found: $($rows.Count)   running now: $(@($rows | Where-Object Running).Count)   active (last $ActiveDays days): $(@($rows | Where-Object Active).Count)"
$rows | Sort-Object @{Expression='Active';Descending=$true}, Account | Format-Table Hash, Account, Active, Running, LastActivity, Portable, InstallFound, InstallPath -AutoSize | Out-String -Width 250 | Write-Host
$pick = @($rows | Where-Object { $AllTerminals -or $_.Active })
if (-not $pick.Count) { Write-Warning 'Nothing to back up (no active terminal). Use -AllTerminals or a larger -ActiveDays.'; return }
$noInstall = @($pick | Where-Object { -not $_.InstallFound -and -not $_.Portable })
if ($noInstall.Count) { Write-Warning ("Program folder not found for: " + (($noInstall | ForEach-Object { $_.Hash }) -join ', ') + ". Their DATA is backed up; install MetaTrader 4 from your broker on the new machine and the data is restored into it.") }
if ($ListOnly) { Write-Info 'ListOnly: nothing was copied.'; return }

# ---------- destination ----------
if (-not $OutDir) {
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $env:USERPROFILE }
    $OutDir = Join-Path $desk ('MT4_BACKUP_' + (Get-Date).ToString('yyyyMMdd_HHmm'))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$drive = (Get-Item -LiteralPath $OutDir).PSDrive
Write-Info "Backup folder: $OutDir   (free space on $($drive.Name): $([math]::Round($drive.Free/1GB,1)) GB)"

# ---------- optional: close running terminals so the copy is clean ----------
if ($CloseTerminalsFirst) {
    foreach ($r in $running) { try { $p = Get-Process -Id $r.Pid -ErrorAction Stop; [void]$p.CloseMainWindow() } catch { } }
    Write-Info 'Asked running terminals to close; waiting up to 90 s ...'
    $until = (Get-Date).AddSeconds(90)
    while ((Get-Process terminal -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Seconds 3 }
    if (Get-Process terminal -ErrorAction SilentlyContinue) { Write-Warning 'Some terminals are still running: their copy may be inconsistent.' }
}

function Robo([string]$src, [string]$dst, [string[]]$xd, [string[]]$xf, [bool]$recurse) {
    $a = @($src, $dst)
    if ($recurse) { $a += '/E' }
    $a += @('/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:8')
    if ($xd -and $xd.Count) { $a += '/XD'; $a += $xd }
    if ($xf -and $xf.Count) { $a += '/XF'; $a += $xf }
    & robocopy @a | Out-Null
    return $LASTEXITCODE   # 0-7 = fine (bit 8 = some files failed, 16 = fatal)
}

$manifest = @()
$problems = @()
$idx = 0
foreach ($p in $pick) {
    $idx++
    $label = 'T{0:D2}_{1}' -f $idx, $(if ($p.Account) { Safe-Name $p.Account } else { Safe-Name $p.Hash.Substring(0, [math]::Min(8, $p.Hash.Length)) })
    $root = Join-Path $OutDir $label
    $dataOut = Join-Path $root 'data'
    $progOut = Join-Path $root 'program'
    New-Item -ItemType Directory -Force -Path $dataOut | Out-Null
    Write-Info ''
    Write-Info "[$idx/$($pick.Count)] $label   account=$($p.Account)   data=$($p.DataPath)"
    $codes = @{}
    # --- data folder: MQL4 (EAs, indicators, libraries, scripts, presets, include, files), config, profiles (charts), templates, root files ---
    $mqlXD = @(); if (-not $IncludeLogs) { $mqlXD += (Join-Path $p.DataPath 'MQL4\Logs') }
    if ($SkipCollectorReports) { $mqlXD += (Join-Path $p.DataPath 'MQL4\Files\GPT_REPORTS') }
    $codes['MQL4'] = Robo (Join-Path $p.DataPath 'MQL4') (Join-Path $dataOut 'MQL4') $mqlXD @() $true
    foreach ($sub in @('config', 'profiles', 'templates', 'signals', 'sounds')) {
        $s = Join-Path $p.DataPath $sub
        if (Test-Path -LiteralPath $s) { $codes[$sub] = Robo $s (Join-Path $dataOut $sub) @() @() $true }
    }
    if ($IncludeHistory -and (Test-Path -LiteralPath (Join-Path $p.DataPath 'history'))) { $codes['history'] = Robo (Join-Path $p.DataPath 'history') (Join-Path $dataOut 'history') @() @() $true }
    if ($IncludeLogs -and (Test-Path -LiteralPath (Join-Path $p.DataPath 'logs'))) { $codes['logs'] = Robo (Join-Path $p.DataPath 'logs') (Join-Path $dataOut 'logs') @() @() $true }
    # loose files in the data folder root (origin.txt, *.ini ...)
    $null = Robo $p.DataPath $dataOut @() @() $false
    # --- program folder (terminal.exe, metaeditor.exe, languages ...) ---
    $progSrc = $p.InstallPath
    if ($p.Portable) { $progSrc = $p.DataPath }
    if ($progSrc -and (Test-Path -LiteralPath (Join-Path $progSrc 'terminal.exe'))) {
        New-Item -ItemType Directory -Force -Path $progOut | Out-Null
        $xd = @('MQL4', 'config', 'profiles', 'templates', 'history', 'logs', 'tester', 'signals', 'sounds', 'bases', 'MQL5') | ForEach-Object { Join-Path $progSrc $_ }
        $codes['program'] = Robo $progSrc $progOut $xd @() $true
    }
    foreach ($k in $codes.Keys) { if ($codes[$k] -ge 8) { $problems += "$label/$k robocopy exit $($codes[$k])" } }
    $bytes = 0; try { $bytes = (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
    $manifest += [pscustomobject]@{
        Label = $label; Account = $p.Account; Hash = $p.Hash; Portable = $p.Portable
        SourceDataPath = $p.DataPath; SourceInstallPath = $p.InstallPath; ProgramIncluded = (Test-Path -LiteralPath $progOut)
        RunningWhenCopied = $p.Running; LastActivity = $p.LastActivity; SizeMB = [math]::Round($bytes / 1MB, 1)
        Experts = @(Get-ChildItem -LiteralPath (Join-Path $dataOut 'MQL4\Experts') -File -Filter '*.ex4' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
}

# ---------- windows side: scheduled tasks, startup items, terminal shortcuts ----------
$sys = Join-Path $OutDir '_SYSTEM'
New-Item -ItemType Directory -Force -Path $sys | Out-Null
try {
    $tasksDir = Join-Path $sys 'scheduled_tasks'; New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    foreach ($tk in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $text = (($tk.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ')
        if ($tk.TaskName -match 'MT4|MetaTrader|terminal|Dashboard|Drive' -or $text -match 'terminal\.exe|MT4|Dashboard|SyncToDrive|Build-Dashboard') {
            $xml = Export-ScheduledTask -TaskName $tk.TaskName -TaskPath $tk.TaskPath -ErrorAction SilentlyContinue
            if ($xml) { Set-Content -LiteralPath (Join-Path $tasksDir ((Safe-Name $tk.TaskName) + '.xml')) -Value $xml -Encoding Unicode }
        }
    }
} catch { Write-Warning "Scheduled tasks not exported: $($_.Exception.Message)" }
try {
    $lnkDir = Join-Path $sys 'shortcuts'; New-Item -ItemType Directory -Force -Path $lnkDir | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
    $info = @()
    foreach ($pl in $places) {
        if (-not $pl -or -not (Test-Path -LiteralPath $pl)) { continue }
        foreach ($l in (Get-ChildItem -LiteralPath $pl -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            $s = $sh.CreateShortcut($l.FullName)
            if ($s.TargetPath -match 'terminal|metatrader|MT4' -or $l.Name -match 'MT4|MetaTrader|Terminal') {
                Copy-Item -LiteralPath $l.FullName -Destination $lnkDir -Force
                $info += [pscustomobject]@{ Name = $l.Name; Folder = $pl; Target = $s.TargetPath; Arguments = $s.Arguments; WorkingDirectory = $s.WorkingDirectory }
            }
        }
    }
    $info | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $sys 'shortcuts.json') -Encoding UTF8
} catch { Write-Warning "Shortcuts not saved: $($_.Exception.Message)" }
$runInfo = $running | ForEach-Object { [pscustomobject]@{ Exe = $_.Exe; CommandLine = $_.Cmd } }
$runInfo | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $sys 'running_terminals.json') -Encoding UTF8
foreach ($x in $ExtraPaths) { if ($x -and (Test-Path -LiteralPath $x)) { $n = Safe-Name (Split-Path -Leaf $x); $null = Robo $x (Join-Path $OutDir ('_EXTRA\' + $n)) @() @() $true } }

# ---------- manifest, checksums, restore tools ----------
$man = [pscustomobject]@{
    Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Machine = $env:COMPUTERNAME; User = $env:USERNAME
    ActiveDays = $ActiveDays; IncludesHistory = [bool]$IncludeHistory; IncludesLogs = [bool]$IncludeLogs; SkippedCollectorReports = [bool]$SkipCollectorReports
    Terminals = $manifest; Problems = $problems
}
$man | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'MANIFEST.json') -Encoding UTF8
Write-Info ''
Write-Info 'Writing SHA256 list (this can take a while for big folders) ...'
$sumFile = Join-Path $OutDir 'FILES.sha256'
$lines = New-Object System.Collections.Generic.List[string]
$prefix = (Get-Item -LiteralPath $OutDir).FullName.TrimEnd('\') + '\'
foreach ($f in (Get-ChildItem -LiteralPath $OutDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'FILES.sha256' })) {
    try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash; $lines.Add($h + '  ' + $f.FullName.Substring($prefix.Length)) } catch { }
}
Set-Content -LiteralPath $sumFile -Value $lines -Encoding UTF8
foreach ($n in @('Restore-Terminals.ps1', 'RESTORE_TERMINALS.bat')) { $s = Join-Path $PSScriptRoot $n; if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $OutDir -Force } }
@"
MT4 TERMINALS BACKUP  -  made $($man.Created) on $($env:COMPUTERNAME)
=====================================================================
Terminals in this backup: $($manifest.Count)   (see MANIFEST.json: account, source paths, size, installed EAs)
Each T##_<account> folder holds:  data\  (MQL4 EAs/presets/files, config, profiles = charts, templates)  and  program\  (terminal.exe folder).
_SYSTEM holds exported scheduled tasks, startup shortcuts and the command lines the terminals were started with.

ON THE NEW MACHINE
  1. Copy this whole folder to the new machine (an external disk or Google Drive works; keep the folder structure).
  2. Check the copy:  Restore-Terminals.ps1 -Verify
  3. Restore:         double-click RESTORE_TERMINALS.bat   (or  .\Restore-Terminals.ps1 -InstallRoot C:\MT4_Terminals)
     Each terminal is rebuilt as a PORTABLE install (program + data in one folder, started with /portable), so it does not depend
     on the hash folder name under %APPDATA%\MetaQuotes\Terminal.
  4. Start each terminal from the shortcuts the restore creates, log in to the broker account, check the EAs are on their charts
     and that AutoTrading is ON.
  5. If the Drive sync / dashboard build runs there, add the printed portable data folders to  `$ExtraDataPaths  in VPS-SyncToDrive.

NOTES
  - Broker passwords: I cannot confirm they are stored in these files. Have every account's login, password and server at hand.
  - This folder contains account numbers and server names: keep it private, do not upload it to a shared place.
  - Terminals that were running while copied are marked RunningWhenCopied in MANIFEST.json: their files can be mid-write. For a clean copy
    close the terminals (or run with -CloseTerminalsFirst) and back up again.
"@ | Set-Content -LiteralPath (Join-Path $OutDir 'README_RESTORE.txt') -Encoding UTF8

Write-Info ''
Write-Info "DONE in $([math]::Round(((Get-Date) - $started).TotalMinutes,1)) min.   Backup: $OutDir"
Write-Info ("Terminals backed up: " + (($manifest | ForEach-Object { "$($_.Label) ($($_.SizeMB) MB)" }) -join ', '))
if ($problems.Count) { Write-Warning ("Some copies reported problems: " + ($problems -join '; ')) }
