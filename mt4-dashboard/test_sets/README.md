# Terminal_15 fader test sets, v2 (HC172 MARTINGALE master 2604172, account 48753031)

Three sets, all built from `01_OFF_FADER_M5.set`. Master magic 2604172, full copy (`InpMatchComment` empty), 1x source lots.

## Compatibility fix (why v1 would not have copied)
Master 2604172 opens every trade with a stop loss and NO take profit (506 of 506 trades in the Nov data have `flag_no_initial_tp=1`).
The base set has `InpAllowMissingMasterTP=false`, which needs both master SL and TP, so nothing would have been copied.
All three sets therefore use the same missing-TP policy, the one already used by the 956 presets:
- `InpAllowMissingMasterTP=true`
- `InpFaderDisasterSLPips=30` (fallback protective stop on every copy; `InpFaderSLMultiplier` stays 0). Check 30 pips is what you want: at 0.50 lots it is about $150 per position, at 0.01 lots about $3.
These two settings must stay together. Do not enable missing-TP copying with both fallback stops at 0.

## Immediate copy
`InpMinMasterAgeSeconds=0` and `InpSpreadWaitMaxSeconds=0` (the base set waits 30 s). `InpMaxMasterAgeSeconds=300` is unchanged: a master trade older than 300 s is not copied.

## The three arms
| File | Fader magic | Difference from the reference |
|---|---|---|
| T15_A_IMMEDIATE_REF.set | 261128101 | none: one copy per eligible master ticket, no monetary loss cap |
| T15_B_DAILYLOCK_150.set | 261128102 | `InpUseDailyLossGuard=true`, `InpDailyLossLimit=-150`: when today's realized + floating fader result reaches -$150 it closes and locks copying until the next trading day |
| T15_C_FLOATCAP_150.set | 261128103 | `InpFaderMaxFloatingLossUSD=150`: closes at -$150 floating loss, then allows new copying after 15 minutes (`InpFloatingCapCooldownMin=15`) |
B tests a daily shutdown, C a temporary floating-loss shutdown. Both cap FADER losses; neither caps master profits.

## Notes
- `InpUseExposureLimits=false` in all three, so the 20-position / 0.2-lot values in the file are inactive. Exposure is 1x source lots.
- NOSYNC is removed until it has a defined independent exit.
- These faders run on the same account as the master, which already has 20 fader magics copying it. Stop the PREWIN / PILEON faders (7691, 7700-7703) first or exposure goes up.
- Judging: at least 14 days and 50 baskets per arm; compare net, max drawdown, profit factor, net / drawdown, worst day. Arms share the same master trades, so compare them with each other.
- Not included (EA has no input): pause after a fall from peak; hours filter.
