# Terminal_15 test sets (HC172 MARTINGALE master 2604172, account 48753031)

Six fader sets, all built from `01_OFF_FADER_M5.set` (the T28 fader set you already run). Only the lines listed below differ.
Common to every set: master magic **2604172**, full copy (`InpMatchComment` empty), `InpLotMultiplier=1.0`, same exposure limits (20 positions / 0.2 lots) as the base set.

| File | Fader magic | Label | What it changes vs the OFF arm | What it tests |
|---|---|---|---|---|
| T15_01_ONECOPY_OFF.set | 261128101 | T15 1COPY OFF | nothing (baseline) | one fader per master trade, no caps |
| T15_02_DAILYLOCK_150.set | 261128102 | T15 DL150 | `InpUseDailyLossGuard=true`, `InpDailyLossLimit=-150` | stop copying for the day after -$150 |
| T15_03_DAILYLOCK_250.set | 261128103 | T15 DL250 | same, `-250` | same, looser |
| T15_04_FLOATCAP_150.set | 261128104 | T15 FC150 | `InpFaderMaxFloatingLossUSD=150` | close the fader basket at -$150 floating |
| T15_05_FLOATCAP_225.set | 261128105 | T15 FC225 | same, `225` | same, looser |
| T15_06_EXPERIMENT_NOSYNC.set | 261128106 | T15 NOSYNC | `InpSyncCloseWithMaster=false` | fader does NOT close when the master closes (Friday-flat and time-stop closes no longer force the fader out). Riskier: positions then live until their own TP/SL or the daily flatten (`InpFlattenTime=22:30`). Run on a demo first. |

## Before you start (important)
1. These faders run on the same account as the master (Terminal_15, account 48753031). That account already has 20 fader magics copying the same master trades.
   If you add these six on top, exposure goes UP, not down. Stop the PREWIN / PILEON faders first: 7691, 7700, 7701, 7702, 7703 (profit factor about 0.5).
2. Run each set on its own chart (EURUSD, M5), one chart per set, as `Master_Exact_Mirror_Multi_3.71`.
3. Arms 01-05 share the same master trades, so compare them against each other, not against the old faders.

## How to judge (read in the dashboard: Roster > Families, or By magic filtered to account 48753031)
- Run at least 14 days AND 50 baskets per arm.
- Compare: net, max drawdown, profit factor, net / drawdown, worst day.
- Stop an arm early if its drawdown passes $1,500 (the baseline arm in my replay: about -1,600 with all copies).
- Expected from the replays (not guarantees): 1 copy per master trade made +538 with drawdown -1,627 since 1 Nov; daily lock 150-250 cut drawdown about 45% for about 20% of profit; floating caps below $225 cut winners as well as losers.

## Not included (needs EA support, not a set file)
- Pause 24 h after a fall of $250 from the fader's own peak (no such input in the EA).
- Hours filter 00:00-06:00 (the only time inputs are the rollover window and the daily flatten time; I could not confirm what `InpRolloverPolicy` does).
