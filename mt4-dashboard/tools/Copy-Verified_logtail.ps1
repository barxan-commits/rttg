# Replacement for the function Copy-Verified in SyncToDrive.ps1 (HOME) and VPS-SyncToDrive.ps1 (VPS).
# A *.log bigger than $MaxLogBytes (a runaway EA can write gigabytes) is copied as its LAST $MaxLogBytes only.
# Put this line near the top of the script, with the other settings:
#     $MaxLogBytes = 10MB
function Copy-Verified([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { return $null }
    Assert-CanonicalDestination $Destination $script:projectRoot
    $destDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $len = 0; try { $len = (Get-Item -LiteralPath $Source -ErrorAction Stop).Length } catch { return $null }
    if ($Source -like '*.log' -and $len -gt $MaxLogBytes) {
        try {
            $in = [System.IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite,Delete')
            try {
                $start = [long]($in.Length - $MaxLogBytes); if ($start % 2 -ne 0) { $start-- }   # MT4 logs are UTF-16: stay on a character
                [void]$in.Seek($start, 'Begin')
                $out = [System.IO.File]::Create($Destination)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
        } catch { return $null }
        $s = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
        $d = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
        if (-not $s -or -not $d) { return $null }
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
