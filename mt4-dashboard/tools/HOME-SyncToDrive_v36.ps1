# MT4_Terminals AUTO-ID + Quant Drive Sync v3.6-HOME
# v3.6 changes:
#   - RUNAWAY LOGS. A log bigger than $MaxLogBytes (10 MB) is copied as its LAST $MaxLogBytes only, so one
#     EA that floods its log (gigabytes) cannot fill Drive or slow the dashboard build. The status file says how many were shortened.
#   - A file that disappears or is locked while copying is skipped instead of stopping the whole run.
# MT4_Terminals AUTO-ID + Quant Drive Sync v3.5-HOME
# v3.5 changes:
#   - ROOT FILE OWNERSHIP. HOME and VPS were both writing the SAME two root
#     files (_sync_status.txt and _terminal_identity_map.txt), so whichever ran
#     last made the fleet look like it contained only half the terminals.
#     Each profile now writes its OWN root files:
#         _sync_status_<PROFILE>.txt
#         _terminal_identity_map_<PROFILE>.txt
#     The shared legacy names are no longer written by either script.
#   - JOURNAL DIAGNOSTIC. 'Latest Journal source' picked the newest *.log in
#     the terminal logs folder, which could be metaeditor.log rather than the
#     MT4 date journal. It now considers only YYYYMMDD.log files.
# MT4_Terminals AUTO-ID + Quant Drive Sync v3.4-HOME
# v3.4: compatible with MT4Collector_Quant v2.04 (atomic writes, #END trailers).
#   - Quant file matching is now tag-agnostic (QuantV2 .. QuantV204 and later).
#     The old literal '_QuantV2_' filter would have matched NOTHING once the
#     collector moved to _QuantV204_ filenames.
#   - .tmp files are excluded. They are the collector's in-progress atomic
#     writes; copying them republishes the partial files atomic writes prevent.
#   - Reads the collector's own status file and reports liveness, so a stalled
#     collector is visible even though this copy refreshes the Drive mtime.
#   - Verifies the #END completion trailer on published CSVs.
#   - Fixed '*\\Experts\\*' filters that never matched (two literal backslashes).
# Finds the REAL MT4 terminal data folder by account/report identity instead of stale terminal hashes.
# Read-only: never changes MT4 trades or EA settings.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------- CONFIG ----------
$ProjectFolderName = 'MT4_Terminals'
$LookbackDays       = 3
$MachineLabel       = 'HOME'
$SyncVersion        = 'MT4-T-AUTOID-3.6-HOME-QUANT'
$CollectorStaleMinutes = 10
$MaxLogBytes = 10MB      # logs bigger than this are copied as their last 10 MB only
$script:cutLogs = @()

# Canonical-only policy: this script may write only under My Drive\MT4_Terminals.
# It must never mirror into the older MT4 RSI EA Data tree.
$CanonicalProjectLeaf = 'MT4_Terminals'

# Existing account -> research terminal mapping.
# Terminal_1 is intentionally left AUTO: if one unknown active account remains, it is assigned there.
# Terminal_2 (48733632) and Terminal_4 (48737190) are deliberately ABSENT.
# They run on the VPS and are owned by VPS-SyncToDrive.ps1. While HOME still
# listed them it could not discover them, so every HOME run stamped
# 'SOURCE NOT DISCOVERED' over the VPS profile's good status file - the two
# scripts fought over the same folders and last writer won.
$AccountMap = [ordered]@{
    '48735541' = 'Terminal_3'
    '48737170' = 'Terminal_5'
    '48745856' = 'Terminal_6'   # 2026-09-16: exact-mirror test account (old 48738769 retired with the Phase-1 pilot)
    '48752709' = 'Terminal_7'
    '48745453' = 'Terminal_8'
    '48754085' = 'Terminal_10'
    '48750213' = 'Terminal_99'
    '48741426' = 'Terminal_1'
    '48750176' = 'Terminal_18'
    '48747504' = 'Terminal_74'
    '7010264' = 'Terminal_fusion'
    '7010265' = 'Terminal_fusion2'
    '48747502' = 'Phase4--223'
    '7011221' = 'Terminal_fusion3'
    '48752374' = 'Terminal_20'
    '48753031' = 'Terminal_15'
    '1420790397' = 'ftmo-test1'
    '48753218' = 'Terminal_22'
     
}

