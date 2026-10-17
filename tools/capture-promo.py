#!/usr/bin/env python3
"""Capture real simulator screens using the bundled, fictional ledger.

Build/install Ledger first, then run with a booted simulator UDID:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 tools/capture-promo.py UDID
The screenshot hooks load local data only; they never connect to a remote ledger.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/screenshots/latest"
DEVICE = sys.argv[1]
BUNDLE = "com.iskerwin.ledger"
SHOTS = [
    ("overview", {"TAB": "overview"}),
    ("add", {"TAB": "add", "FILL": "1"}),
    ("categories", {"TAB": "add", "FILL": "1", "ALLCATS": "1"}),
    ("journal", {"TAB": "journal", "FILTERS": "month"}),
    ("calendar", {"TAB": "journal", "CALENDAR": "1"}),
    ("day", {"TAB": "journal", "CAL_DAY": "1"}),
    ("detail", {"TAB": "journal", "OPEN_LINK": "sub-icloud"}),
    ("accounts", {"TAB": "accounts"}),
    ("register", {"TAB": "accounts", "OPEN_ACCOUNT": "Assets:Bank:CMB"}),
    ("card", {"TAB": "accounts", "OPEN_ACCOUNT": "Liabilities:CreditCard:CMB"}),
    ("holdings", {"TAB": "accounts", "OPEN_HOLDINGS": "1", "HOLDING_OPEN": "1"}),
    ("reports", {"TAB": "reports", "QUESTION": "where"}),
    ("comparison", {"TAB": "reports", "QUESTION": "change"}),
    ("forecast", {"TAB": "reports", "REPORT": "forecast"}),
    ("year", {"TAB": "reports", "REPORT": "year", "YEAR": "2025"}),
    ("subscriptions", {"TAB": "reports", "REPORT": "subscriptions"}),
    ("query", {"TAB": "reports", "REPORT": "b:payees"}),
    ("settings", {"TAB": "settings"}),
    ("sync", {"TAB": "overview", "SYNC": "1"}),
    ("privacy", {"TAB": "overview", "PRIVACY": "1"}),
    ("dark", {"TAB": "overview", "DARK": "1"}),
]


def sim(*args, env=None, check=True):
    return subprocess.run(["xcrun", "simctl", *args], env=env, check=check,
                          timeout=60, capture_output=True, text=True)


devices = json.loads(sim("list", "devices", "--json").stdout)["devices"]
runtime, device = next((runtime, d) for runtime, group in devices.items() for d in group if d["udid"] == DEVICE)
OUT.mkdir(parents=True, exist_ok=True)
sim("status_bar", DEVICE, "override", "--time", "9:41", "--batteryState", "charged",
    "--batteryLevel", "100", "--wifiBars", "3", "--cellularBars", "4")
try:
    for name, flags in SHOTS:
        sim("terminate", DEVICE, BUNDLE, check=False)
        sim("ui", DEVICE, "appearance", "dark" if flags.get("DARK") else "light")
        env = {k: v for k, v in os.environ.items() if not k.startswith("SIMCTL_CHILD_LEDGER_")}
        env["SIMCTL_CHILD_LEDGER_DEMO"] = str(ROOT / "Ledger/Demo")
        env.update({"SIMCTL_CHILD_LEDGER_" + k: v for k, v in flags.items() if k != "DARK"})
        sim("launch", DEVICE, BUNDLE, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", env=env)
        # The first parse can exceed a fixed 4–8 second delay in Debug.
        # The launch/loading screen is ~136 KB on this device; full screens are larger.
        target = OUT / (name + ".png")
        for attempt in range(30):
            time.sleep(3)
            sim("io", DEVICE, "screenshot", str(target))
            if target.stat().st_size > 180_000:
                time.sleep(2)  # allow sheet and navigation animations to finish
                sim("io", DEVICE, "screenshot", str(target))
                break
        else:
            raise RuntimeError(f"{name}: screen may still be loading; inspect before publishing")
        print(name, flush=True)
finally:
    sim("ui", DEVICE, "appearance", "light")
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
(OUT / "capture.json").write_text(json.dumps({
    "source_commit": revision,
    "source_working_tree_changes": subprocess.check_output(
        ["git", "diff", "--name-only", "--", "Ledger", "LedgerKit"], cwd=ROOT, text=True).splitlines(),
    "device": DEVICE,
    "device_name": device["name"],
    "runtime": runtime,
    "captured_on": time.strftime("%Y-%m-%d"),
    "ledger": "Ledger/Demo (fictional data)",
    "screens": [name for name, _ in SHOTS],
}, ensure_ascii=False, indent=2) + "\n")
