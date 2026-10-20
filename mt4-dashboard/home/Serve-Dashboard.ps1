<#
  Local web server for the MT4 Dashboard on a PC that has Google Drive for desktop (no Claude needed).
  It serves index.html on http://127.0.0.1:8765/ and gives the page read access to the two folders it needs
  (MT4_Terminals\_DASHBOARD and MT4_Terminals\_DASHBOARD_BUILD) plus permission to drop a BUILD_NOW_*.txt file
  into _DASHBOARD_BUILD (the Build now button). It listens on this PC only (127.0.0.1) and writes nothing else.
  Started hidden by START_SERVER.vbs; OPEN_DASHBOARD.bat starts it for you.
#>
param([int]$Port = 8765, [string]$Root = '')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$isNix = ($IsLinux -or $IsMacOS)

$own = $false
$single = New-Object System.Threading.Mutex($false, $(if ($isNix) { 'MT4DashboardLocalServer' } else { 'Global\MT4DashboardLocalServer' }))
try { $own = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
if (-not $own) { exit 0 }

function Find-Root {
  $f = Join-Path $here 'root.txt'
  if (Test-Path -LiteralPath $f) { $p = (Get-Content -LiteralPath $f | Select-Object -First 1).Trim().Trim('"'); if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  foreach ($p in @('I:\My Drive\MT4_Terminals', 'G:\My Drive\MT4_Terminals', 'H:\My Drive\MT4_Terminals', 'D:\My Drive\MT4_Terminals')) { if (Test-Path -LiteralPath $p) { return $p } }
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) { $p = Join-Path $d.Root 'My Drive\MT4_Terminals'; if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}
if (-not $Root) { $Root = Find-Root }
$Allowed = @('_DASHBOARD', '_DASHBOARD_BUILD')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8' }

function Send([System.Net.HttpListenerResponse]$res, [int]$code, [byte[]]$bytes, [string]$type) {
  $res.StatusCode = $code; $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function SendText($res, [int]$code, [string]$text, [string]$type = 'text/plain; charset=utf-8') { Send $res $code $utf8.GetBytes($text) $type }
function Read-Shared([string]$path) {
  $fs = New-Object System.IO.FileStream($path, 'Open', 'Read', 'ReadWrite,Delete')
  try { $ms = New-Object System.IO.MemoryStream; $fs.CopyTo($ms); return $ms.ToArray() } finally { $fs.Dispose() }
}
# "_DASHBOARD/name.ext": only the two allowed folders, a plain file name
function Resolve-Item([string]$rel) {
  if (-not $Root -or -not $rel) { return $null }
  $parts = $rel -split '/'
  if ($parts.Count -ne 2 -or $Allowed -notcontains $parts[0] -or $parts[1] -match '[\\/:*?"<>|]' -or $parts[1] -match '^\.+$') { return $null }
  return [pscustomobject]@{ Dir = $parts[0]; Name = $parts[1]; Path = (Join-Path (Join-Path $Root $parts[0]) $parts[1]) }
}

# 127.0.0.1 first; some Windows setups only allow localhost without administrator rights
$listener = $null; $urlFile = Join-Path $here 'server_url.txt'; $lastErr = ''
foreach ($h in @('127.0.0.1', 'localhost')) {
  try {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://${h}:$Port/")
    $l.Start()
    $listener = $l
    [System.IO.File]::WriteAllText($urlFile, "http://${h}:$Port/", $utf8)
    break
  } catch { $lastErr = $_.Exception.Message }
}
if (-not $listener) { [System.IO.File]::WriteAllText($urlFile, 'ERROR ' + $lastErr, $utf8); exit 1 }
while ($listener.IsListening) {
  $ctx = $listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
  try {
    $hostOk = ($req.Headers['Host'] -in @("127.0.0.1:$Port", "localhost:$Port"))
    $path = $req.Url.AbsolutePath
    if (-not $hostOk) { SendText $res 403 'forbidden' }
    elseif ($path -eq '/' -or $path -eq '/index.html') {
      $idx = Join-Path $here 'index.html'
      $html = $utf8.GetString((Read-Shared $idx))
      $at = $html.IndexOf('<head>'); if ($at -ge 0) { $html = $html.Insert($at + 6, '<script src="/shim.js"></script>') }
      SendText $res 200 $html 'text/html; charset=utf-8'
    }
    elseif ($path -eq '/shim.js') { Send $res 200 (Read-Shared (Join-Path $here 'dashboard-shim.js')) $mime['.js'] }
    elseif ($path -eq '/fs/info') { SendText $res 200 (@{ root = $Root; found = [bool]$Root } | ConvertTo-Json -Compress) $mime['.json'] }
    elseif ($path -eq '/fs/list') {
      $d = $req.QueryString['dir']
      if (-not $Root -or $Allowed -notcontains $d) { SendText $res 404 '[]' $mime['.json'] }
      else {
        $dir = Join-Path $Root $d
        $items = @(); if (Test-Path -LiteralPath $dir) {
          $items = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = $_.Name; mtime = $_.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); size = $_.Length } })
        }
        SendText $res 200 (ConvertTo-Json -InputObject @($items) -Compress) $mime['.json']
      }
    }
    elseif ($path -eq '/fs/read') {
      $it = Resolve-Item $req.QueryString['path']
      if (-not $it -or -not (Test-Path -LiteralPath $it.Path)) { SendText $res 404 'not found' }
      else { Send $res 200 (Read-Shared $it.Path) 'application/octet-stream' }
    }
    elseif ($path -eq '/fs/write' -and $req.HttpMethod -eq 'POST' -and $req.Headers['X-Dash'] -eq '1') {
      $it = Resolve-Item $req.QueryString['path']
      if (-not $it -or $it.Dir -ne '_DASHBOARD_BUILD' -or $it.Name -notmatch '^BUILD_NOW[A-Za-z0-9_.-]*\.txt$') { SendText $res 403 'not allowed' }
      else {
        $sr = New-Object System.IO.StreamReader($req.InputStream, $utf8); $body = $sr.ReadToEnd(); if ($body.Length -gt 2000) { $body = $body.Substring(0, 2000) }
        [System.IO.File]::WriteAllText($it.Path, $body, $utf8)
        SendText $res 200 (@{ id = ($it.Dir + '/' + $it.Name); title = $it.Name } | ConvertTo-Json -Compress) $mime['.json']
      }
    }
    else { SendText $res 404 'not found' }
  } catch { try { SendText $res 500 ('error: ' + $_.Exception.Message) } catch { } }
  finally { try { $res.Close() } catch { } }
}