# Prevent two copies of this HOME sync from running at the same time.
$mutexName = 'Global\MT4_Terminals_HOME_Sync_v34'
$createdNew = $false
$syncMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Output 'Another MT4_Terminals HOME sync instance is already running. Exiting.'
    exit 0
}

function Assert-CanonicalDestination([string]$Path, [string]$ProjectRoot) {
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "REFUSING NON-CANONICAL DESTINATION: $pathFull (allowed root: $rootFull)"
    }
}

function Find-DriveProjectRoot {
    $candidates = @(
        'I:\My Drive\MT4_Terminals',
        'G:\My Drive\MT4_Terminals',
        'H:\My Drive\MT4_Terminals',
        'D:\My Drive\MT4_Terminals'
    )
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }

    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $p = Join-Path $d.Root 'My Drive\MT4_Terminals'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "Could not find Google Drive project folder 'My Drive\\MT4_Terminals'."
}

function Get-AccountFromTerminalFolder([string]$DataPath) {
    $filesPath = Join-Path $DataPath 'MQL4\Files'
    if (-not (Test-Path -LiteralPath $filesPath)) { return $null }

    # Strongest identity: new AUTO-ID file.
    $id = Get-ChildItem -LiteralPath $filesPath -Filter 'GPT_MT4_TERMINAL_ID_*.txt' -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($id -and $id.BaseName -match 'GPT_MT4_TERMINAL_ID_(\d+)$') { return $Matches[1] }

    # QuantV2 identity fallback: files live one level deeper in MQL4\Files\GPT_REPORTS.
    $qPath = Join-Path $filesPath 'GPT_REPORTS'
    if (Test-Path -LiteralPath $qPath) {
        $q = Get-ChildItem -LiteralPath $qPath -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -ne '.tmp' -and $_.Name -match '_\d+_Quant[A-Za-z0-9]*_' } |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($q -and $q.Name -match '_(\d+)_Quant[A-Za-z0-9]*_') { return $Matches[1] }
    }

    # Immediate backward-compatible identity: Statement_<account>.csv.
    $st = Get-ChildItem -LiteralPath $filesPath -Filter 'Statement_*.csv' -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($st -and $st.BaseName -match '^Statement_(\d+)$') { return $Matches[1] }

    # Daily report also identifies account.
    $tr = Get-ChildItem -LiteralPath $filesPath -Filter 'Trades_*_????-??-??.csv' -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($tr -and $tr.Name -match '^Trades_(\d+)_') { return $Matches[1] }
    return $null
}

function Get-CollectorHealth([string]$ReportsDir, [string]$Logical, [string]$Acct) {
    if (-not (Test-Path -LiteralPath $ReportsDir)) { return $null }

    $st = Get-ChildItem -LiteralPath $ReportsDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like "*_${Logical}_${Acct}_Quant*_collector_status.txt" } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $st) { return $null }

    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $st.FullName -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z_ ]*?)\s*:\s*(.+?)\s*$') { $h[$Matches[1].Trim()] = $Matches[2].Trim() }
    }

    $updated = $null
    if ($h.ContainsKey('Updated')) {
        try { $updated = [datetime]::ParseExact($h['Updated'],'yyyy.MM.dd HH:mm:ss',$null) } catch { $updated = $null }
    }

    [pscustomobject]@{
        File          = $st.Name
        Version       = $(if ($st.Name -match '_(Quant[A-Za-z0-9]*)_') { $Matches[1] } else { 'unknown' })
        Updated       = $updated
        AgeMinutes    = $(if ($updated) { [math]::Round(((Get-Date) - $updated).TotalMinutes,1) } else { $null })
        RunId         = $h['run_id']
        SinceLastPoll = $h['seconds_since_last_poll']
        Stalls        = $h['timer_stalls_detected']
        Tracked       = $h['Tracked tickets']
        ClosedRows    = $h['Closed rows remembered']
        DataPath      = $h['terminal_data_path']
        Connected     = $h['connected']
    }
}

