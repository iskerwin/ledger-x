"""Work out, with Beancount itself, what the year review (YearReviewTests) is checked against, as booked (each
currency on its own): income and expenses by year, by month and by category group, the change in assets and
liabilities, and net worth at the end of the year before and of each month.

    F=LedgerKit/Tests/LedgerKitTests/Fixtures
    python3 tools/fixtures/year_expected.py $F/realistic/main.bean $F/money/realistic-years.json 2026-10-08
    python3 tools/fixtures/year_expected.py $F/money/main.bean $F/money/edge-years.json 2024-07-31

The last argument is "today": the current year runs up to it. Run it again whenever a sample changes.
"""
import calendar
import datetime
import json
import sys
from collections import defaultdict

from beancount import loader
from beancount.core import data

main, dest, today = sys.argv[1], sys.argv[2], sys.argv[3]
entries, errors, options = loader.load_file(main)
txns = [e for e in entries if isinstance(e, data.Transaction)]   # pads already turned into transactions
TODAY = datetime.date.fromisoformat(today)


def add(d, k, c, n):
    d[k][c] = d[k].get(c, 0.0) + float(n)


def clean(d):
    return {k: {c: round(n, 6) for c, n in cs.items() if abs(n) > 1e-9} for k, cs in d.items() if any(abs(n) > 1e-9 for n in cs.values())}


def holdings_at(day):
    """assets and liabilities by currency, up to and including `day`"""
    out = defaultdict(float)
    for t in txns:
        if t.date > day:
            continue
        for p in t.postings:
            if p.account.startswith(("Assets:", "Liabilities:")):
                out[p.units.currency] += float(p.units.number)
    return {c: round(n, 6) for c, n in out.items() if abs(n) > 1e-9}


def side_at(prefix, day):
    out = defaultdict(float)
    for t in txns:
        if t.date > day:
            continue
        for p in t.postings:
            if p.account.startswith(prefix):
                out[p.units.currency] += float(p.units.number)
    return out


years = sorted({t.date.year for t in txns if t.flag != "P"})
out = {"today": today, "years": {}}
for y in years:
    through = min(datetime.date(y, 12, 31), TODAY)
    inc, exp = defaultdict(float), defaultdict(float)
    months = defaultdict(lambda: defaultdict(lambda: {"income": {}, "expenses": {}}))
    cats = defaultdict(dict)
    for t in txns:
        if t.date.year != y or t.date > through:
            continue
        m = t.date.strftime("%Y-%m")
        for p in t.postings:
            c, n = p.units.currency, float(p.units.number)
            if p.account.startswith("Income:"):
                inc[c] += -n
                mm = months[m]["x"]["income"]; mm[c] = mm.get(c, 0.0) - n
            elif p.account.startswith("Expenses:"):
                exp[c] += n
                mm = months[m]["x"]["expenses"]; mm[c] = mm.get(c, 0.0) + n
                g = ":".join(p.account.split(":")[:2])
                cats[g][c] = cats[g].get(c, 0.0) + n
    before = datetime.date(y - 1, 12, 31)
    worth = {}
    for mo in range(1, 13):
        last = datetime.date(y, mo, calendar.monthrange(y, mo)[1])
        if datetime.date(y, mo, 1) > through:
            break
        worth[f"{y}-{mo:02d}"] = holdings_at(min(last, through))
    a0, a1 = side_at("Assets:", before), side_at("Assets:", through)
    l0, l1 = side_at("Liabilities:", before), side_at("Liabilities:", through)
    out["years"][str(y)] = {
        "through": through.isoformat(),
        "income": {c: round(n, 6) for c, n in inc.items() if abs(n) > 1e-9},
        "expenses": {c: round(n, 6) for c, n in exp.items() if abs(n) > 1e-9},
        "months": {m: {k: {c: round(n, 6) for c, n in v.items() if abs(n) > 1e-9} for k, v in d["x"].items()} for m, d in sorted(months.items())},
        "categories": clean(cats),
        "assets_change": {c: round(a1.get(c, 0) - a0.get(c, 0), 6) for c in set(a0) | set(a1) if abs(a1.get(c, 0) - a0.get(c, 0)) > 1e-9},
        "liabilities_change": {c: round(l1.get(c, 0) - l0.get(c, 0), 6) for c in set(l0) | set(l1) if abs(l1.get(c, 0) - l0.get(c, 0)) > 1e-9},
        "worth_start": holdings_at(before),
        "worth_by_month": worth,
    }
with open(dest, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")
print(f"{len(years)} years: " + ", ".join(f"{y}: {len(out['years'][str(y)]['categories'])} categories" for y in years))
