#!/usr/bin/env python3
"""Generate fake MT4Collector_Quant output for trying out the dashboard.

Writes a folder tree like the real one (one Reports folder per terminal) with
the same column layouts as collector v1.11, v2.00 and v2.04+, including rows
duplicated across file tags. Usage:

    python make_sample_data.py <output-folder>
"""
import os
import random
import sys
from datetime import datetime, timedelta

H_V1 = ("source,collector_version,machine_label,terminal_label,campaign,account,account_currency,server,ticket,open_time,close_time,type,lots,symbol,digits,point_size,"
        "open_price,close_price,initial_sl,initial_tp,last_seen_sl,last_seen_tp,final_sl,final_tp,magic,comment,profit,commission,swap,net_profit,duration_seconds,first_seen,"
        "first_spread_points,avg_spread_points,max_spread_points,mfe_price_move,mae_price_move,mfe_points,mae_points,seconds_to_mfe,seconds_to_mae,first_seen_balance,first_seen_equity,recorded_at")
H_V200 = H_V1.replace(",recorded_at", ",open_spread_cost_estimate_account_ccy,close_spread_points_observed,close_spread_cost_estimate_account_ccy,recorded_at")
H_V204 = ("source,collector_version,machine_label,terminal_label,campaign,account,account_currency,server,ticket,open_time,close_time,type,lots,symbol,digits,point_size,"
          "open_price,close_price,initial_sl,initial_tp,last_seen_sl,last_seen_tp,final_sl,final_tp,initial_sl_points,initial_tp_points,flag_no_initial_tp,flag_wide_initial_sl,"
          "magic,comment,base_comment,exit_reason,exit_reason_source,profit,commission,swap,net_profit,duration_seconds,first_seen,first_spread_points,avg_spread_points,"
          "max_spread_points,mfe_price_move,mae_price_move,mfe_points,mae_points,seconds_to_mfe,seconds_to_mae,first_seen_balance,first_seen_equity,"
          "open_spread_cost_estimate_account_ccy,close_spread_points_observed,close_spread_cost_estimate_account_ccy,basket_id,basket_leg_seq,basket_anchor_close,basket_gap_seconds,recorded_at")
H_SNAP = ("collector_version,machine_label,terminal_label,campaign,account,server,time,balance,equity,floating_net,margin,free_margin,margin_level_pct,open_market_orders,"
          "pending_orders,long_orders,short_orders,long_lots,short_lots,total_market_lots,approx_notional_account_ccy,gross_profit_open,gross_loss_open,spread_cost_est_open_positions")
H_OPEN = ("machine_label,terminal_label,campaign,account,ticket,type,lots,symbol,open_time,open_price,initial_sl,initial_tp,last_sl,last_tp,initial_sl_points,"
          "flag_no_initial_tp,flag_wide_initial_sl,magic,comment,base_comment,mfe_points,mae_points,max_spread_points,last_seen")

SYMBOLS = {"EURUSD": (5, 1.137), "AUDCAD": (5, 0.905), "NZDUSD": (5, 0.560), "EURJPY": (3, 185.5), "XAUUSD": (2, 4400.0)}
STRATS = [(1001, "TREND_ENTRY_A"), (1002, "RANGE_REJECT_B"), (1003, "RANGE_REJECT_C"), (1004, "PYRAMID_ADAPTIVE"), (1005, "RSI_MIRROR")]
SERVER = "Broker-Demo"


def ts(d):
    return d.strftime("%Y.%m.%d %H:%M:%S")