function Test-CsvTrailer([string]$Path) {
    try {
        $last = Get-Content -LiteralPath $Path -Tail 1 -ErrorAction Stop
        return (([string]$last).TrimStart('"').StartsWith('#END'))
    } catch { return $false }
}

function Copy-Verified([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { return $null }
    Assert-CanonicalDestination $Destination $script:projectRoot
    $destDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $len = 0; try { $len = (Get-Item -LiteralPath $Source -ErrorAction Stop).Length } catch { return $null }
    if ($Source -like '*.log' -and $len -gt $MaxLogBytes) {
        # v3.6: a runaway log can be gigabytes. Copy only its last $MaxLogBytes (MT4 logs are UTF-16: start on a character).
        try {
            $in = [System.IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite,Delete')
            try {
                $start = [long]($in.Length - $MaxLogBytes); if ($start % 2 -ne 0) { $start-- }
                [void]$in.Seek($start, 'Begin')
                $out = [System.IO.File]::Create($Destination)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
        } catch { return $null }
        $s = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
        $d = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
        if (-not $s -or -not $d) { return $null }
        $script:cutLogs += $Source
        return [pscustomobject]@{
            Source=$Source; Destination=$Destination; SourceBytes=$d.Length; DestinationBytes=$d.Length
            SourceWrite=$s.LastWriteTime; DestinationWrite=$d.LastWriteTime; Match=$true
        }
    }
    try { cmd /c copy /y /b "$Source" "$Destination" | Out-Null } catch { return $null }
    $s = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
    $d = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
    if (-not $s -or -not $d) { return $null }
    [pscustomobject]@{
        Source=$Source; Destination=$Destination
        SourceBytes=$s.Length; DestinationBytes=$d.Length
        SourceWrite=$s.LastWriteTime; DestinationWrite=$d.LastWriteTime
        Match=($s.Length -eq $d.Length)
    }
}

$runStart = Get-Date
$projectRoot = Find-DriveProjectRoot
if ((Split-Path -Leaf $projectRoot) -ne $CanonicalProjectLeaf) { throw "Unexpected project root: $projectRoot" }
$metaRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (-not (Test-Path -LiteralPath $metaRoot)) { throw "MetaQuotes Terminal root not found: $metaRoot" }

# Discover every actual MT4 data folder by its current account identity.
$discovered = @()
Get-ChildItem -LiteralPath $metaRoot -Directory -ErrorAction Stop | ForEach-Object {
    $dp = $_.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $dp 'MQL4'))) { return }
    $acct = Get-AccountFromTerminalFolder $dp
    if ($acct) {
        $discovered += [pscustomobject]@{ Account=$acct; DataPath=$dp; Hash=$_.Name }
    }
}

# If duplicate account folders exist, choose the one with the freshest local identity/report/log activity.
$active = @{}
foreach ($g in ($discovered | Group-Object Account)) {
    $best = $null; $bestTime = [datetime]::MinValue
    foreach ($x in $g.Group) {
        $times = @()
        foreach ($p in @(
            (Join-Path $x.DataPath 'MQL4\Files'),
            (Join-Path $x.DataPath 'MQL4\Logs'),
            (Join-Path $x.DataPath 'logs')
        )) {
            if (Test-Path -LiteralPath $p) {
                $f = Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($f) { $times += $f.LastWriteTime }
            }
        }
        $t = if ($times.Count) { ($times | Sort-Object -Descending | Select-Object -First 1) } else { [datetime]::MinValue }
        if ($t -gt $bestTime) { $bestTime=$t; $best=$x }
    }
    if ($best) { $active[$g.Name] = $best }
}

