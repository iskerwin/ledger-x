"""Work out, with Beancount itself, what the plugins the app runs report for a ledger (PluginTests):

    python3 tools/plugins_expected.py LedgerKit/Tests/LedgerKitTests/Fixtures/plugins/main.bean \
        LedgerKit/Tests/LedgerKitTests/Fixtures/plugins/expected.json

- missing_commodities  check_commodity: the currencies without a commodity directive, in Beancount's order
- leafonly             the accounts leafonly reports
- duplicates           noduplicates: [file:line of the entry reported, file:line of the one it repeats]
- prices               every price entry after implicit_prices: [date, currency, number, quote, made by the plugin]
- latest               the latest price of each pair (Beancount's price map)
"""
import json
import os
import re
import sys

from beancount import loader
from beancount.core import data, prices
from beancount.plugins.check_commodity import CheckCommodityError
from beancount.plugins.leafonly import LeafOnlyError
from beancount.core.compare import CompareError

main, dest = sys.argv[1], sys.argv[2]
root = os.path.dirname(os.path.abspath(main))
entries, errors, options = loader.load_file(main)


def where(meta):
    return f"{os.path.relpath(meta['filename'], root)}:{meta['lineno']}"


out = {"missing_commodities": [], "leafonly": [], "duplicates": [], "prices": [], "latest": {}}
for e in errors:
    if isinstance(e, CheckCommodityError):
        out["missing_commodities"].append(re.search(r"'(.+)'", e.message).group(1))
    elif isinstance(e, LeafOnlyError):
        out["leafonly"].append(re.search(r"'(.+)'", e.message).group(1))
    elif isinstance(e, CompareError):
        other = e.message.split(" == ", 1)[1]
        f = re.search(r"'filename': '([^']+)', 'lineno': (\d+)", other)
        out["duplicates"].append([where(e.entry.meta), f"{os.path.relpath(f.group(1), root)}:{f.group(2)}"])
for p in entries:
    if isinstance(p, data.Price):
        out["prices"].append([p.date.isoformat(), p.currency, float(p.amount.number), p.amount.currency,
                              "__implicit_prices__" in p.meta])
pm = prices.build_price_map(entries)
for (base, quote) in pm.forward_pairs:
    d, n = prices.get_latest_price(pm, (base, quote))
    out["latest"][f"{base}/{quote}"] = [d.isoformat(), float(n)]
out["duplicates"].sort()
with open(dest, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")
print(json.dumps({k: (len(v) if isinstance(v, (list, dict)) else v) for k, v in out.items()}))
others = [e for e in errors if not isinstance(e, (CheckCommodityError, LeafOnlyError, CompareError))]
for e in others:
    print("other:", e.message.splitlines()[0])
