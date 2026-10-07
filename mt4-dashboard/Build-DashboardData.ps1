<#
.SYNOPSIS
  Builds compact, gzip-compressed copies of MT4Collector_Quant data and MT4
  logs for the online MT4 Dashboard.

.DESCRIPTION
  Reads (never modifies) everything under ProjectRoot and writes only into
  OutDir (default <ProjectRoot>\_DASHBOARD):

    trades_<account>_<yyyy-MM>[_pN].csv.gz   closed trades, deduplicated by
                                             account + ticket (newest collector
                                             version wins)
    open_now.csv.gz                          open positions, newest file per account
    equity_<account>.csv.gz                  balance/equity per N minutes, with the
                                             lowest/highest equity inside each slot
    health_events.csv.gz                     EA errors, warnings and activity from
                                             the Experts and Journal logs
    status_all.txt                           all collector status files
    sync_all.txt                             AutoSync status and identity-map files
    mt4dash_manifest.json                    build time and file list

  Files are rewritten only when their content changed, so Google Drive only
  syncs what is new. Each file stays far below the size the Google Drive
  connector can pass to the dashboard page.

  Run it on ONE machine only (the VPS is best: it is always on), e.g. every
  10 minutes with Task Scheduler. Works with Windows PowerShell 5.1 and 7.

  Automatic build: put this script in MT4_Terminals\_DASHBOARD_BUILD on Google
  Drive and run INSTALL_AUTO_UPDATE.bat from there once on the build PC. It
  writes BUILD_PC.txt (other PCs then skip the build), and every run writes
  last_build_<PC>.txt next to this script.

  More folders (e.g. another EA's terminals): -ExtraFolders, or one per line in
  EXTRA_FOLDERS.txt next to this script. A folder can be one terminal (it has
  Reports, Experts or Journal inside) or a folder of terminals.
#>
[CmdletBinding()]
param(
  # default: the parent folder when this script is in MT4_Terminals\_DASHBOARD_BUILD,
  # otherwise I:\My Drive\MT4_Terminals
  [string]$ProjectRoot = '',
  [string]$OutDir = '',
  [ValidateRange(1, 240)]
  [int]$EquityMinutes = 15,
  [ValidateRange(1000, 100000)]
  [int]$MaxRowsPerFile = 10000,
  [ValidateRange(1, 30)]
  [int]$LogDays = 3,
  [string[]]$Exclude = @('ARCHIVE', '_DASHBOARD', '_MASTER', 'mastergpt'),
  # more data folders; a relative path is taken inside the folder that holds ProjectRoot (My Drive)
  [string[]]$ExtraFolders = @(),
  # build even when BUILD_PC.txt names another PC
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BuilderVersion = '2026-10-08'
$pc = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
$here = $PSScriptRoot
$runLog = if ($here) { Join-Path $here ('last_build_' + $pc + '.txt') } else { '' }
$started = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$timing = New-Object System.Collections.Generic.List[string]
function Add-Timing([string]$Step) { $timing.Add(('{0} {1:n0}s' -f $Step, $sw.Elapsed.TotalSeconds)); $sw.Reset(); $sw.Start() }

# every run leaves a short note next to the script, so a failing scheduled run is visible on Drive
function Write-RunLog([string]$Result, [string[]]$More) {
  if (-not $runLog) { return }
  $lines = @(
    ('MT4 Dashboard build on ' + $pc),
    ('Started:  ' + $started.ToString('yyyy-MM-dd HH:mm:ss')),
    ('Finished: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
    ('Result:   ' + $Result),
    ('Project:  ' + $ProjectRoot),
    ('Builder:  ' + $BuilderVersion)) + @($More)
  try { [System.IO.File]::WriteAllText($runLog, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
}
trap {
  Write-RunLog ('FAILED - ' + $_.Exception.Message) @($_.InvocationInfo.PositionMessage)
  break
}

# only one PC builds: the one named in BUILD_PC.txt (written by INSTALL_AUTO_UPDATE.bat)
$buildPcFile = if ($here) { Join-Path $here 'BUILD_PC.txt' } else { '' }
if (-not $Force -and $buildPcFile -and (Test-Path -LiteralPath $buildPcFile)) {
  $buildPc = @(Get-Content -LiteralPath $buildPcFile | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
  if ($buildPc -and $buildPc -ine $pc) {
    Write-Host ('Skipped: the dashboard data is built on {0} (BUILD_PC.txt), not on {1}. Run INSTALL_AUTO_UPDATE.bat here to move the build to this PC.' -f $buildPc, $pc)
    exit 0
  }
}
# scheduled runs (AUTO_BUILD.vbs passes -NonInteractive) leave the PC idle at least twice as long as
# the last build took, so a slow build never keeps the VPS busy more than about a third of the time
$scheduled = @([Environment]::GetCommandLineArgs() | Where-Object { $_ -ieq '-NonInteractive' }).Count -gt 0
if ($scheduled -and -not $Force -and $runLog -and (Test-Path -LiteralPath $runLog)) {
  $prev = @{}
  foreach ($l in @(Get-Content -LiteralPath $runLog -TotalCount 8)) { if ($l -match '^(Started|Finished|Result):\s+(.*)$') { $prev[$Matches[1]] = $Matches[2].Trim() } }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $s0 = [datetime]::MinValue; $f0 = [datetime]::MinValue
  if ([string]$prev['Result'] -like 'OK*' -and
      [datetime]::TryParseExact([string]$prev['Started'], 'yyyy-MM-dd HH:mm:ss', $inv, [Globalization.DateTimeStyles]::None, [ref]$s0) -and
      [datetime]::TryParseExact([string]$prev['Finished'], 'yyyy-MM-dd HH:mm:ss', $inv, [Globalization.DateTimeStyles]::None, [ref]$f0)) {
    $took = ($f0 - $s0).TotalSeconds; $idle = ($started - $f0).TotalSeconds
    if ($took -gt 0 -and $idle -ge 0 -and $idle -lt 2 * $took) {
      Write-Host ('Skipped: the last build took {0:n0}s and ended {1:n0}s ago.' -f $took, $idle)
      exit 0
    }
  }
}
# one build at a time on this PC (the scheduled task and a manual run could overlap)
$mutex = $null
try { $mutex = New-Object System.Threading.Mutex($false, 'Global\MT4DashboardBuild') } catch { $mutex = New-Object System.Threading.Mutex($false, 'MT4DashboardBuild') }
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Write-Host 'Another dashboard build is running on this PC; this run was skipped.'; exit 0 }
# keep the MT4 terminals responsive
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = if ($here -and (Split-Path -Leaf $here) -ieq '_DASHBOARD_BUILD') { Split-Path -Parent $here } else { 'I:\My Drive\MT4_Terminals' }
}
if (-not (Test-Path -LiteralPath $ProjectRoot)) { throw "ProjectRoot does not exist: $ProjectRoot" }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $ProjectRoot '_DASHBOARD' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# folders to scan: the project, plus -ExtraFolders and EXTRA_FOLDERS.txt (one per line, # starts a comment).
# Base is where the relative path starts, so its first part names the terminal (used for logs and sync files).
$roots = New-Object System.Collections.Generic.List[object]
$roots.Add([pscustomobject]@{ Path = $ProjectRoot.TrimEnd('\', '/'); Base = $ProjectRoot.TrimEnd('\', '/') })
$extraList = @($ExtraFolders)
$extraFile = if ($here) { Join-Path $here 'EXTRA_FOLDERS.txt' } else { '' }
if ($extraFile -and (Test-Path -LiteralPath $extraFile)) {
  $extraList += @(Get-Content -LiteralPath $extraFile | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$extraNotes = New-Object System.Collections.Generic.List[string]
foreach ($x in $extraList) {
  $p = if ([System.IO.Path]::IsPathRooted($x)) { $x } else { Join-Path (Split-Path -Parent $ProjectRoot) $x }
  if (-not (Test-Path -LiteralPath $p -PathType Container)) { $extraNotes.Add('SKIP extra folder not found: ' + $x); continue }
  $p = (Resolve-Path -LiteralPath $p).Path.TrimEnd('\', '/')
  if (@($roots | Where-Object { ($p + '\').StartsWith($_.Path + '\', [StringComparison]::OrdinalIgnoreCase) -or ($p + '/').StartsWith($_.Path + '/', [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
  # one terminal (Reports, Experts, Journal, MQL4 or logs inside): name it after the folder; else a folder of terminals
  $isTerminal = @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Reports|Experts|Journal|MQL4|logs)$' }).Count -gt 0
  $roots.Add([pscustomobject]@{ Path = $p; Base = $(if ($isTerminal) { Split-Path -Parent $p } else { $p }) })
}

if (-not ('Mt4DashV2.Builder' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Mt4DashV2 {
  // ends a run that hangs (e.g. a file Google Drive cannot fetch), so the next scheduled run can start
  public static class Watchdog {
    static System.Threading.Timer timer;
    public static void Start(int minutes, string logPath, string logText) {
      timer = new System.Threading.Timer(delegate(object o) {
        try { if (!string.IsNullOrEmpty(logPath)) File.WriteAllText(logPath, logText); } catch (Exception) { }
        Environment.Exit(3);
      }, null, (long)minutes * 60000L, System.Threading.Timeout.Infinite);
    }
  }
  public class Csv {
    public string[] Header;
    public Dictionary<string, int> Index;
    public List<string[]> Rows = new List<string[]>();
    public int Get(string name) { int i; return Index.TryGetValue(name, out i) ? i : -1; }
  }

  public static class Builder {
    // New columns are always appended at the end; code below uses fixed indexes for the first ones.
    public static readonly string[] TradeCols = new string[] {
      "account","ticket","machine_label","terminal_label","campaign","account_currency","server",
      "open_time","close_time","type","lots","symbol","digits","open_price","close_price",
      "magic","comment","base_comment","exit_reason","profit","commission","swap","net_profit",
      "duration_seconds","avg_spread_points","max_spread_points","mfe_points","mae_points",
      "open_spread_cost_estimate_account_ccy","close_spread_cost_estimate_account_ccy",
      "basket_id","basket_leg_seq","collector_version","recorded_at",
      "initial_sl","initial_tp","initial_sl_points","initial_tp_points","point_size",
      "flag_no_initial_tp","flag_wide_initial_sl","first_seen_balance" };
    public static readonly string[] OpenCols = new string[] {
      "account","machine_label","terminal_label","campaign","ticket","type","lots","symbol",
      "open_time","open_price","last_sl","last_tp","magic","comment","base_comment",
      "mfe_points","mae_points","max_spread_points","last_seen",
      "initial_sl_points","profit","swap","commission" };
    public static readonly string[] SnapCols = new string[] {
      "account","machine_label","terminal_label","campaign","server","time","balance","equity",
      "floating_net","margin_level_pct","open_market_orders","total_market_lots" };

    public static List<string> Log = new List<string>();
    // ticket -> close time of every closed trade, filled by BuildTrades and used by BuildHealth
    public static Dictionary<string, DateTime> ClosedAt = new Dictionary<string, DateTime>();
    static readonly string[] TimeFormats = new string[] { "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm" };
    static bool TryTime(string s, out DateTime t) {
      return DateTime.TryParseExact(s, TimeFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out t);
    }

    // ---------------- reading ----------------
    static Encoding Detect(Stream s) {
      byte[] b = new byte[4]; int n = s.Read(b, 0, 4); s.Position = 0;
      if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE) return Encoding.Unicode;
      if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) return Encoding.BigEndianUnicode;
      if (n >= 4 && b[1] == 0 && b[3] == 0 && b[0] != 0) return Encoding.Unicode;  // UTF-16LE without BOM
      return new UTF8Encoding(false);
    }
    static StreamReader OpenText(string path) {
      FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      return new StreamReader(fs, Detect(fs), true);
    }
    static string ReadAllText(string path) { using (StreamReader sr = OpenText(path)) return sr.ReadToEnd(); }

    public static string[] SplitLine(string line) {
      if (line.IndexOf('"') < 0) return line.Split(',');
      List<string> f = new List<string>(); StringBuilder sb = new StringBuilder(); bool q = false;
      for (int i = 0; i < line.Length; i++) {
        char c = line[i];
        if (q) {
          if (c == '"') { if (i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; } else q = false; }
          else sb.Append(c);
        } else if (c == '"') q = true;
        else if (c == ',') { f.Add(sb.ToString()); sb.Length = 0; }
        else sb.Append(c);
      }
      f.Add(sb.ToString());
      return f.ToArray();
    }

    // Unquoted comments can contain commas: glue extra fields back into comment (and base_comment).
    static string[] FixRow(string[] r, int n, int ci, int bi) {
      if (r.Length == n) return r;
      if (r.Length < n) { string[] p = new string[n]; for (int i = 0; i < n; i++) p[i] = i < r.Length ? r[i] : ""; return p; }
      int extra = r.Length - n;
      if (ci < 0) { string[] t = new string[n]; Array.Copy(r, t, n); return t; }
      List<string> o = new List<string>();
      for (int i = 0; i < ci; i++) o.Add(r[i]);
      if (bi == ci + 1 && extra % 2 == 0) {
        int h = extra / 2;
        o.Add(string.Join(",", r, ci, h + 1));
        o.Add(string.Join(",", r, ci + h + 1, h + 1));
        for (int i = ci + extra + 2; i < r.Length; i++) o.Add(r[i]);
      } else {
        o.Add(string.Join(",", r, ci, extra + 1));
        for (int i = ci + extra + 1; i < r.Length; i++) o.Add(r[i]);
      }
      return o.ToArray();
    }

    // Lines starting with '#' are collector trailers (#END,rows,...) and are skipped.
    public static Csv Read(string path) {
      Csv csv = new Csv();
      csv.Index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
      int ci = -1, bi = -1;
      using (StreamReader sr = OpenText(path)) {
        string l;
        while ((l = sr.ReadLine()) != null) {
          if (l.Trim().Length == 0 || l.StartsWith("#")) continue;
          if (csv.Header == null) {
            csv.Header = SplitLine(l);
            for (int i = 0; i < csv.Header.Length; i++) { string h = csv.Header[i].Trim(); if (!csv.Index.ContainsKey(h)) csv.Index[h] = i; }
            ci = csv.Get("comment"); bi = csv.Get("base_comment");
            continue;
          }
          csv.Rows.Add(FixRow(SplitLine(l), csv.Header.Length, ci, bi));
        }
      }
      if (csv.Header == null) csv.Header = new string[0];
      return csv;
    }

    // ---------------- writing ----------------
    static string Cell(string[] r, int i) { return i < 0 || i >= r.Length ? "" : r[i].Trim(); }
    static double Num(string s) { double d; return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : 0; }
    static bool TryNum(string s, out double d) { return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d); }
    static string F(double d) { return d.ToString("0.##", CultureInfo.InvariantCulture); }
    static string Esc(string s) {
      if (s.IndexOfAny(new char[] { ',', '"', '\n', '\r' }) < 0) return s;
      return "\"" + s.Replace("\"", "\"\"") + "\"";
    }
    static string Join(string[] cols, IList<string[]> rows) {
      StringBuilder sb = new StringBuilder();
      sb.Append(string.Join(",", cols)).Append('\n');
      foreach (string[] r in rows) {
        for (int i = 0; i < r.Length; i++) { if (i > 0) sb.Append(','); sb.Append(Esc(r[i] ?? "")); }
        sb.Append('\n');
      }
      return sb.ToString();
    }
    static byte[] Gzip(string text) {
      byte[] raw = new UTF8Encoding(false).GetBytes(text);
      using (MemoryStream ms = new MemoryStream()) {
        using (GZipStream gz = new GZipStream(ms, CompressionMode.Compress, true)) gz.Write(raw, 0, raw.Length);
        return ms.ToArray();
      }
    }
    // Writes only when the bytes differ; temp file + move so Drive never syncs a half-written file.
    public static bool WriteIfChanged(string path, byte[] data) {
      if (File.Exists(path)) {
        byte[] old = File.ReadAllBytes(path);
        if (old.Length == data.Length) {
          bool same = true;
          for (int i = 0; i < old.Length; i++) if (old[i] != data[i]) { same = false; break; }
          if (same) return false;
        }
      }
      string tmp = path + ".tmp";
      File.WriteAllBytes(tmp, data);
      if (File.Exists(path)) File.Delete(path);
      File.Move(tmp, path);
      return true;
    }
    static string TagOf(string name) {
      Match m = Regex.Match(name, @"_(Quant[A-Za-z]*\d+)_", RegexOptions.IgnoreCase);
      return m.Success ? m.Groups[1].Value : "untagged";
    }

    // ---------------- closed trades ----------------
    class Rec { public string[] Out; public double Version; public string Recorded; }

    public static List<string> BuildTrades(string[] files, string outDir, int maxRows, out int total) {
      Dictionary<string, Rec> map = new Dictionary<string, Rec>();
      foreach (string f in files) {
        Csv c;
        try { c = Read(f); } catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); continue; }
        int[] ix = new int[TradeCols.Length];
        for (int i = 0; i < TradeCols.Length; i++) ix[i] = c.Get(TradeCols[i]);
        int iType = c.Get("type"), iAcc = c.Get("account"), iTicket = c.Get("ticket"), iClose = c.Get("close_time");
        int iVer = c.Get("collector_version"), iRec = c.Get("recorded_at");
        string tag = TagOf(Path.GetFileName(f));
        int used = 0;
        foreach (string[] r in c.Rows) {
          string type = Cell(r, iType).ToUpperInvariant();
          if (type != "BUY" && type != "SELL") continue;
          string acc = Cell(r, iAcc), ticket = Cell(r, iTicket);
          if (acc.Length == 0 || ticket.Length == 0 || Cell(r, iClose).Length < 10) continue;
          string[] o = new string[TradeCols.Length + 1];
          for (int i = 0; i < TradeCols.Length; i++) o[i] = Cell(r, ix[i]);
          o[TradeCols.Length] = tag;
          Rec rec = new Rec(); rec.Out = o; rec.Version = Num(Cell(r, iVer)); rec.Recorded = Cell(r, iRec);
          string key = acc + "|" + ticket; Rec prev;
          if (!map.TryGetValue(key, out prev) || rec.Version > prev.Version ||
              (rec.Version == prev.Version && string.CompareOrdinal(rec.Recorded, prev.Recorded) > 0)) map[key] = rec;
          used++;
        }
        Log.Add("trades " + Path.GetFileName(f) + " rows=" + c.Rows.Count + " used=" + used);
      }
      total = map.Count;
      ClosedAt.Clear();
      foreach (Rec r in map.Values) { DateTime ct; if (TryTime(r.Out[8], out ct)) ClosedAt[r.Out[1]] = ct; }
      Dictionary<string, List<string[]>> groups = new Dictionary<string, List<string[]>>();
      foreach (Rec r in map.Values) {
        string acc = r.Out[0]; string close = r.Out[8];
        string month = close.Substring(0, 4) + "-" + close.Substring(5, 2);
        string g = acc + "_" + month; List<string[]> l;
        if (!groups.TryGetValue(g, out l)) { l = new List<string[]>(); groups[g] = l; }
        l.Add(r.Out);
      }
      string[] cols = new string[TradeCols.Length + 1];
      Array.Copy(TradeCols, cols, TradeCols.Length); cols[TradeCols.Length] = "file_tag";
      List<string> produced = new List<string>();
      foreach (KeyValuePair<string, List<string[]>> kv in groups) {
        kv.Value.Sort(delegate(string[] a, string[] b) {
          int x = string.CompareOrdinal(a[8], b[8]); return x != 0 ? x : string.CompareOrdinal(a[1], b[1]); });
        int parts = (kv.Value.Count + maxRows - 1) / maxRows;
        for (int p = 0; p < parts; p++) {
          List<string[]> slice = kv.Value.GetRange(p * maxRows, Math.Min(maxRows, kv.Value.Count - p * maxRows));
          string name = "trades_" + kv.Key + (parts > 1 ? "_p" + (p + 1) : "") + ".csv.gz";
          if (WriteIfChanged(Path.Combine(outDir, name), Gzip(Join(cols, slice)))) Log.Add("wrote " + name);
          produced.Add(name);
        }
      }
      return produced;
    }

    // ---------------- open positions ----------------
    public static List<string> BuildOpen(string[] files, string outDir) {
      Dictionary<string, List<string[]>> best = new Dictionary<string, List<string[]>>();
      Dictionary<string, string> bestSeen = new Dictionary<string, string>();
      foreach (string f in files) {
        Csv c;
        try { c = Read(f); } catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); continue; }
        int[] ix = new int[OpenCols.Length];
        for (int i = 0; i < OpenCols.Length; i++) ix[i] = c.Get(OpenCols[i]);
        Dictionary<string, List<string[]>> per = new Dictionary<string, List<string[]>>();
        Dictionary<string, string> seen = new Dictionary<string, string>();
        foreach (string[] r in c.Rows) {
          string[] o = new string[OpenCols.Length];
          for (int i = 0; i < OpenCols.Length; i++) o[i] = Cell(r, ix[i]);
          if (o[0].Length == 0) continue;
          List<string[]> l; if (!per.TryGetValue(o[0], out l)) { l = new List<string[]>(); per[o[0]] = l; seen[o[0]] = ""; }
          l.Add(o);
          if (string.CompareOrdinal(o[18], seen[o[0]]) > 0) seen[o[0]] = o[18];
        }
        foreach (KeyValuePair<string, List<string[]>> kv in per) {
          string s; if (!bestSeen.TryGetValue(kv.Key, out s) || string.CompareOrdinal(seen[kv.Key], s) > 0) { best[kv.Key] = kv.Value; bestSeen[kv.Key] = seen[kv.Key]; }
        }
      }
      List<string[]> all = new List<string[]>();
      foreach (List<string[]> l in best.Values) all.AddRange(l);
      if (WriteIfChanged(Path.Combine(outDir, "open_now.csv.gz"), Gzip(Join(OpenCols, all)))) Log.Add("wrote open_now.csv.gz");
      List<string> produced = new List<string>(); produced.Add("open_now.csv.gz");
      return produced;
    }

    // ---------------- equity ----------------
    class Slot { public string[] Last; public double MinEq = double.MaxValue, MaxEq = double.MinValue, MinFloat = double.MaxValue; public string MinEqTime = ""; }

    public static List<string> BuildEquity(string[] files, string outDir, int minutes) {
      Dictionary<string, SortedDictionary<string, Slot>> per = new Dictionary<string, SortedDictionary<string, Slot>>();
      foreach (string f in files) {
        Csv c;
        try { c = Read(f); } catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); continue; }
        int[] ix = new int[SnapCols.Length];
        for (int i = 0; i < SnapCols.Length; i++) ix[i] = c.Get(SnapCols[i]);
        int iEq = ix[7], iFl = ix[8];
        foreach (string[] r in c.Rows) {
          string acc = Cell(r, ix[0]), t = Cell(r, ix[5]);
          if (acc.Length == 0 || t.Length < 16) continue;
          int hh, mm;
          if (!int.TryParse(t.Substring(11, 2), out hh) || !int.TryParse(t.Substring(14, 2), out mm)) continue;
          int slotNo = (hh * 60 + mm) / minutes;
          string bucket = t.Substring(0, 10) + "#" + slotNo.ToString("0000");
          SortedDictionary<string, Slot> d;
          if (!per.TryGetValue(acc, out d)) { d = new SortedDictionary<string, Slot>(StringComparer.Ordinal); per[acc] = d; }
          Slot s;
          if (!d.TryGetValue(bucket, out s)) { s = new Slot(); d[bucket] = s; }
          double eq, fl;
          if (TryNum(Cell(r, iEq), out eq)) {
            if (eq < s.MinEq) { s.MinEq = eq; s.MinEqTime = t; }
            if (eq > s.MaxEq) s.MaxEq = eq;
          }
          if (TryNum(Cell(r, iFl), out fl) && fl < s.MinFloat) s.MinFloat = fl;
          if (s.Last == null || string.CompareOrdinal(s.Last[5], t) < 0) {
            string[] o = new string[SnapCols.Length];
            for (int i = 0; i < SnapCols.Length; i++) o[i] = Cell(r, ix[i]);
            s.Last = o;
          }
        }
        Log.Add("snapshots " + Path.GetFileName(f) + " rows=" + c.Rows.Count);
      }
      string[] cols = new string[SnapCols.Length + 4];
      Array.Copy(SnapCols, cols, SnapCols.Length);
      cols[SnapCols.Length] = "equity_min"; cols[SnapCols.Length + 1] = "equity_min_time";
      cols[SnapCols.Length + 2] = "equity_max"; cols[SnapCols.Length + 3] = "floating_min";
      List<string> produced = new List<string>();
      foreach (KeyValuePair<string, SortedDictionary<string, Slot>> kv in per) {
        List<string[]> rows = new List<string[]>();
        foreach (Slot s in kv.Value.Values) {
          if (s.Last == null) continue;
          string[] o = new string[cols.Length];
          Array.Copy(s.Last, o, SnapCols.Length);
          o[SnapCols.Length] = s.MinEq == double.MaxValue ? "" : F(s.MinEq);
          o[SnapCols.Length + 1] = s.MinEqTime;
          o[SnapCols.Length + 2] = s.MaxEq == double.MinValue ? "" : F(s.MaxEq);
          o[SnapCols.Length + 3] = s.MinFloat == double.MaxValue ? "" : F(s.MinFloat);
          rows.Add(o);
        }
        string name = "equity_" + kv.Key + ".csv.gz";
        if (WriteIfChanged(Path.Combine(outDir, name), Gzip(Join(cols, rows)))) Log.Add("wrote " + name);
        produced.Add(name);
      }
      return produced;
    }

    // ---------------- text bundles ----------------
    public static List<string> BuildBundle(string[] files, string[] labels, string outDir, string name) {
      StringBuilder sb = new StringBuilder();
      for (int i = 0; i < files.Length; i++) {
        try { sb.Append("#FILE: ").Append(labels[i]).Append('\n').Append(ReadAllText(files[i]).Replace("\r", "")).Append('\n'); }
        catch (Exception e) { Log.Add("SKIP " + files[i] + " : " + e.Message); }
      }
      if (WriteIfChanged(Path.Combine(outDir, name), new UTF8Encoding(false).GetBytes(sb.ToString()))) Log.Add("wrote " + name);
      List<string> produced = new List<string>(); produced.Add(name);
      return produced;
    }

    // ---------------- logs: errors, warnings, activity ----------------
    class Agg {
      public string Terminal, Kind, Date, Source, Chart, Category, Severity, First = "", Last = "", Sample = "", Magic = "";
      public long Count; public double Max = double.MinValue, Sum;
    }
    static readonly Regex RxLine = new Regex(@"^\s*(\d+)\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.*)$");
    static readonly Regex RxChart = new Regex(@"^(.*?)\s+([^\s,]+),(M1|M5|M15|M30|H1|H4|D1|W1|MN1|MN)(:\s?|\s+inputs:\s?)(.*)$");
    static readonly Regex RxMagic = new Regex(@"(?:^|;\s*)(?:MagicNumber|InpMagic|InpMagicNumber|Magic)=(\d+)", RegexOptions.IgnoreCase);
    static readonly Regex RxFade = new Regex(@"(?:^|;\s*)(InpFadeBeforeFilters|InpReverseAfterFilters)=(\w+)", RegexOptions.IgnoreCase);
    static readonly Regex RxErrCode = new Regex(@"\berror\b\W{0,3}(\d{1,5})\b", RegexOptions.IgnoreCase);
    static readonly Regex RxUninit = new Regex(@"^uninit reason (\d+)", RegexOptions.IgnoreCase);
    static readonly Regex RxFailed = new Regex(@"failed \[([^\]]+)\]", RegexOptions.IgnoreCase);
    static readonly Regex RxPing = new Regex(@"ping to current access point (.+?) is ([\d.]+) ms", RegexOptions.IgnoreCase);
    static readonly Regex RxAccount = new Regex(@"^'(\d+)':\s*(.*)$");
    static readonly Regex RxTicket = new Regex(@"ticket #?(\d{5,})", RegexOptions.IgnoreCase);
    static readonly Regex RxOrderClose = new Regex(@"^order #(\d{5,})\b.*\bclosing\b", RegexOptions.IgnoreCase);
    const string LateClose = "Late close attempt (order already closed)";
    // An EA that closes a ticket the broker already closed by SL/TP gets "unknown ticket" (4108) or a close at
    // price 0. True when the trade's close time (broker time) is at most 2 minutes after the log line (PC time).
    static bool ClosedBefore(string ticket, string time) {
      DateTime closed, at;
      return !string.IsNullOrEmpty(ticket) && ClosedAt.TryGetValue(ticket, out closed) && TryTime(time, out at) && closed <= at.AddMinutes(2);
    }
    static string TicketOf(string msg) { Match m = RxTicket.Match(msg); return m.Success ? m.Groups[1].Value : ""; }
    static readonly string[] UninitNames = new string[] { "program", "removed", "recompiled", "symbol or timeframe changed", "chart closed",
      "inputs changed", "account changed", "template applied", "init failed", "terminal closed" };

    static void Add(Dictionary<string, Agg> aggs, string terminal, string kind, string date, string source, string chart,
                    string category, string severity, string time, string sample, double value, string magic) {
      string key = terminal + "|" + kind + "|" + date + "|" + source + "|" + chart + "|" + category;
      Agg a;
      if (!aggs.TryGetValue(key, out a)) {
        a = new Agg(); a.Terminal = terminal; a.Kind = kind; a.Date = date; a.Source = source; a.Chart = chart;
        a.Category = category; a.Severity = severity; a.First = time; aggs[key] = a;
      }
      a.Count++; a.Last = time;
      if (sample != null) a.Sample = sample.Length > 240 ? sample.Substring(0, 240) : sample;
      if (!double.IsNaN(value)) { a.Sum += value; if (value > a.Max) a.Max = value; }
      if (!string.IsNullOrEmpty(magic)) a.Magic = magic;
    }

    static void ClassifyExpert(Dictionary<string, Agg> aggs, Dictionary<string, string> magics, string term, string date,
                               string level, string time, string rest) {
      string source = "", chart = "", msg = rest; bool isInputs = false;
      Match m = RxChart.Match(rest);
      if (m.Success) {
        source = m.Groups[1].Value.Trim(); chart = m.Groups[2].Value + "," + m.Groups[3].Value; msg = m.Groups[5].Value;
        isInputs = m.Groups[4].Value.Contains("inputs");
      }
      bool isExpertTag = source.StartsWith("Expert ");
      if (isExpertTag) source = source.Substring(7).Trim();
      if (source.StartsWith("Custom indicator ")) source = source.Substring(17).Trim();
      string instKey = term + "|" + source + "|" + chart;
      string magic; magics.TryGetValue(instKey, out magic);
      string cat = null, sev = "info";
      if (isInputs) {
        Match mm = RxMagic.Match(msg);
        if (mm.Success) { magic = mm.Groups[1].Value; magics[instKey] = magic; }
        StringBuilder sb = new StringBuilder();
        if (mm.Success) sb.Append("MagicNumber=").Append(mm.Groups[1].Value);
        foreach (Match fm in RxFade.Matches(msg)) { if (sb.Length > 0) sb.Append("; "); sb.Append(fm.Groups[1].Value).Append('=').Append(fm.Groups[2].Value); }
        Add(aggs, term, "experts", date, source, chart, "EA started (inputs)", "info", time, sb.Length > 0 ? sb.ToString() : msg, double.NaN, magic);
        return;
      }
      string low = msg.ToLowerInvariant();
      Match um = RxUninit.Match(msg);
      if (isExpertTag && low.StartsWith("loaded successfully")) cat = "EA loaded";
      else if (isExpertTag && low.StartsWith("removed")) cat = "EA removed";
      else if (um.Success) { int code = int.Parse(um.Groups[1].Value); cat = "EA stopped: " + (code >= 0 && code < UninitNames.Length ? UninitNames[code] : "reason " + code); }
      // the EA's own hard-stop exit: a stop-out, not a terminal fault (shown with "Everything incl. info")
      else if (low.Contains("emergency exit")) { cat = "Emergency exit"; sev = "info"; }
      else if (low.Contains("aep close") && (low.Contains("exhausted") || low.Contains("retry"))) {
        if (ClosedBefore(TicketOf(msg), time)) { cat = LateClose; sev = "info"; }
        else if (low.Contains("exhausted")) { cat = "AEP close exhausted"; sev = "critical"; }
        else { cat = "AEP close retry failed"; sev = "warning"; }
      }
      else if (low.Contains("aep sync") && low.Contains("exhausted")) { cat = "AEP sync exhausted"; sev = "warning"; }
      else if (low.Contains("aep sync retry")) { cat = "AEP sync retry failed"; sev = "warning"; }
      else if (low.Contains("unknown ticket")) {
        if (ClosedBefore(TicketOf(msg), time)) { cat = LateClose; sev = "info"; } else { cat = "Unknown ticket"; sev = "warning"; }
      }
      else if (low.StartsWith("alert:") && low.Contains("take profit hit")) { cat = "Take profit hit"; sev = "info"; }
      else if (low.StartsWith("alert:")) { cat = "Alert"; sev = "warning"; }
      else if (low.Contains("pair_blocked") && low.Contains("not connected")) { cat = "Mirror copier blocked: terminal not connected"; sev = "warning"; }
      else if (low.Contains("pair_blocked")) { cat = "Mirror copier waiting"; sev = "info"; }
      else if (low.Contains("spread too wide")) { cat = "Entry blocked: spread too wide"; sev = "info"; }
      else if (low.Contains("timer gap")) { cat = "Collector timer stall"; sev = "info"; }
      else if (low.StartsWith("open #")) cat = "Order opened";
      else if (low.StartsWith("close #")) cat = "Order closed";
      else if (low.StartsWith("modify #")) cat = "Order modified";
      else if (low.StartsWith("delete #")) cat = "Order deleted";
      else {
        Match em = RxErrCode.Match(msg);
        if (em.Success) { cat = "Error " + em.Groups[1].Value; sev = "error"; }
        else if (low.Contains("cannot open file")) { cat = "Cannot open file"; sev = "error"; }
        else if (low.Contains("trade operations not allowed")) { cat = "Trading not allowed (AutoTrading off or not allowed in EA settings)"; sev = "error"; }
        else if (level == "3") { cat = "Terminal error"; sev = "error"; }
      }
      if (cat != null) Add(aggs, term, "experts", date, source, chart, cat, sev, time, msg, double.NaN, magic);
      Add(aggs, term, "experts", date, source, chart, "_activity", "activity", time, msg, double.NaN, magic);
    }

    static void ClassifyJournal(Dictionary<string, Agg> aggs, Dictionary<string, string> accounts, string term, string date,
                                string level, string time, string rest) {
      string msg = rest; string source = "terminal";
      Match am = RxAccount.Match(rest);
      if (am.Success) { accounts[term] = am.Groups[1].Value; source = am.Groups[1].Value; msg = am.Groups[2].Value; }
      string low = msg.ToLowerInvariant();
      Match pm = RxPing.Match(msg);
      if (pm.Success) { double v = Num(pm.Groups[2].Value); Add(aggs, term, "journal", date, source, "", "Ping (ms)", "info", time, pm.Groups[1].Value + " " + F(v) + " ms", v, ""); return; }
      Match fm = RxFailed.Match(msg);
      if (low.Contains("connect failed") || (low.Contains("connection to") && low.Contains("lost"))) {
        Add(aggs, term, "journal", date, source, "", "Connection failed" + (fm.Success ? ": " + fm.Groups[1].Value : ""), "warning", time, msg, double.NaN, "");
      } else if (fm.Success) {
        Match om = RxOrderClose.Match(msg);
        if (om.Success && ClosedBefore(om.Groups[1].Value, time)) Add(aggs, term, "journal", date, source, "", LateClose, "info", time, msg, double.NaN, "");
        else Add(aggs, term, "journal", date, source, "", "Order failed: " + fm.Groups[1].Value, "error", time, msg, double.NaN, "");
      } else if (low.StartsWith("login on ")) {
        Add(aggs, term, "journal", date, source, "", "Login", "info", time, msg, double.NaN, "");
      } else if (low.Contains("requote")) {
        Add(aggs, term, "journal", date, source, "", "Requote", "warning", time, msg, double.NaN, "");
      } else if (low.Contains("trade context is busy")) {
        Add(aggs, term, "journal", date, source, "", "Trade context busy", "warning", time, msg, double.NaN, "");
      } else if (low.Contains(": loaded successfully") || low.EndsWith(": removed") || low.Contains(": initialized") || low.Contains(": uninit reason")) {
        // EA and indicator load/unload lines carry a high level in the journal but are not errors
      } else if (level == "2" || level == "3") {
        Add(aggs, term, "journal", date, source, "", "Terminal error", "error", time, msg, double.NaN, "");
      }
    }

    public static List<string> BuildHealth(string[] files, string[] terminals, string[] kinds, string outDir) {
      Dictionary<string, Agg> aggs = new Dictionary<string, Agg>();
      Dictionary<string, string> magics = new Dictionary<string, string>();
      Dictionary<string, string> accounts = new Dictionary<string, string>();
      // read oldest first so the latest MagicNumber per EA instance wins
      int[] order = new int[files.Length];
      for (int i = 0; i < order.Length; i++) order[i] = i;
      Array.Sort(order, delegate(int a, int b) { return string.CompareOrdinal(Path.GetFileName(files[a]), Path.GetFileName(files[b])); });
      foreach (int k in order) {
        string f = files[k]; string fn = Path.GetFileNameWithoutExtension(f);
        if (fn.Length != 8) continue;
        string date = fn.Substring(0, 4) + "." + fn.Substring(4, 2) + "." + fn.Substring(6, 2);
        long lines = 0;
        try {
          using (StreamReader sr = OpenText(f)) {
            string l;
            while ((l = sr.ReadLine()) != null) {
              Match m = RxLine.Match(l);
              if (!m.Success) continue;
              lines++;
              string time = date + " " + m.Groups[2].Value.Substring(0, 8);
              if (kinds[k] == "journal") ClassifyJournal(aggs, accounts, terminals[k], date, m.Groups[1].Value, time, m.Groups[3].Value);
              else ClassifyExpert(aggs, magics, terminals[k], date, m.Groups[1].Value, time, m.Groups[3].Value);
            }
          }
        } catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); continue; }
        Log.Add("log " + terminals[k] + "/" + kinds[k] + "/" + Path.GetFileName(f) + " lines=" + lines);
      }
      string[] cols = new string[] { "terminal","kind","date","source","chart","category","severity","count",
        "first_time","last_time","value_max","value_sum","magic","account","sample" };
      List<string[]> rows = new List<string[]>();
      foreach (Agg a in aggs.Values) {
        string acc; accounts.TryGetValue(a.Terminal, out acc);
        string magic = a.Magic; string m2;
        if (string.IsNullOrEmpty(magic) && magics.TryGetValue(a.Terminal + "|" + a.Source + "|" + a.Chart, out m2)) magic = m2;
        rows.Add(new string[] { a.Terminal, a.Kind, a.Date, a.Source, a.Chart, a.Category, a.Severity, a.Count.ToString(CultureInfo.InvariantCulture),
          a.First, a.Last, a.Max == double.MinValue ? "" : F(a.Max), a.Sum == 0 ? "" : F(a.Sum), magic ?? "", acc ?? "", a.Sample });
      }
      rows.Sort(delegate(string[] a, string[] b) {
        int x = string.CompareOrdinal(a[0], b[0]); if (x != 0) return x;
        x = string.CompareOrdinal(a[2], b[2]); if (x != 0) return x;
        return string.CompareOrdinal(a[5] + a[3] + a[4], b[5] + b[3] + b[4]); });
      if (WriteIfChanged(Path.Combine(outDir, "health_events.csv.gz"), Gzip(Join(cols, rows)))) Log.Add("wrote health_events.csv.gz");
      List<string> produced = new List<string>(); produced.Add("health_events.csv.gz");
      return produced;
    }
  }
}
'@
}

[Mt4DashV2.Watchdog]::Start(30, $runLog, (@(
  ('MT4 Dashboard build on ' + $pc),
  ('Started:  ' + $started.ToString('yyyy-MM-dd HH:mm:ss')),
  'Result:   FAILED - stopped after 30 minutes. Is Google Drive running and online on this PC?',
  ('Project:  ' + $ProjectRoot),
  ('Builder:  ' + $BuilderVersion)) -join "`r`n") + "`r`n")

Add-Timing 'start'
[Mt4DashV2.Builder]::Log.Clear()

# One walk over the project instead of one per file type (listing folders on Google Drive is slow).
# Folders and files whose name starts with an -Exclude entry are skipped; an unreadable folder is skipped.
$excludeRx = '^(' + (@($Exclude | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
$found = @{}
foreach ($k in @('trades', 'open', 'snaps', 'status', 'sync', 'map', 'logs')) { $found[$k] = New-Object System.Collections.Generic.List[string] }
$dirs = New-Object System.Collections.Generic.Stack[string]
foreach ($r in $roots) { $dirs.Push($r.Path) }
while ($dirs.Count -gt 0) {
  $d = $dirs.Pop()
  try {
    foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
      $n = [System.IO.Path]::GetFileName($f)
      if ($n -match $excludeRx) { continue }
      if ($n -like '*_DetailedStatementLive.csv') { $found['trades'].Add($f) }
      elseif ($n -like '*_open_now.csv') { $found['open'].Add($f) }
      elseif ($n -like '*_account_snapshots.csv') { $found['snaps'].Add($f) }
      elseif ($n -like '*collector_status.txt') { $found['status'].Add($f) }
      elseif ($n -like '_sync_status*.txt') { $found['sync'].Add($f) }
      elseif ($n -like '_terminal_identity_map*.txt') { $found['map'].Add($f) }
      elseif ($n -like '*.log') { $found['logs'].Add($f) }
    }
    foreach ($s in [System.IO.Directory]::EnumerateDirectories($d)) { if ([System.IO.Path]::GetFileName($s) -notmatch $excludeRx) { $dirs.Push($s) } }
  } catch { [Mt4DashV2.Builder]::Log.Add('SKIP ' + $d + ' : ' + $_.Exception.Message) }
}
# stable order: older collector tags first (newest version wins anyway)
function Get-Found([string]$Kind) { return @($found[$Kind] | Sort-Object) }
function Get-RelativeParts([string]$Path) {
  $best = $null
  foreach ($r in $roots) {
    $inside = $Path.StartsWith($r.Path + '\', [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($r.Path + '/', [StringComparison]::OrdinalIgnoreCase)
    if ($inside -and (-not $best -or $r.Path.Length -gt $best.Path.Length)) { $best = $r }
  }
  $base = if ($best) { $best.Base } else { $ProjectRoot }
  return @($Path.Substring($base.Length).TrimStart('\', '/') -split '[\\/]')
}

$tradeFiles = Get-Found 'trades'
$openFiles = Get-Found 'open'
$snapFiles = Get-Found 'snaps'
$statusFiles = Get-Found 'status'
$syncFiles = @(Get-Found 'sync') + @(Get-Found 'map')

# MT4 logs: <terminal>\Experts\yyyymmdd.log and <terminal>\Journal\yyyymmdd.log (also MQL4\Logs and logs)
$logCandidates = foreach ($f in (Get-Found 'logs')) {
  $name = [System.IO.Path]::GetFileName($f)
  if ($name -notmatch '^\d{8}\.log$') { continue }
  $parts = Get-RelativeParts $f
  if ($parts.Count -lt 3) { continue }
  $folder = $parts[$parts.Count - 2]
  $parentFolder = if ($parts.Count -ge 3) { $parts[$parts.Count - 3] } else { '' }
  $kind = $null
  if ($folder -ieq 'Experts') { $kind = 'experts' }
  elseif ($folder -ieq 'Journal') { $kind = 'journal' }
  elseif ($folder -ieq 'Logs' -and $parentFolder -ieq 'MQL4') { $kind = 'experts' }
  elseif ($folder -ieq 'logs') { $kind = 'journal' }
  if (-not $kind) { continue }
  [pscustomobject]@{ Path = $f; Terminal = $parts[0]; Kind = $kind; Date = $name.Substring(0, 8) }
}
# the last LogDays calendar days up to today, so terminals that stopped logging drop out
$logCut = $started.AddDays(1 - $LogDays).ToString('yyyyMMdd')
$logFiles = @($logCandidates | Where-Object { $_.Date -ge $logCut })
Write-Host ("Found {0} statement, {1} open, {2} snapshot, {3} status, {4} sync, {5} log files" -f `
  $tradeFiles.Count, $openFiles.Count, $snapFiles.Count, $statusFiles.Count, $syncFiles.Count, $logFiles.Count)
Add-Timing 'scan'

$total = 0
$produced = New-Object System.Collections.Generic.List[string]
$produced.AddRange([Mt4DashV2.Builder]::BuildTrades([string[]]$tradeFiles, $OutDir, $MaxRowsPerFile, [ref]$total))
Add-Timing 'trades'
$produced.AddRange([Mt4DashV2.Builder]::BuildOpen([string[]]$openFiles, $OutDir))
Add-Timing 'open'
$produced.AddRange([Mt4DashV2.Builder]::BuildEquity([string[]]$snapFiles, $OutDir, $EquityMinutes))
Add-Timing 'equity'
$statusLabels = @($statusFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) })
$produced.AddRange([Mt4DashV2.Builder]::BuildBundle([string[]]$statusFiles, [string[]]$statusLabels, $OutDir, 'status_all.txt'))
$syncLabels = @($syncFiles | ForEach-Object { (Get-RelativeParts $_) -join '/' })
$produced.AddRange([Mt4DashV2.Builder]::BuildBundle([string[]]$syncFiles, [string[]]$syncLabels, $OutDir, 'sync_all.txt'))
Add-Timing 'status+sync'
$produced.AddRange([Mt4DashV2.Builder]::BuildHealth([string[]]@($logFiles | ForEach-Object { $_.Path }),
  [string[]]@($logFiles | ForEach-Object { $_.Terminal }), [string[]]@($logFiles | ForEach-Object { $_.Kind }), $OutDir))
Add-Timing 'logs'

# remove outputs that are no longer produced (e.g. a month split differently)
Get-ChildItem -LiteralPath $OutDir -File | Where-Object {
  ($_.Name -like 'trades_*.csv.gz' -or $_.Name -like 'equity_*.csv.gz' -or $_.Name -like '*.tmp') -and -not $produced.Contains($_.Name)
} | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; [Mt4DashV2.Builder]::Log.Add('removed ' + $_.Name) }

$manifest = [ordered]@{
  generatedAt = $started.ToString('yyyy-MM-dd HH:mm:ss')
  generatedUtc = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  builder     = $BuilderVersion
  machine     = $pc
  projectRoot = $ProjectRoot
  extraFolders = @($roots | Select-Object -Skip 1 | ForEach-Object { $_.Path })
  trades      = $total
  logDays     = $LogDays
  sources     = [ordered]@{ statements = $tradeFiles.Count; open = $openFiles.Count; snapshots = $snapFiles.Count; status = $statusFiles.Count; sync = $syncFiles.Count; logs = $logFiles.Count }
  files       = @($produced)
}
$json = $manifest | ConvertTo-Json -Depth 4
[void][Mt4DashV2.Builder]::WriteIfChanged((Join-Path $OutDir 'mt4dash_manifest.json'), [System.Text.UTF8Encoding]::new($false).GetBytes($json))

$changed = @([Mt4DashV2.Builder]::Log | Where-Object { $_ -like 'wrote *' -or $_ -like 'removed *' }).Count
$skipped = @($extraNotes) + @([Mt4DashV2.Builder]::Log | Where-Object { $_ -like 'SKIP *' })
$result = '{0} unique closed trades. {1} output files, {2} changed. {3:n1}s' -f $total, $produced.Count, $changed, ((Get-Date) - $started).TotalSeconds
Write-Host $result
foreach ($s in $skipped) { Write-Warning $s }
Add-Timing 'write'
Write-RunLog ('OK - ' + $result) (@('Timing:   ' + ($timing -join ', ')) + @($skipped))
$mutex.ReleaseMutex()
if ($VerbosePreference -eq 'Continue') { [Mt4DashV2.Builder]::Log | ForEach-Object { Write-Verbose $_ } }