# Terminal_1 auto-assign is OFF. Terminal_1 is not in testing, and silently
# adopting an unknown active account - possibly a personal or live one - into
# the research tree is not a safe default. Set to $true only deliberately.
$EnableTerminal1AutoAssign = $false
if ($EnableTerminal1AutoAssign) {
    $unknown = @($active.Keys | Where-Object { -not $AccountMap.Contains($_) })
    if ($unknown.Count -eq 1) {
        Write-Output "AUTO-ASSIGN: account $($unknown[0]) -> Terminal_1"
        $AccountMap[$unknown[0]] = 'Terminal_1'
    }
}

$allStatus = @()
foreach ($acct in $AccountMap.Keys) {
    $logical = $AccountMap[$acct]
    $destRoot = Join-Path $projectRoot $logical
    New-Item -ItemType Directory -Force -Path (Join-Path $destRoot 'Reports'),(Join-Path $destRoot 'Experts'),(Join-Path $destRoot 'Journal') | Out-Null

    if (-not $active.ContainsKey($acct)) {
        $status = @(
            "AutoSync version: $SyncVersion",
            "Logical terminal: $logical",
            "Expected account: $acct",
            "Run started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))",
            'STATUS: SOURCE NOT DISCOVERED',
            'Hint: attach HistoryExporter_AUTOID_v2 once, or ensure Statement_<account>.csv exists in MQL4\\Files.'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $destRoot '_sync_status.txt') -Value $status -Encoding UTF8
        $allStatus += "$logical account=$acct SOURCE_NOT_DISCOVERED"
        continue
    }

    $src = $active[$acct].DataPath
    $results = @()
    $script:cutLogs = @()

    # Reports: main statement + recent daily files + identity/status.
    $filesPath = Join-Path $src 'MQL4\Files'
    foreach ($f in (Get-ChildItem -LiteralPath $filesPath -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "Statement_$acct.csv" -or
        $_.Name -like "Trades_${acct}_*.csv" -or
        $_.Name -like 'GPT_MT4_TERMINAL_ID_*.txt' -or
        $_.Name -like 'GPT_MT4_EXPORTER_STATUS_*.txt'
    })) {
        if ($f.Name -like 'Trades_*' -and $f.LastWriteTime -lt (Get-Date).AddDays(-$LookbackDays)) { continue }
        $results += Copy-Verified $f.FullName (Join-Path (Join-Path $destRoot 'Reports') $f.Name)
    }

    # QuantV2 reports/state: collector writes these under MQL4\Files\GPT_REPORTS.
    # Match BOTH logical terminal and account so stale/mislabelled files cannot leak
    # into another terminal's Drive folder.
    $quantPath = Join-Path $filesPath 'GPT_REPORTS'
    if (Test-Path -LiteralPath $quantPath) {
        # Tag-agnostic: matches QuantV2, QuantV201 ... QuantV204 and later.
        # .tmp files are the collector's in-progress atomic writes and must NEVER
        # be copied - doing so republishes exactly the partial files that the
        # atomic write was introduced to eliminate.
        $quantPattern = "*_${logical}_${acct}_Quant*"
        foreach ($f in (Get-ChildItem -LiteralPath $quantPath -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -like $quantPattern -and $_.Extension -ne '.tmp' })) {
            $results += Copy-Verified $f.FullName (Join-Path (Join-Path $destRoot 'Reports') $f.Name)
        }
    }

    # Today + recent Journal/Experts logs. Use actual discovered terminal data path.
    $cut = (Get-Date).AddDays(-$LookbackDays)
    foreach ($spec in @(
        @{Src=(Join-Path $src 'MQL4\Logs'); Dst=(Join-Path $destRoot 'Experts')},
        @{Src=(Join-Path $src 'logs');       Dst=(Join-Path $destRoot 'Journal')}
    )) {
        if (Test-Path -LiteralPath $spec.Src) {
            foreach ($f in (Get-ChildItem -LiteralPath $spec.Src -Filter '*.log' -File -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -ge $cut})) {
                $results += Copy-Verified $f.FullName (Join-Path $spec.Dst $f.Name)
            }
        }
    }

    # Copy-Verified returns $null when a source vanishes mid-run; without this
    # the null lands in the array and inflates "Files copied/verified".
    $results = @($results | Where-Object { $_ -ne $null })

    $bad = @($results | Where-Object { -not $_.Match })
    # Was '*\\Experts\\*' (two literal backslashes) - never matched, so the
    # Latest-* diagnostic lines were silently absent from every status file.
    $latestExperts = $results | Where-Object {$_.Destination -like '*\Experts\*'} | Sort-Object SourceWrite -Descending | Select-Object -First 1
    # Only MT4 date journals (YYYYMMDD.log). Without this, metaeditor.log - which
    # lives in the same folder and is written constantly - wins on recency and the
    # diagnostic reports the wrong file.
    $latestJournal = $results |
        Where-Object {$_.Destination -like '*\Journal\*' -and
                      [System.IO.Path]::GetFileName($_.Destination) -match '^\d{8}\.log$'} |
        Sort-Object SourceWrite -Descending | Select-Object -First 1
    $latestReport  = $results | Where-Object {$_.Destination -like '*\Reports\*'} | Sort-Object SourceWrite -Descending | Select-Object -First 1

    $lines = @(
        "AutoSync version: $SyncVersion",
        "Machine: $env:COMPUTERNAME",
        "Sync profile: $MachineLabel",
        "Logical terminal: $logical",
        "Account: $acct",
        "Terminal hash: $($active[$acct].Hash)",
        "Detected data path: $src",
        "Run started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))",
        "Run finished: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
        "Files copied/verified: $(@($results).Count)",
        "Size mismatches: $($bad.Count)"
    )
    if (@($script:cutLogs).Count) { $lines += "Logs shortened to the last $([int]($MaxLogBytes / 1MB)) MB: $(@($script:cutLogs).Count)" }
    if ($latestExperts) { $lines += "Latest Experts source: $($latestExperts.Source) | bytes=$($latestExperts.SourceBytes) | write=$($latestExperts.SourceWrite.ToString('yyyy-MM-dd HH:mm:ss')) | destinationBytes=$($latestExperts.DestinationBytes)" }
    if ($latestJournal) { $lines += "Latest Journal source: $($latestJournal.Source) | bytes=$($latestJournal.SourceBytes) | write=$($latestJournal.SourceWrite.ToString('yyyy-MM-dd HH:mm:ss')) | destinationBytes=$($latestJournal.DestinationBytes)" }
    if ($latestReport)  { $lines += "Latest Report source: $($latestReport.Source) | bytes=$($latestReport.SourceBytes) | write=$($latestReport.SourceWrite.ToString('yyyy-MM-dd HH:mm:ss')) | destinationBytes=$($latestReport.DestinationBytes)" }
    # ---- Collector liveness, read from the file the collector itself wrote ----
    # A stalled collector still gets its Drive mtime refreshed by this very copy,
    # so freshness must be judged from CONTENT. Terminal_4 sat frozen for 45
    # minutes on 26 Aug while looking perfectly healthy in Drive.
    $health = Get-CollectorHealth (Join-Path $destRoot 'Reports') $logical $acct
    $collectorProblem = $false

    if ($health) {
        $lines += "Collector build: $($health.Version)"
        $lines += "Collector updated: $(if ($health.Updated) { $health.Updated.ToString('yyyy-MM-dd HH:mm:ss') } else { 'UNPARSED' })"
        $lines += "Collector age minutes: $($health.AgeMinutes)"
        $lines += "Collector run_id: $($health.RunId)"
        $lines += "Collector tracked tickets: $($health.Tracked)"
        $lines += "Collector closed rows: $($health.ClosedRows)"
        if ($health.SinceLastPoll) { $lines += "Collector seconds since last poll: $($health.SinceLastPoll)" }
        if ($health.Stalls)        { $lines += "Collector timer stalls: $($health.Stalls)" }
        if ($health.Connected)     { $lines += "Collector connected: $($health.Connected)" }

        if ($health.AgeMinutes -ne $null -and $health.AgeMinutes -gt $CollectorStaleMinutes) {
            $lines += "COLLECTOR WARNING: status is $($health.AgeMinutes) min old (threshold $CollectorStaleMinutes) - collector may have stalled"
            $collectorProblem = $true
        }

        # Cross-check the collector's self-declared data path against the folder
        # this script discovered. A mismatch means the label is pointed at the
        # wrong terminal - the failure mode behind the T2/T4 confusion.
        if ($health.DataPath -and ($health.DataPath.TrimEnd('\') -ne $src.TrimEnd('\'))) {
            $lines += "COLLECTOR WARNING: identity mismatch. collector says '$($health.DataPath)' but sync discovered '$src'"
            $collectorProblem = $true
        }
    } else {
        $lines += 'Collector status: NOT FOUND (QuantV2xx collector not attached, or not yet written)'
    }

    # ---- Completion-trailer verification on atomically published CSVs ----
    # v2.04 ends every full-rewrite CSV with #END. Missing trailer means the file
    # is truncated - either a partial write or a partial copy.
    # Only v2.04 and later emit #END. Checking older collectors would warn on
    # every terminal, and a warning that is always on is a warning nobody reads.
    $trailerBad     = @()
    $trailerChecked = 0
    foreach ($tf in (Get-ChildItem -LiteralPath (Join-Path $destRoot 'Reports') -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "*_${logical}_${acct}_Quant*" -and
                                    ($_.Name -like '*_active_state.csv' -or
                                     $_.Name -like '*_open_now.csv' -or
                                     $_.Name -like '*_basket_state.csv') })) {
        $capable = $false
        if ($tf.Name -match '_QuantV2(\d+)_') { $capable = ([int]$Matches[1] -ge 4) }
        if (-not $capable) { continue }

        $trailerChecked++
        if (-not (Test-CsvTrailer $tf.FullName)) { $trailerBad += $tf.Name }
    }
    if ($trailerBad.Count -gt 0) {
        $lines += "TRAILER WARNING: incomplete file(s): $($trailerBad -join ', ')"
        $collectorProblem = $true
    } elseif ($trailerChecked -gt 0) {
        $lines += "Trailer check: OK ($trailerChecked files)"
    } else {
        $lines += 'Trailer check: n/a (collector predates #END trailers)'
    }

    $lines += if ($bad.Count -ne 0)   {'STATUS: COPY SIZE MISMATCH'}
              elseif ($collectorProblem) {'STATUS: OK (COLLECTOR WARNING)'}
              else                     {'STATUS: OK'}
    Set-Content -LiteralPath (Join-Path $destRoot '_sync_status.txt') -Value ($lines -join "`r`n") -Encoding UTF8
    $allStatus += "$logical account=$acct hash=$($active[$acct].Hash) copied=$(@($results).Count) mismatches=$($bad.Count)"
}