def make_trades(rng, machine, terminal, campaign, account, start, n, edge):
    rows = []
    ticket = 4000000000 + account % 1000 * 10000
    t = start
    basket_no = 0
    while len(rows) < n:
        magic, comment = rng.choice(STRATS)
        sym = rng.choice(list(SYMBOLS))
        digits, price = SYMBOLS[sym]
        point = 10 ** -digits
        side = rng.choice(["BUY", "SELL"])
        basket_no += 1
        legs = rng.randint(1, 5)
        anchor = t + timedelta(minutes=rng.randint(30, 900))
        hit_tp = rng.random() < 0.55 + edge
        for leg in range(1, legs + 1):
            ticket += rng.randint(1, 40)
            ot = t + timedelta(minutes=leg * rng.randint(1, 20))
            lots = [0.01, 0.01, 0.03, 0.03, 0.05][leg - 1]
            pts = rng.randint(80, 260)
            move = pts if hit_tp else -pts * 1.6
            pl = round(move * lots * (1.0 if digits != 2 else 0.1), 2)
            comm, swap = round(-lots * 6, 2), round(rng.choice([0, 0, -0.1, -0.3]) * lots * 10, 2)
            exit_reason = "TP" if hit_tp else "SL"
            raw = comment + ("[tp]" if hit_tp else "[sl]")
            if rng.random() < 0.05:
                exit_reason, raw = "CLOSE_OTHER", comment
            op = round(price + rng.uniform(-0.01, 0.01) * price, digits)
            cp = round(op + (move * point if side == "BUY" else -move * point), digits)
            sl_pts, tp_pts = 200.0, 200.0
            sgn = 1 if side == "BUY" else -1
            bid = f"{terminal}_{magic}_{sym}_{side}_{int(anchor.timestamp())}"
            rows.append(dict(
                ticket=ticket, open_time=ts(ot), close_time=ts(anchor), type=side, lots=f"{lots:.2f}", symbol=sym, digits=digits,
                point_size=f"{point:.10f}", open_price=op, close_price=cp, sl=round(op - sgn * sl_pts * point, digits),
                tp=round(op + sgn * tp_pts * point, digits), sl_pts=sl_pts, tp_pts=tp_pts,
                magic=magic, comment=raw, base_comment=comment, exit_reason=exit_reason, profit=f"{pl:.2f}", commission=f"{comm:.2f}", swap=f"{swap:.2f}",
                net=f"{pl + comm + swap:.2f}", duration=int((anchor - ot).total_seconds()), mfe=rng.randint(10, 300), mae=rng.randint(10, 300),
                spread=rng.randint(10, 60), basket_id=bid, leg=leg, anchor=ts(anchor),
            ))
        t = anchor + timedelta(minutes=rng.randint(5, 240))
    return rows


def v204_line(r, machine, terminal, campaign, account, version):
    return ",".join(str(x) for x in [
        "LIVE_TRACKER", version, machine, terminal, campaign, account, "USD", SERVER, r["ticket"], r["open_time"], r["close_time"], r["type"], r["lots"], r["symbol"],
        r["digits"], r["point_size"], r["open_price"], r["close_price"], r["sl"], r["tp"], r["sl"], r["tp"], r["sl"], r["tp"], r["sl_pts"], r["tp_pts"], 0, 0,
        r["magic"], r["comment"], r["base_comment"], r["exit_reason"], "comment_tag", r["profit"], r["commission"], r["swap"], r["net"], r["duration"],
        r["open_time"], r["spread"], r["spread"], r["spread"] * 2, 0.0005, 0.0019, r["mfe"], r["mae"], 600, 900, "500000.00", "499999.81", "0.12", 24.0, "0.17",
        r["basket_id"], r["leg"], r["anchor"], 90, r["close_time"]])


def old_line(r, machine, terminal, campaign, account, version, with_spread):
    vals = ["LIVE_TRACKER", version, machine, terminal, campaign, account, "USD", SERVER, r["ticket"], r["open_time"], r["close_time"], r["type"], r["lots"], r["symbol"],
            r["digits"], r["point_size"], r["open_price"], r["close_price"], r["sl"], r["tp"], r["sl"], r["tp"], r["sl"], r["tp"], r["magic"], r["comment"],
            r["profit"], r["commission"], r["swap"], r["net"], r["duration"], r["open_time"], r["spread"], r["spread"], r["spread"] * 2, 0.0005, 0.0019, r["mfe"], r["mae"],
            600, 900, "500000.00", "499999.81"]
    if with_spread:
        vals += ["0.12", 24.0, "0.17"]
    vals.append(r["close_time"])
    return ",".join(str(x) for x in vals)


def write(path, text, utf16=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if utf16:
        with open(path, "wb") as f:
            f.write(b"\xff\xfe" + text.encode("utf-16-le"))
    else:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)


