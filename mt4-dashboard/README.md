# MT4 Dashboard

**Online version (private to you):** https://claude.ai/artifact/TN6q9WSaaW2kGbwTjtYrq5
— opens on any device where you are signed in to claude.ai and reads your data
from Google Drive automatically. See *Online setup* below.

A single local web page (`index.html`) that reads the files written by the
**MT4Collector_Quant** EA and shows statistics per magic number, comment,
symbol, account, campaign, exit reason and basket. Everything runs in your
browser; no data is uploaded and nothing needs to be installed.

## Use it

1. Download `index.html` and open it in Chrome or Edge (double-click works).
2. Click **Choose folder** and pick a folder that contains the collector files:
   - `%APPDATA%\MetaQuotes\Terminal` to read every terminal on this PC
     (paste that path into the folder dialog's address bar), or
   - your Google Drive folder that holds the terminals' `Reports` folders
     (this also brings in the VPS terminals).

   The browser will ask to confirm "upload" of the folder: that only lets the
   page read the files locally.
3. Use the filters at the top (period, account, campaign, magic, comment,
   symbol, side). Click any row in the magic / comment / symbol / account
   tables, or any bar in the magic chart, to filter by it.

To refresh after new trades, choose the folder again.

## Online setup (one time)

The online page cannot download your raw statement files (they are 7-11 MB;
the Google Drive connector passes about 1 MB per file). So a small script
writes compact, gzip-compressed copies into `MT4_Terminals\_DASHBOARD`, and
the page reads those.

1. Copy `Build-DashboardData.ps1` and `RUN_BUILD_DASHBOARD.bat` to **one**
   machine that has `I:\My Drive\MT4_Terminals` (the VPS is best: it is
   always on). Run it on one machine only.
2. Run `RUN_BUILD_DASHBOARD.bat` once and check it prints the number of
   trades. It only reads MT4 data; it writes only inside `_DASHBOARD`.
3. Schedule it every 10 minutes (Command Prompt, adjust the path):

   ```
   schtasks /Create /TN "MT4 Dashboard build" /SC MINUTE /MO 10 /TR "\"C:\path\to\RUN_BUILD_DASHBOARD.bat\"" /F
   ```

4. Open the online page. The first time, allow Google Drive when claude.ai
   asks. The page refreshes itself every 15 minutes while open; the
   **Refresh from Drive** button reloads now. Files that did not change
   come from your browser's cache, so refreshes are quick.

Data is as fresh as the last script run plus Google Drive sync. The header
shows when and where the data was built. New terminals appear automatically
once their collector files are synced into `MT4_Terminals`.

## Views

- **Top tiles**: net profit, win rate, profit factor, expectancy in money and
  R, closed-trade drawdown, **max equity drawdown including floating loss**
  (worst account), **worst floating loss**, net % of balance, health,
  open positions and floating P/L.
- **By magic / comment / symbol / account / campaign / exit reason**: full
  statistics per group, including Avg R, Total R and Net % of balance. The
  magic table also counts trades without a TP and with a wide SL (collector
  flags).
- **Compare**: pick 2–4 magics, comments, accounts, campaigns or symbols and
  see their curves on one chart, in money, R or % of balance, with a 90%
  range for the average per trade. The range resamples whole baskets,
  because pyramid legs win and lose together.
- **Periods**: split the history at one to three dates (default: the middle)
  and compare the periods side by side: one cumulative curve coloured by
  period with a straight line for each period's slope, daily results, key
  figures (net per day, trades and lots per day, win rate, PF, risk per
  trade, R), which strategies stopped, kept running or started at each split,
  and the biggest changes by magic, account, symbol or comment. The split
  dates are saved in your browser, so the last period keeps growing as new
  trades arrive. Other filters still apply, e.g. pick one account first.
- **Baskets & depth**: results by number of legs per basket, how often baskets
  reach each depth, and results by leg number.
- **Open positions**: exposure and floating P/L per magic (P/L per position
  needs the updated collector, see below).
- **Accounts**: balance, equity, equity drawdown chart, worst floating loss.
- **Health**: per terminal status (critical, not syncing, stale, errors),
  problems found in the Experts and Journal logs (AEP failures, emergency
  exits, unknown tickets, error codes, connection failures, failed orders,
  blocked mirror copier), ping, which EAs are running with their magic
  number and fade settings, and EA loads/restarts.

R = net result ÷ (initial SL distance × value of one point × lots). The value
of one point is learned from your own closed trades per symbol. Trades
without an initial SL, or with one under 10 points, have no R.

## Update the collector for floating P/L per magic

The patched MT4Collector_Quant v2.05 and v2.04 files were delivered
separately (they are your own source code, so they are not stored in this
repository). The only change: `open_now.csv` gets three columns at the end
(profit, swap, commission of each open position), read with `OrderSelect`
when the file is written. Same version number, same file tag, nothing else
changes, and readers that use column names (your audit scripts, this
dashboard) keep working.

For each terminal:
1. Copy the file with the same version the terminal runs over its
   `MQL4\Experts\MT4Collector_Quant_v2.0x.mq4`.
2. Open it in MetaEditor and compile (F7). Check the result says 0 errors.
3. The running collector reloads by itself and keeps its inputs.

Terminals you do not update keep working; their positions just show – for
P/L.

## What it reads

| File | Used for |
|---|---|
| `*_DetailedStatementLive.csv` | Closed trades: all statistics, charts and tables |
| `*_open_now.csv` | Open positions (latest file per account) |
| `*_account_snapshots.csv` | Balance / equity chart and floating P/L |
| `*_collector_status.txt` | Collector version and health on the Accounts tab |
| `Experts\yyyymmdd.log`, `Journal\yyyymmdd.log` | Health tab (read by the build script, last 3 days by default: `-LogDays`) |
| `_sync_status*.txt`, `_terminal_identity_map*.txt` | Not-syncing and unmapped-terminal warnings on the Health tab |
| `_DASHBOARD\*.csv.gz`, `status_all.txt`, `sync_all.txt` | The compact copies made by `Build-DashboardData.ps1` (the local page reads these too) |

- Column layouts from collector v1.11, v2.00 and v2.04+ are all supported;
  columns are matched by name.
- The same trade often appears in several files (older tags such as
  `QuantV2`, `QuantV204` are carried into newer ones, and backup copies).
  Trades are merged by account + ticket, keeping the row from the newest
  collector version. The **Files** tab shows how many rows each file
  contributed.
- "Base comment" groups `X`, `X[sl]` and `X[tp]` together. Switch
  **Group comments by** to *Raw comment* to split them.
- Net profit = profit + commission + swap. Max drawdown is measured on
  closed-trade cumulative profit. Times are MT4 server time.
- Floating P/L per open position needs the updated collector (see above).
  Terminals still on the original collector show floating P/L per account
  only.

## Statistics

Per group: trades, win %, net, profit factor, expectancy, gross profit and
loss, average win and loss, payoff, best and worst trade, max drawdown, longest
losing streak, lots, commission + swap, spread cost estimate, TP / SL / other
exits, average hold time, average MFE / MAE in points, SQN, buy vs sell net,
first and last close. The magic table also shows basket count, basket win %
and worst basket. Every table can be sorted and exported to CSV.

## Try it without your data

```
python tools/make_sample_data.py sample
```

Then choose the `sample` folder in the page.