# Project-wide heartbeat / identity map for remote diagnosis.
$heartbeat = @(
    "AutoSync version: $SyncVersion",
    "Machine: $env:COMPUTERNAME",
        "Sync profile: $MachineLabel",
    "Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
    "Project: $projectRoot",
    "Destination policy: CANONICAL ONLY",
    "Discovered account folders: $($active.Count)",
    ''
) + $allStatus
# Profile-scoped: HOME and VPS must not overwrite each other's fleet heartbeat.
Set-Content -LiteralPath (Join-Path $projectRoot '_sync_status_HOME.txt') -Value ($heartbeat -join "`r`n") -Encoding UTF8

$mapLines = @('MT4_Terminals AUTO-ID map (HOME profile only)', "Updated=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))", '')
foreach ($acct in $active.Keys | Sort-Object) {
    $logical = if ($AccountMap.Contains($acct)) {$AccountMap[$acct]} else {'UNMAPPED'}
    $mapLines += "$logical | account=$acct | hash=$($active[$acct].Hash) | data=$($active[$acct].DataPath)"
}
Set-Content -LiteralPath (Join-Path $projectRoot '_terminal_identity_map_HOME.txt') -Value ($mapLines -join "`r`n") -Encoding UTF8

# Release single-instance lock.
if ($syncMutex) { try { $syncMutex.ReleaseMutex() } catch {} ; $syncMutex.Dispose() }
