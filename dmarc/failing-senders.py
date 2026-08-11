#!/usr/bin/env python3
"""Who is sending as our domains and failing DMARC?

For every <record>, decide DMARC alignment from policy_evaluated (which is
per-record and authoritative) rather than from the individual auth_results --
attributing policy_evaluated to each signature inflates counts.

    ./failing-senders.py                 # every domain
    ./failing-senders.py themyersbriggs.net
    ./failing-senders.py --min 5         # hide long-tail noise
"""
import sys, os, glob, collections, datetime, argparse
import xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("domain", nargs="?")
ap.add_argument("--min", type=int, default=1, help="minimum message count to show")
a = ap.parse_args()

here = os.path.dirname(os.path.abspath(__file__))
fails = collections.defaultdict(lambda: collections.Counter())
envs = collections.defaultdict(set)
dates = collections.defaultdict(list)
totals = collections.Counter()

for f in glob.glob(os.path.join(here, "reports", "*.xml")):
    try: root = ET.parse(f).getroot()
    except Exception: continue
    dom = (root.findtext("./policy_published/domain") or "").lower()
    if not dom or (a.domain and dom != a.domain.lower()): continue
    beg = root.findtext("./report_metadata/date_range/begin")
    org = root.findtext("./report_metadata/org_name") or "?"
    for rec in root.findall("./record"):
        n = int(rec.findtext("./row/count") or 1)
        totals[dom] += n
        pe = rec.find("./row/policy_evaluated")
        if pe is None: continue
        dkim = (pe.findtext("dkim") or "").lower()
        spf = (pe.findtext("spf") or "").lower()
        if dkim == "pass" or spf == "pass":     # DMARC passes on EITHER aligned identifier
            continue
        ip = rec.findtext("./row/source_ip") or "?"
        dis = (pe.findtext("disposition") or "none").lower()
        fails[dom][(ip, dis)] += n
        for e in rec.findall("./auth_results/spf"):
            if e.findtext("domain"): envs[(dom, ip)].add(e.findtext("domain"))
        for e in rec.findall("./auth_results/dkim"):
            if e.findtext("domain"): envs[(dom, ip)].add("dkim:" + e.findtext("domain"))
        if beg: dates[(dom, ip)].append(int(beg))

for dom in sorted(fails, key=lambda d: -sum(fails[d].values())):
    tot = sum(fails[dom].values())
    print(f"\n{'='*100}\n{dom}   DMARC-failing messages: {tot:,}  of {totals[dom]:,} total "
          f"({100*tot/max(totals[dom],1):.1f}%)\n{'='*100}")
    agg = collections.Counter()
    for (ip, dis), n in fails[dom].items(): agg[ip] += n
    print(f"{'source IP':<40}{'msgs':>8}  {'dispositions':<26}{'first..last':<24}identities seen")
    for ip, n in agg.most_common():
        if n < a.min: continue
        dd = sorted(dates.get((dom, ip), []))
        rng = ""
        if dd:
            fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.UTC).strftime("%m-%d")
            rng = f"{fmt(dd[0])}..{fmt(dd[-1])}"
        disp = ", ".join(f"{d}={c}" for (i, d), c in fails[dom].items() if i == ip)
        ids = ", ".join(sorted(envs.get((dom, ip), set()))[:3]) or "-"
        print(f"{ip:<40}{n:>8}  {disp:<26}{rng:<24}{ids[:60]}")
