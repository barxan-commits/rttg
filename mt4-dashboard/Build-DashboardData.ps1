<#
.SYNOPSIS
  Builds compact, gzip-compressed copies of MT4Collector_Quant data for the
  online MT4 Dashboard.

.DESCRIPTION
  Reads (never modifies) every *_DetailedStatementLive.csv, *_open_now.csv,
  *_account_snapshots.csv and *collector_status.txt under ProjectRoot and
  writes into OutDir (default <ProjectRoot>\_DASHBOARD):

    trades_<account>_<yyyy-MM>[_pN].csv.gz   closed trades, deduplicated by
                                             account + ticket (newest collector
                                             version wins)
    open_now.csv.gz                          open positions, newest file per account
    equity_<account>.csv.gz                  balance/equity, one point per N minutes
    status_all.txt                           all collector status files
    mt4dash_manifest.json                    build time and file list

  Files are rewritten only when their content changed, so Google Drive only
  syncs what is new. Each file stays far below the size the Google Drive
  connector can pass to the dashboard page.

  Run it on ONE machine only (the VPS is best: it is always on), e.g. every
  10 minutes with Task Scheduler. Works with Windows PowerShell 5.1 and 7.
#>
[CmdletBinding()]
param(
  [string]$ProjectRoot = 'I:\My Drive\MT4_Terminals',
  [string]$OutDir = '',
  [ValidateRange(1, 240)]
  [int]$EquityMinutes = 15,
  [ValidateRange(1000, 100000)]
  [int]$MaxRowsPerFile = 10000,
  [string[]]$Exclude = @('ARCHIVE', '_DASHBOARD', '_MASTER', 'mastergpt')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectRoot)) { throw "ProjectRoot does not exist: $ProjectRoot" }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $ProjectRoot '_DASHBOARD' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

if (-not ('Mt4Dash.Builder' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Mt4Dash {
  public class Csv {
    public string[] Header;
    public Dictionary<string, int> Index;
    public List<string[]> Rows = new List<string[]>();
    public int Get(string name) { int i; return Index.TryGetValue(name, out i) ? i : -1; }
  }

  public static class Builder {
    public static readonly string[] TradeCols = new string[] {
      "account","ticket","machine_label","terminal_label","campaign","account_currency","server",
      "open_time","close_time","type","lots","symbol","digits","open_price","close_price",
      "magic","comment","base_comment","exit_reason","profit","commission","swap","net_profit",
      "duration_seconds","avg_spread_points","max_spread_points","mfe_points","mae_points",
      "open_spread_cost_estimate_account_ccy","close_spread_cost_estimate_account_ccy",
      "basket_id","basket_leg_seq","collector_version","recorded_at" };
    public static readonly string[] OpenCols = new string[] {
      "account","machine_label","terminal_label","campaign","ticket","type","lots","symbol",
      "open_time","open_price","last_sl","last_tp","magic","comment","base_comment",
      "mfe_points","mae_points","max_spread_points","last_seen" };
    public static readonly string[] SnapCols = new string[] {
      "account","machine_label","terminal_label","campaign","server","time","balance","equity",
      "floating_net","margin_level_pct","open_market_orders","total_market_lots" };

    public static List<string> Log = new List<string>();

    static string ReadAllText(string path) {
      using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
      using (StreamReader sr = new StreamReader(fs, new UTF8Encoding(false), true)) {
        return sr.ReadToEnd();
      }
    }

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

    public static Csv Read(string path) {
      Csv csv = new Csv();
      string text = ReadAllText(path);
      string[] lines = text.Split('\n');
      int start = 0;
      while (start < lines.Length && lines[start].Trim().Length == 0) start++;
      if (start >= lines.Length) { csv.Header = new string[0]; csv.Index = new Dictionary<string, int>(); return csv; }
      csv.Header = SplitLine(lines[start].TrimEnd('\r'));
      csv.Index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
      for (int i = 0; i < csv.Header.Length; i++) { string h = csv.Header[i].Trim(); if (!csv.Index.ContainsKey(h)) csv.Index[h] = i; }
      int ci = csv.Get("comment"), bi = csv.Get("base_comment");
      for (int k = start + 1; k < lines.Length; k++) {
        string l = lines[k].TrimEnd('\r');
        if (l.Trim().Length == 0) continue;
        csv.Rows.Add(FixRow(SplitLine(l), csv.Header.Length, ci, bi));
      }
      return csv;
    }

    static string Cell(string[] r, int i) { return i < 0 || i >= r.Length ? "" : r[i].Trim(); }
    static double Num(string s) { double d; return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : 0; }
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
      // group by account + close month
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

    public static List<string> BuildEquity(string[] files, string outDir, int minutes) {
      Dictionary<string, SortedDictionary<string, string[]>> per = new Dictionary<string, SortedDictionary<string, string[]>>();
      foreach (string f in files) {
        Csv c;
        try { c = Read(f); } catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); continue; }
        int[] ix = new int[SnapCols.Length];
        for (int i = 0; i < SnapCols.Length; i++) ix[i] = c.Get(SnapCols[i]);
        foreach (string[] r in c.Rows) {
          string acc = Cell(r, ix[0]), t = Cell(r, ix[5]);
          if (acc.Length == 0 || t.Length < 16) continue;
          int hh, mm;
          if (!int.TryParse(t.Substring(11, 2), out hh) || !int.TryParse(t.Substring(14, 2), out mm)) continue;
          int slot = (hh * 60 + mm) / minutes;
          string bucket = t.Substring(0, 10) + "#" + slot.ToString("0000");
          SortedDictionary<string, string[]> d;
          if (!per.TryGetValue(acc, out d)) { d = new SortedDictionary<string, string[]>(StringComparer.Ordinal); per[acc] = d; }
          string[] prev;
          if (d.TryGetValue(bucket, out prev) && string.CompareOrdinal(prev[5], t) >= 0) continue;
          string[] o = new string[SnapCols.Length];
          for (int i = 0; i < SnapCols.Length; i++) o[i] = Cell(r, ix[i]);
          d[bucket] = o;
        }
        Log.Add("snapshots " + Path.GetFileName(f) + " rows=" + c.Rows.Count);
      }
      List<string> produced = new List<string>();
      foreach (KeyValuePair<string, SortedDictionary<string, string[]>> kv in per) {
        string name = "equity_" + kv.Key + ".csv.gz";
        if (WriteIfChanged(Path.Combine(outDir, name), Gzip(Join(SnapCols, new List<string[]>(kv.Value.Values))))) Log.Add("wrote " + name);
        produced.Add(name);
      }
      return produced;
    }

    public static List<string> BuildStatus(string[] files, string outDir) {
      StringBuilder sb = new StringBuilder();
      foreach (string f in files) {
        try { sb.Append("#FILE: ").Append(Path.GetFileName(f)).Append('\n').Append(ReadAllText(f).Replace("\r", "")).Append('\n'); }
        catch (Exception e) { Log.Add("SKIP " + f + " : " + e.Message); }
      }
      if (WriteIfChanged(Path.Combine(outDir, "status_all.txt"), new UTF8Encoding(false).GetBytes(sb.ToString()))) Log.Add("wrote status_all.txt");
      List<string> produced = new List<string>(); produced.Add("status_all.txt");
      return produced;
    }
  }
}
'@
}

