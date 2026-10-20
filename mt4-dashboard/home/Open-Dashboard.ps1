# Starts the local dashboard server (hidden) and opens the dashboard in Edge. Called by OPEN_DASHBOARD.bat.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
try { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*Serve-Dashboard.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch { }
$urlFile = Join-Path $here 'server_url.txt'
Remove-Item -LiteralPath $urlFile -Force -ErrorAction SilentlyContinue
Start-Process -FilePath 'wscript.exe' -ArgumentList @('//B', '//Nologo', ('"' + (Join-Path $here 'START_SERVER.vbs') + '"'))
$url = ''
for ($i = 0; $i -lt 20 -and -not $url; $i++) {
  Start-Sleep -Milliseconds 700
  if (Test-Path -LiteralPath $urlFile) { $url = (Get-Content -LiteralPath $urlFile -ErrorAction SilentlyContinue | Select-Object -First 1) }
}
if ($url -and $url -like 'http*') {
  try { Start-Process -FilePath 'msedge' -ArgumentList $url } catch { Start-Process $url }
} else {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show("The local dashboard server did not start.`r`n$url`r`nCheck that Google Drive for desktop is running and that Serve-Dashboard.ps1 is in this folder, then try again.", 'MT4 Dashboard') | Out-Null
}
