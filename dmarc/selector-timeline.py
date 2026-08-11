#!/usr/bin/env python3
"""Per-day DKIM selector pass/fail for one domain. Reads ./reports/*.xml.

Counts one observation per <record>, and only counts a selector once per record
(a record may carry several <dkim> elements -- the same message seen from several
angles, not several messages).
"""
import sys, glob, datetime, collections, xml.etree.ElementTree as ET

domain = sys.argv[1]
sels = [s.lower() for s in sys.argv[2].split(",")] if len(sys.argv) > 2 else None
day = collections.defaultdict(lambda: collections.Counter())
tot = collections.Counter()

for f in glob.glob("reports/*.xml"):
    try: root = ET.parse(f).getroot()
    except Exception: continue
    pol = root.findtext("./policy_published/domain", "")
    if (pol or "").lower() != domain.lower(): continue
    beg = root.findtext("./report_metadata/date_range/begin")
    if not beg: continue
    d = datetime.datetime.fromtimestamp(int(beg), datetime.UTC).strftime("%Y-%m-%d")
    for rec in root.findall("./record"):
        seen = set()
        for dk in rec.findall("./auth_results/dkim"):
            s = (dk.findtext("selector") or "").lower()
            r = (dk.findtext("result") or "?").lower()
            if sels and s not in sels: continue
            if (s, r) in seen: continue
            seen.add((s, r))
            n = int(rec.findtext("./row/count") or 1)
            day[d][f"{s}:{r}"] += n
            tot[f"{s}:{r}"] += n

print(f"=== {domain} — DKIM selector by day ===")
keys = sorted(tot, key=lambda k: -tot[k])
print(f"{'date':<12}" + "".join(f"{k:>22}" for k in keys))
for d in sorted(day):
    print(f"{d:<12}" + "".join(f"{day[d].get(k,0):>22,}" for k in keys))
print(f"{'TOTAL':<12}" + "".join(f"{tot[k]:>22,}" for k in keys))
