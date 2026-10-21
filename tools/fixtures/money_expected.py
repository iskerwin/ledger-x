"""Work out, with Beancount itself, the figures the money API tests check LedgerKit against
(MoneyApiTests): balances on the given days, holdings and their lots, the latest price of each pair, and the
totals of every account and parent account on the last day.

    F=LedgerKit/Tests/LedgerKitTests/Fixtures
    python3 tools/fixtures/money_expected.py $F/realistic/main.bean $F/money/realistic.json 2024-06-30 2025-12-31 2026-10-08
    python3 tools/fixtures/money_expected.py $F/money/main.bean $F/money/edge.json 2024-04-10 2024-06-30 2024-07-31

Run it again whenever a sample changes.
"""
import datetime
import json
import os
import sys
from collections import defaultdict

from beancount import loader
from beancount.core import data

main, dest, DATES = sys.argv[1], sys.argv[2], sys.argv[3:]
entries, errors, options = loader.load_file(main)
txns = [e for e in entries if isinstance(e, data.Transaction)]   # pads already turned into transactions


def num(d):
    return float(d)


def balances(date):
    """units by account and currency, every transaction up to and including `date`"""
    day = datetime.date.fromisoformat(date)
    out = defaultdict(lambda: defaultdict(float))
    for t in txns:
        if t.date > day:
            continue
        for p in t.postings:
            out[p.account][p.units.currency] += num(p.units.number)
    return {a: {c: round(n, 8) for c, n in cs.items() if abs(n) > 1e-9} for a, cs in out.items() if any(abs(n) > 1e-9 for n in cs.values())}


# holdings: the lots held at cost at the end, by account, commodity and cost currency
from beancount.core import inventory
held = defaultdict(inventory.Inventory)
for t in txns:
    for p in t.postings:
        held[p.account].add_position(p)
holdings = []
for acct, i in sorted(held.items()):
    groups = defaultdict(list)
    for pos in i:
        if pos.cost is None or pos.units.number == 0:
            continue
        groups[(pos.units.currency, pos.cost.currency)].append(pos)
    for (c, q), ps in sorted(groups.items()):
        lots = sorted(({"units": num(p.units.number), "cost": num(p.cost.number), "date": p.cost.date.isoformat()} for p in ps),
                      key=lambda l: (l["date"], l["cost"]))
        holdings.append({"account": acct, "currency": c, "cost_currency": q,
                         "units": round(sum(l["units"] for l in lots), 8),
                         "cost": round(sum(l["units"] * l["cost"] for l in lots), 8), "lots": lots})

# latest price directive of each pair (as written in the ledger; no implied prices)
latest = {}
for e in entries:
    if isinstance(e, data.Price):
        k = e.currency + "/" + e.amount.currency
        if k not in latest or e.date >= datetime.date.fromisoformat(latest[k]["date"]):
            latest[k] = {"date": e.date.isoformat(), "number": num(e.amount.number)}

# totals of every account and each of its parents, at the last day
end = balances(DATES[-1])
tree = defaultdict(lambda: defaultdict(float))
for a, cs in end.items():
    parts = a.split(":")
    for k in range(1, len(parts) + 1):
        for c, n in cs.items():
            tree[":".join(parts[:k])][c] += n
tree = {a: {c: round(n, 8) for c, n in cs.items() if abs(n) > 1e-9} for a, cs in tree.items()}

out = {"dates": DATES, "balances": {d: balances(d) for d in DATES}, "holdings": holdings, "prices": latest, "tree": tree}
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")
print(f"{len(txns)} transactions; {sum(len(v) for v in out['balances'].values())} account balances; "
      f"{len(holdings)} holdings; {len(latest)} price pairs; {len(tree)} tree nodes")
