# Restore-Terminals.ps1  -  rebuild the backed-up MetaTrader 4 terminals on a NEW machine (made by Backup-ActiveTerminals.ps1)
# Windows PowerShell 5.1 compatible. Run it from inside the copied backup folder (or pass -BackupDir).
#
# Each terminal is restored as a PORTABLE install: program + data in ONE folder, started with  terminal.exe /portable .
# This avoids the hash folder name MT4 builds from the install path, so it works on any drive layout.
#
#   .\Restore-Terminals.ps1 -Verify                          check the copied files against FILES.sha256 only
#   .\Restore-Terminals.ps1 -ListOnly                        show what would be restored, change nothing
#   .\Restore-Terminals.ps1 -InstallRoot C:\MT4_Terminals    restore everything there (default)
#   .\Restore-Terminals.ps1 -Only T01_48754085               restore one terminal only
#   .\Restore-Terminals.ps1 -ImportTasks                     also re-create the exported scheduled tasks (review them first!)
[CmdletBinding()]
param(
    [string]$BackupDir = '',
    [string]$InstallRoot = 'C:\MT4_Terminals',
    [string[]]$Only = @(),
    [switch]$Verify,
    [switch]$ListOnly,
    [switch]$ImportTasks,
    [switch]$NoShortcuts,
    [switch]$Overwrite                       # allow writing into a folder that already exists
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $BackupDir) { $BackupDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
$manFile = Join-Path $BackupDir 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manFile)) { throw "MANIFEST.json not found in $BackupDir. Run this from inside the backup folder." }
$man = Get-Content -LiteralPath $manFile -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "Backup made $($man.Created) on $($man.Machine): $(@($man.Terminals).Count) terminal(s)"

# ---------- verify ----------
if ($Verify) {
    $sum = Join-Path $BackupDir 'FILES.sha256'
    if (-not (Test-Path -LiteralPath $sum)) { throw 'FILES.sha256 is missing.' }
    $bad = 0; $n = 0
    foreach ($line in (Get-Content -LiteralPath $sum -Encoding UTF8)) {
        if ($line.Length -lt 70) { continue }
        $hash = $line.Substring(0, 64); $rel = $line.Substring(66)
        $full = Join-Path $BackupDir $rel; $n++
        if (-not (Test-Path -LiteralPath $full)) { Write-Warning "MISSING  $rel"; $bad++; continue }
        $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($h -ne $hash) { Write-Warning "CHANGED  $rel"; $bad++ }
    }
    if ($bad) { Write-Host "$bad of $n files differ or are missing. Copy the backup again." -ForegroundColor Red; exit 2 }
    Write-Host "All $n files match FILES.sha256." -ForegroundColor Green; return
}

$list = @($man.Terminals)
if ($Only.Count) { $list = @($list | Where-Object { $Only -contains $_.Label -or $Only -contains $_.Account }) }
if (-not $list.Count) { throw 'No terminal selected.' }

# ---------- plan ----------
$need = 0
foreach ($t in $list) { $need += [double]$t.SizeMB }
$rootDrive = Split-Path -Qualifier $InstallRoot
if (-not $rootDrive) { $rootDrive = 'C:' }
$free = 0; try { $free = (Get-PSDrive -Name $rootDrive.TrimEnd(':') -ErrorAction Stop).Free / 1MB } catch { }
Write-Host ''
Write-Host "Restore to: $InstallRoot   (needs about $([math]::Round($need)) MB, free $([math]::Round($free)) MB)"
foreach ($t in $list) { Write-Host ("  {0,-16} account {1,-12} {2,8} MB   program in backup: {3}   was running when copied: {4}" -f $t.Label, $t.Account, $t.SizeMB, $t.ProgramIncluded, $t.RunningWhenCopied) }
if ($free -and $free -lt $need * 1.1) { throw 'Not enough free disk space.' }
if ($ListOnly) { Write-Host 'ListOnly: nothing changed.'; return }
if (Get-Process terminal -ErrorAction SilentlyContinue) { Write-Warning 'MT4 terminals are running on this machine. Close them first if they use the same folders.' }