def main(out):
    rng = random.Random(7)
    start = datetime(2026, 8, 20, 1, 0, 0)
    terminals = [("HOME", "Terminal_1", "CAMPAIGN_A", 10000001, 0.05), ("HOME", "Terminal_10", "CAMPAIGN_B", 10000002, -0.08),
                 ("VPS", "M15_Terminal", "CAMPAIGN_C", 10000003, 0.0)]
    for machine, terminal, campaign, account, edge in terminals:
        tdir = os.path.join(out, terminal)
        folder = os.path.join(tdir, "Reports")
        prefix = f"{machine}_{terminal}_{account}"
        rows = make_trades(rng, machine, terminal, campaign, account, start, 900, edge)
        old, new = rows[:300], rows
        # older tag: v2.00 header with first 300 trades (duplicated in the newer file)
        lines = [H_V200] + [old_line(r, machine, terminal, campaign, account, "2.00", True) for r in old]
        write(os.path.join(folder, prefix + "_QuantV2_DetailedStatementLive.csv"), "\r\n".join(lines) + "\r\n")
        # current tag: v2.05 header with everything
        lines = [H_V204] + [v204_line(r, machine, terminal, campaign, account, "2.05") for r in new]
        write(os.path.join(folder, prefix + "_QuantV205_DetailedStatementLive.csv"), "\r\n".join(lines) + "\r\n", utf16=(terminal == "Terminal_10"))
        if terminal == "M15_Terminal":
            # untagged v1.11 file, one unquoted comma inside a comment
            extra = make_trades(rng, machine, terminal, "CAMPAIGN_OLD", account, start - timedelta(days=10), 40, 0.1)
            for r in extra:
                r["ticket"] -= 9000000
            extra[0]["comment"] = "RSI,manual close"
            lines = [H_V1] + [old_line(r, machine, terminal, "CAMPAIGN_OLD", account, "1.11", False) for r in extra]
            write(os.path.join(folder, f"{machine}_{terminal}_{account}_DetailedStatementLive.csv"), "\n".join(lines) + "\n")
        # snapshots every minute
        bal = 500000.0
        snaps = [H_SNAP]
        closes = sorted((r["close_time"], float(r["net"])) for r in new)
        ci = 0
        t = start
        end = datetime.strptime(new[-1]["close_time"], "%Y.%m.%d %H:%M:%S")
        while t <= end:
            while ci < len(closes) and closes[ci][0] <= ts(t):
                bal += closes[ci][1]
                ci += 1
            fl = round(rng.uniform(-40, 25), 2)
            if ts(t) == ts(start + timedelta(days=12, minutes=7)):
                fl = -2500.0
            snaps.append(f"2.05,{machine},{terminal},{campaign},{account},{SERVER},{ts(t)},{bal:.2f},{bal + fl:.2f},{fl:.2f},6.81,{bal - 7:.2f},7343540.68,4,0,3,1,0.05,0.01,0.06,9492.11,0.03,-1.11,0.62")
            t += timedelta(minutes=1)
        write(os.path.join(folder, prefix + "_QuantV205_account_snapshots.csv"), "\n".join(snaps) + "\n")
        # open positions: newest file and a stale older-tag file
        last_seen = ts(end)
        patched = terminal == "Terminal_1"
        op = [H_OPEN + (",profit,swap,commission" if patched else "")]
        for i in range(12):
            magic, comment = rng.choice(STRATS)
            sym = rng.choice(list(SYMBOLS))
            row = f"{machine},{terminal},{campaign},{account},{5000000000 + i},{rng.choice(['BUY', 'SELL'])},0.0{rng.randint(1, 5)},{sym},{ts(end - timedelta(hours=i))},0.56052,0.56252,0.55852,0.56252,0.55741,200.0,0,0,{magic},{comment},{comment},{rng.randint(5, 250)},{rng.randint(5, 250)},94.00,{last_seen}"
            if patched:
                row += f",{rng.uniform(-30, 20):.2f},{rng.choice([0, -0.12, -0.3]):.2f},-0.06"
            op.append(row)
        op.append(f"#END,rows,12,run,1700000000_{account},written,{last_seen}")
        write(os.path.join(folder, prefix + "_QuantV205_open_now.csv"), "\n".join(op) + "\n")
        write(os.path.join(folder, prefix + "_QuantV2_open_now.csv"), "\n".join([H_OPEN, op[1].replace(last_seen, ts(end - timedelta(days=9)))]) + "\n")
        write(os.path.join(folder, prefix + "_QuantV205_owner.csv"), f"1700000000_{account},C:\\Users\\you\\AppData\\Roaming\\MetaQuotes\\Terminal\\HASH,{account},{last_seen}\n")
        status = (f"MT4Collector Quant v2.05\nUpdated: {last_seen}\nMachine: {machine}\nTerminal: {terminal}\nCampaign: {campaign}\nAccount: {account}\n"
                  f"Server: {SERVER}\nCurrent OrdersTotal: 12\nconnected: YES\nterminal_company: SampleBroker\ntimer_stalls_detected: 74\nfile_tag: QuantV205\n#END\n")
        write(os.path.join(folder, prefix + "_QuantV205_collector_status.txt"), status)
        write_logs(rng, tdir, terminal, account, end)
    write(os.path.join(out, "_sync_status_HOME.txt"),
          "AutoSync version: MT4-T-AUTOID-3.5-HOME-QUANT\nMachine: HOMEPC\nSync profile: HOME\nRun: 2026-12-21 13:30:00\n\n"
          "Terminal_1 account=10000001 hash=AAA copied=14 mismatches=0\nTerminal_10 account=10000002 hash=BBB copied=20 mismatches=0\n"
          "Terminal_7 account=10000007 SOURCE_NOT_DISCOVERED\n")
    write(os.path.join(out, "_terminal_identity_map_HOME.txt"),
          "MT4_Terminals AUTO-ID map (HOME profile only)\nUpdated=2026-12-21 13:30:00\n\n"
          "Terminal_1 | account=10000001 | hash=AAA | data=C:\\x\nTerminal_10 | account=10000002 | hash=BBB | data=C:\\y\n"
          "UNMAPPED | account=10000003 | hash=CCC | data=C:\\z\n")
    t7 = os.path.join(out, "Terminal_7")
    write(os.path.join(t7, "_sync_status.txt"), "AutoSync version: MT4-T-AUTOID-3.5-HOME-QUANT\nLogical terminal: Terminal_7\n"
          "Expected account: 10000007\nRun started: 2026-12-21 13:30:00\nSTATUS: SOURCE NOT DISCOVERED\n")
    print("sample data written to", out)


