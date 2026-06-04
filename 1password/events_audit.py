#!/usr/bin/env python3
"""
events_audit.py - 1Password Events API usage audit

Pulls sign-in attempts + item usages over a time window and ranks users by
recency of 1Password *Windows desktop app* activity. Used to prioritize the
1Password MSI -> MSIX migration (uninstall the broken MSI off active
Windows-desktop users first).

Usage:  python3 events_audit.py [DAYS]   (default 60)

Token : ~/GitHub/.tokens/1password-events  (Events Reporting bearer JWT)
Base  : events.1password.com  (US; taken from the token's `aud`)

CAVEAT: itemusages only logs items in SHARED vaults (not Private/Personal),
so it under-counts. signinattempts captures every session regardless of vault
and is the primary "is this user active on the Windows desktop app" signal.
"""
import sys, json, datetime, collections
from pathlib import Path
import requests

BASE  = "https://events.1password.com"
TOKEN = Path.home().joinpath("GitHub/.tokens/1password-events").read_text().strip()
H     = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

days  = int(sys.argv[1]) if len(sys.argv) > 1 else 60
start = (datetime.datetime.now(datetime.timezone.utc)
         - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

def pull(endpoint):
    items, body = [], {"limit": 1000, "start_time": start}
    url = f"{BASE}/api/v1/{endpoint}"
    for _ in range(1000):
        r = requests.post(url, headers=H, json=body, timeout=90)
        r.raise_for_status()
        j = r.json()
        items += j.get("items", [])
        if j.get("has_more") and j.get("cursor"):
            body = {"cursor": j["cursor"]}
        else:
            break
    return items

signins = pull("signinattempts")
usages  = pull("itemusages")
print(f"window: last {days} days (since {start})")
print(f"signinattempts: {len(signins)}   itemusages: {len(usages)}")

# --- distinct client combos (so the real app_name/os_name values are visible) ---
combos = collections.Counter()
for ev in signins + usages:
    c = ev.get("client") or {}
    combos[(c.get("app_name"), c.get("platform_name"), c.get("os_name"))] += 1
print("\n=== distinct clients (count  app_name | platform_name | os_name) ===")
for (a, p, o), n in combos.most_common():
    print(f"  {n:6}  {a} | {p} | {o}")

def is_win_desktop(c):
    o = (c.get("os_name") or "").lower()
    a = (c.get("app_name") or "").lower()
    if not o.startswith("windows"):
        return False
    if any(x in a for x in ["browser", "extension", "cli", "web", "safari",
                            "chrome", "edge", "firefox", "command line"]):
        return False
    return True

U = collections.defaultdict(lambda: {"name": "", "email": "", "last_signin": "",
    "last_activity": "", "win_last": "", "win_n": 0, "win_apps": set(),
    "win_machines": set(), "win_versions": set(), "win_last_ver": ""})

def user_of(ev):
    return ev.get("target_user") or ev.get("user") or {}

def ingest(ev, success_only_for_signin=False, is_signin=False):
    u = user_of(ev)
    email = u.get("email") or u.get("uuid")
    if not email:
        return
    d = U[email]; d["email"] = email; d["name"] = u.get("name") or d["name"]
    ts = ev.get("timestamp", "")
    c  = ev.get("client") or {}
    counts = True
    if is_signin:
        if ev.get("category") == "success":
            if ts > d["last_signin"]:  d["last_signin"]  = ts
            if ts > d["last_activity"]: d["last_activity"] = ts
        else:
            counts = False  # failed sign-ins don't count as "active use"
    else:
        if ts > d["last_activity"]: d["last_activity"] = ts
    if counts and is_win_desktop(c):
        d["win_n"] += 1
        d["win_apps"].add(c.get("app_name"))
        if c.get("platform_name"): d["win_machines"].add(c.get("platform_name"))
        ver = c.get("app_version")
        if ver: d["win_versions"].add(ver)
        if ts > d["win_last"]:
            d["win_last"] = ts
            d["win_last_ver"] = ver or d["win_last_ver"]

for ev in signins: ingest(ev, is_signin=True)
for ev in usages:  ingest(ev, is_signin=False)

rows = sorted(U.values(), key=lambda d: (d["win_last"], d["last_activity"]), reverse=True)
win_rows = [d for d in rows if d["win_n"] > 0]

print(f"\n=== Users active on the 1Password WINDOWS DESKTOP app  ({len(win_rows)}) ===")
print(f"{'last_win_desktop':20} {'evts':>5} {'cur_ver':10} {'name':24} {'machine(s)':22} email")
for d in win_rows:
    print(f"{d['win_last'][:19]:20} {d['win_n']:5} {(d['win_last_ver'] or '?'):10} "
          f"{(d['name'] or '')[:24]:24} {(','.join(sorted(d['win_machines'])))[:22]:22} {d['email']}")

no_wd = [d for d in rows if d["win_n"] == 0]
print(f"\n(Users with activity but NO Windows-desktop use in window: {len(no_wd)} - lower priority)")

# machine-readable dump for cross-referencing with PDQ
out = {"window_days": days, "since": start,
       "users": [{"email": d["email"], "name": d["name"],
                  "last_win_desktop": d["win_last"], "win_events": d["win_n"],
                  "win_apps": sorted(x for x in d["win_apps"] if x),
                  "last_activity": d["last_activity"]} for d in rows]}
Path("/tmp/1p_audit.json").write_text(json.dumps(out, indent=2))
print("\n(JSON written to /tmp/1p_audit.json for PDQ cross-reference)")