function Robo([string]$src, [string]$dst) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    & robocopy $src $dst /E /COPY:DAT /DCOPY:T /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP /MT:8 | Out-Null
    return $LASTEXITCODE
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$made = @(); $dataPaths = @(); $missingProgram = @()
foreach ($t in $list) {
    $src = Join-Path $BackupDir $t.Label
    $dst = Join-Path $InstallRoot $t.Label
    if ((Test-Path -LiteralPath $dst) -and -not $Overwrite) { Write-Warning "$dst already exists: skipped (use -Overwrite to write into it)."; continue }
    Write-Host ''
    Write-Host "Restoring $($t.Label) -> $dst"
    $prog = Join-Path $src 'program'
    if (Test-Path -LiteralPath $prog) { $c = Robo $prog $dst; if ($c -ge 8) { Write-Warning "program copy reported problems (robocopy $c)" } }
    else { $missingProgram += $t.Label; New-Item -ItemType Directory -Force -Path $dst | Out-Null }
    $c = Robo (Join-Path $src 'data') $dst; if ($c -ge 8) { Write-Warning "data copy reported problems (robocopy $c)" }
    # portable marker: MT4 starts in portable mode with the /portable switch; nothing else is required
    $exe = Join-Path $dst 'terminal.exe'
    $made += [pscustomobject]@{ Label = $t.Label; Account = $t.Account; Dir = $dst; Exe = $exe; HasExe = (Test-Path -LiteralPath $exe) }
    $dataPaths += $dst
}

# ---------- shortcuts ----------
if (-not $NoShortcuts) {
    try {
        $sh = New-Object -ComObject WScript.Shell
        $desk = [Environment]::GetFolderPath('Desktop'); $folder = Join-Path $desk 'MT4 terminals'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        foreach ($m in ($made | Where-Object HasExe)) {
            $l = $sh.CreateShortcut((Join-Path $folder ("MT4 " + $m.Label + ".lnk")))
            $l.TargetPath = $m.Exe; $l.Arguments = '/portable'; $l.WorkingDirectory = $m.Dir; $l.Save()
        }
        Write-Host "Shortcuts: $folder  (each starts terminal.exe /portable)"
    } catch { Write-Warning "Shortcuts not created: $($_.Exception.Message)" }
}

# ---------- scheduled tasks (only on request) ----------
$tasksDir = Join-Path $BackupDir '_SYSTEM\scheduled_tasks'
if ($ImportTasks -and (Test-Path -LiteralPath $tasksDir)) {
    foreach ($x in (Get-ChildItem -LiteralPath $tasksDir -Filter '*.xml')) {
        try { & schtasks.exe /Create /TN ([IO.Path]::GetFileNameWithoutExtension($x.Name)) /XML $x.FullName /F | Out-Null; Write-Host "Task imported: $($x.BaseName)  (check its paths: they point at the OLD machine's folders)" }
        catch { Write-Warning "Task $($x.Name) not imported: $($_.Exception.Message)" }
    }
} elseif (Test-Path -LiteralPath $tasksDir) {
    Write-Host "Scheduled tasks were exported to $tasksDir. They are NOT imported unless you run with -ImportTasks (paths inside may point at the old machine)."
}
@("# Portable MT4 data folders restored on $env:COMPUTERNAME", "# Put these into `$ExtraDataPaths in VPS-SyncToDrive_v37.ps1 / the dashboard collector scripts:") + ($dataPaths | ForEach-Object { "'$_'," }) |
    Set-Content -LiteralPath (Join-Path $InstallRoot 'EXTRA_DATA_PATHS.txt') -Encoding UTF8

Write-Host ''
Write-Host 'DONE.' -ForegroundColor Green
if ($missingProgram.Count) { Write-Warning ("No program folder in the backup for: " + ($missingProgram -join ', ') + ". Install MetaTrader 4 (broker version), copy its files into the folder shown above, then start it with /portable.") }
Write-Host 'Next: start each terminal from the shortcuts, log in to its broker account, check the EAs are on the charts and AutoTrading is ON.'
Write-Host "Portable data folders are listed in $InstallRoot\EXTRA_DATA_PATHS.txt (for the Drive sync / dashboard collector)."