def write_logs(rng, tdir, terminal, account, end):
    """Experts and Journal logs in MT4 format: level<TAB>time<TAB>text, CRLF."""
    ea = "Sample_Pyramid_EA"
    for back in range(3):
        day = end - timedelta(days=back)
        name = day.strftime("%Y%m%d") + ".log"
        ex, jr = [], []
        def L(lines, level, h, m, text):
            lines.append(f"{level}\t{h:02d}:{m:02d}:{rng.randint(0, 59):02d}.{rng.randint(0, 999):03d}\t{text}")
        if back == 2:
            L(ex, 0, 0, 1, f"Expert {ea} EURUSD,M15: loaded successfully")
            L(ex, 0, 0, 1, f"{ea} EURUSD,M15 inputs: Pair_1=EURUSD; InpLotStage1=0.01; MagicNumber=1001; InpFadeBeforeFilters=true; InpReverseAfterFilters=false; InpMaxLegs=10; ")
            L(ex, 0, 0, 2, f"{ea} EURUSD,M15: initialized")
        for h in range(0, 24, 2):
            L(ex, 0, h, 5, f"{ea} EURUSD,M15: AUDCAD REJECTED: no raw signal")
            L(ex, 0, h, 15, f"{ea} EURUSD,M15: Entry blocked on AUDJPY: spread too wide (161 pts).")
            L(ex, 2, h, 20, f"{ea} EURUSD,M15: open #20516{rng.randint(10000, 99999)} buy 0.01 EURAUD at 1.62279 sl: 1.61875 tp: 1.62385 ok")
            L(ex, 0, h, 30, f"MT4Collector_Quant_v2.05 EURUSD,H1: Collector: timer gap of {rng.randint(5, 20)}s detected (poll=1s) - possible terminal stall, stalls so far={h}")
        if terminal == "Terminal_1" and back == 0:
            L(ex, 0, 0, 0, f"{ea} EURUSD,M15: AEP sync retry 1/3 failed for ticket 4100000001. Error: 132")
            L(ex, 0, 0, 0, f"{ea} EURUSD,M15: AEP sync EXHAUSTED all 3 attempts for ticket 4100000002 -- broker SL/TP may be stale until the next regular cycle retries again.")
            L(ex, 3, 9, 15, f"{ea} EURUSD,M15: unknown ticket 4100000003 for OrderClose function")
            L(ex, 0, 9, 15, f"{ea} EURUSD,M15: AEP close retry 2/3 failed for ticket 4100000003 on CADJPY. Error: 4108")
            L(ex, 0, 9, 16, f"{ea} EURUSD,M15: AEP close EXHAUSTED all 3 attempts for ticket 4100000003 on CADJPY -- still open.")
            L(ex, 0, 9, 16, f"{ea} EURUSD,M15: Alert: EMERGENCY EXIT: Hard Stop Loss breached (from AEP) on CADJPY")
        if terminal == "M15_Terminal":
            L(ex, 0, 3, 40, "Sample_MirrorCopier GBPUSD,H1: MirrorCopier: PAIR_BLOCKED - terminal not connected")
            L(ex, 0, 23, 59, f"{ea} EURUSD,M15: uninit reason 5")
        L(jr, 0, 4, 0, f"'{account}': login on Broker-Demo through Demo.Europe.1 (ping: 58.53 ms)")
        L(jr, 0, 4, 1, f"'{account}': ping to current access point Demo.Europe.1 is {rng.uniform(50, 70):.2f} ms")
        if back == 0:
            L(jr, 1, 10, 20, f"'{account}': connect failed [No connection]")
            L(jr, 0, 10, 25, f"'{account}': ping to current access point Demo.Asia.5 is 480.68 ms")
            L(jr, 2, 11, 0, f"'{account}': order buy 0.01 EURUSD opening at market sl: 1.13000 tp: 1.14000 failed [Invalid stops]")
        ex.sort(key=lambda x: x.split("\t")[1])
        jr.sort(key=lambda x: x.split("\t")[1])
        write(os.path.join(tdir, "Experts", name), "\r\n".join(ex) + "\r\n")
        write(os.path.join(tdir, "Journal", name), "\r\n".join(jr) + "\r\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
