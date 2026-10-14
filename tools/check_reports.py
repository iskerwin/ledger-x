"""Work the statement figures out again with Beancount and compare them with what LedgerKit wrote
(ReportDumpTests → reports.json): balances as booked, at cost, at market value and converted, the conversions,
income and expenses by month, net worth by month. Exits 1 on any difference larger than a cent.

    python3 tools/check_reports.py <main.bean> <reports.json>
"""
import json
import sys
from collections import defaultdict
from decimal import Decimal

from beancount import loader
from beancount.core import convert, data, inventory, prices
from beancount.plugins import implicit_prices

main, dump = sys.argv[1], sys.argv[2]
got = json.load(open(dump))
date = got["date"]

entries, errors, options = loader.load_file(main)
if errors:
    print(f"beancount: {len(errors)} errors loading the sample (first: {errors[0].message})")
# LedgerKit also takes rates from @ prices and costs in transactions, as this plugin does
entries, _ = implicit_prices.add_implicit_prices(entries, options)
price_map = prices.build_price_map(entries)

import datetime
D = datetime.date.fromisoformat(date)
txns = [e for e in entries if isinstance(e, data.Transaction)]

by_acct = defaultdict(inventory.Inventory)
for t in txns:
    if t.date > D:
        continue
    for p in t.postings:
        by_acct[p.account].add_position(p)


def as_dict(inv):
    out = defaultdict(float)
    for pos in inv:
        out[pos.units.currency] += float(pos.units.number)
    return {c: v for c, v in out.items() if abs(v) > 1e-9}


BASE = options["operating_currency"][0]


def convert_to(inv, target):
    """Beancount converts with a direct price only (or through the cost currency); LedgerKit also goes through
    the operating currency (HKD → CNY → USD). Do the same here: what is left after the direct conversion is
    converted to the operating currency and from there to the target."""
    x = inv.reduce(convert.convert_position, target, price_map, D)
    if target == BASE:
        return x
    out = inventory.Inventory()
    for pos in x:
        if pos.units.currency == target:
            out.add_position(pos)
            continue
        via = convert.convert_position(pos, BASE, price_map, D)
        out.add_amount(convert.convert_amount(via, target, price_map, D) if via.currency == BASE else pos.units)
    return out


def valued(mode):
    out = {}
    for a, inv in by_acct.items():
        if mode == "units":
            x = inv.reduce(convert.get_units)
        elif mode == "cost":
            x = inv.reduce(convert.get_cost)
        elif mode == "market":
            x = inv.reduce(convert.get_value, price_map, D)
        else:
            x = convert_to(inv, mode.split("_")[1])
        d = as_dict(x)
        if d:
            out[a] = d
    return out


problems = []


def close(a, b, tol=0.01):
    return abs(a - b) <= tol


def compare(label, ours, theirs, tol=0.01):
    for k in sorted(set(ours) | set(theirs)):
        a, b = ours.get(k, 0.0), theirs.get(k, 0.0)
        if not close(a, b, tol):
            problems.append(f"{label} {k}: LedgerKit {a:.4f}, Beancount {b:.4f}")


def total(accts, pred):
    out = defaultdict(float)
    for a, d in accts.items():
        if pred(a):
            for c, v in d.items():
                out[c] += v
    return out


for mode, ours in got["modes"].items():
    theirs = valued(mode)
    for a in sorted(set(ours["accounts"]) | set(theirs)):
        compare(f"[{mode}] {a}", ours["accounts"].get(a, {}), theirs.get(a, {}))
    # conversions: what makes each currency balance (negated sum of every account)
    conv = {c: -v for c, v in total(theirs, lambda a: True).items()}
    compare(f"[{mode}] conversions", ours["conversions"], conv)
    nw = total(theirs, lambda a: a.startswith(("Assets:", "Liabilities:")))
    compare(f"[{mode}] net worth", ours["net_worth"], nw)
    earn = total(theirs, lambda a: a.startswith(("Income:", "Expenses:")))
    compare(f"[{mode}] earnings", ours["earnings"], earn)

# this year's income and expenses by account, as booked
year = defaultdict(lambda: defaultdict(float))
for t in txns:
    if datetime.date(2026, 1, 1) <= t.date <= D:
        for p in t.postings:
            if p.account.startswith(("Income:", "Expenses:")):
                year[p.account][p.units.currency] += float(p.units.number)
for a in sorted(set(got["year"]) | set(year)):
    compare(f"[2026] {a}", got["year"].get(a, {}), {c: v for c, v in year.get(a, {}).items() if abs(v) > 1e-9})

# income (shown positive) and expenses by month, as booked
flows = defaultdict(lambda: {"income": defaultdict(float), "expenses": defaultdict(float)})
for t in txns:
    m = t.date.strftime("%Y-%m")
    if m in got["flows"] or ("2026-01" <= m <= "2026-09"):
        for p in t.postings:
            if p.account.startswith("Income:"):
                flows[m]["income"][p.units.currency] -= float(p.units.number)
            elif p.account.startswith("Expenses:"):
                flows[m]["expenses"][p.units.currency] += float(p.units.number)
for m in sorted(set(got["flows"]) | {k for k in flows if "2026-01" <= k <= "2026-09"}):
    for side in ("income", "expenses"):
        compare(f"[{m} {side}]", got["flows"].get(m, {}).get(side, {}), flows[m][side])

# net worth at each month end, as booked
for m, ours in sorted(got["worth"].items()):
    y, mo = int(m[:4]), int(m[5:])
    end = (datetime.date(y + (mo == 12), mo % 12 + 1, 1) - datetime.timedelta(days=1))
    end = min(end, D)
    w = defaultdict(float)
    for t in txns:
        if t.date <= end:
            for p in t.postings:
                if p.account.startswith(("Assets:", "Liabilities:")):
                    w[p.units.currency] += float(p.units.number)
    compare(f"[net worth {m}]", ours, w)

# only HKD, converted to CNY
hk = inventory.Inventory()
for a, inv in by_acct.items():
    if a.startswith(("Assets:", "Liabilities:")):
        for pos in inv:
            if pos.units.currency == "HKD":
                hk.add_position(pos)
compare("[HKD only, in CNY]", got["hkd_in_cny"], as_dict(convert_to(hk, "CNY")))

if problems:
    print(f"{len(problems)} differences from Beancount:")
    for p in problems[:80]:
        print("  " + p)
    sys.exit(1)
print(f"Reports match Beancount ({len(got['modes'])} valuations, {len(got['flows'])} months, {len(got['worth'])} month ends)")