function Find-Files([string]$Pattern) {
  $all = [System.IO.Directory]::EnumerateFiles($ProjectRoot, $Pattern, [System.IO.SearchOption]::AllDirectories)
  $keep = foreach ($f in $all) {
    $rel = $f.Substring($ProjectRoot.Length)
    $skip = $false
    foreach ($x in $Exclude) { if ($rel -like "*\$x*" -or $rel -like "*/$x*") { $skip = $true; break } }
    if (-not $skip) { $f }
  }
  # stable order: older collector tags first (newest version wins anyway)
  return @($keep | Sort-Object)
}

$started = Get-Date
[Mt4Dash.Builder]::Log.Clear()
$tradeFiles = Find-Files '*_DetailedStatementLive.csv'
$openFiles = Find-Files '*_open_now.csv'
$snapFiles = Find-Files '*_account_snapshots.csv'
$statusFiles = Find-Files '*collector_status.txt'
Write-Host ("Found {0} statement, {1} open, {2} snapshot, {3} status files" -f $tradeFiles.Count, $openFiles.Count, $snapFiles.Count, $statusFiles.Count)

$total = 0
$produced = New-Object System.Collections.Generic.List[string]
$produced.AddRange([Mt4Dash.Builder]::BuildTrades([string[]]$tradeFiles, $OutDir, $MaxRowsPerFile, [ref]$total))
$produced.AddRange([Mt4Dash.Builder]::BuildOpen([string[]]$openFiles, $OutDir))
$produced.AddRange([Mt4Dash.Builder]::BuildEquity([string[]]$snapFiles, $OutDir, $EquityMinutes))
$produced.AddRange([Mt4Dash.Builder]::BuildStatus([string[]]$statusFiles, $OutDir))

# remove outputs that are no longer produced (e.g. a month split differently)
Get-ChildItem -LiteralPath $OutDir -File | Where-Object {
  ($_.Name -like 'trades_*.csv.gz' -or $_.Name -like 'equity_*.csv.gz' -or $_.Name -like '*.tmp') -and -not $produced.Contains($_.Name)
} | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; [Mt4Dash.Builder]::Log.Add('removed ' + $_.Name) }

$manifest = [ordered]@{
  generatedAt = $started.ToString('yyyy-MM-dd HH:mm:ss')
  machine     = $env:COMPUTERNAME
  projectRoot = $ProjectRoot
  trades      = $total
  sources     = [ordered]@{ statements = $tradeFiles.Count; open = $openFiles.Count; snapshots = $snapFiles.Count; status = $statusFiles.Count }
  files       = @($produced)
}
$json = $manifest | ConvertTo-Json -Depth 4
[void][Mt4Dash.Builder]::WriteIfChanged((Join-Path $OutDir 'mt4dash_manifest.json'), [System.Text.UTF8Encoding]::new($false).GetBytes($json))

$changed = @([Mt4Dash.Builder]::Log | Where-Object { $_ -like 'wrote *' -or $_ -like 'removed *' }).Count
$skipped = @([Mt4Dash.Builder]::Log | Where-Object { $_ -like 'SKIP *' })
Write-Host ("{0} unique closed trades. {1} output files, {2} changed. {3:n1}s" -f $total, $produced.Count, $changed, ((Get-Date) - $started).TotalSeconds)
foreach ($s in $skipped) { Write-Warning $s }
if ($VerbosePreference -eq 'Continue') { [Mt4Dash.Builder]::Log | ForEach-Object { Write-Verbose $_ } }
