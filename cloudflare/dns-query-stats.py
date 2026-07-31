#!/usr/bin/env python3
"""Cloudflare DNS query stats — "is this DNS record still being used?"

A query for <selector>._domainkey only happens when a receiver validates a DKIM
signature with that selector. A query for a mail whitelabel envelope domain only
happens when a receiver evaluates SPF on it. So query volume is a direct,
receiver-driven usage signal, independent of your own mail logs.

    ./dns-query-stats.py themyersbriggs.net
    ./dns-query-stats.py themyersbriggs.net --days 7 --top 25
    ./dns-query-stats.py themyersbriggs.net --names s1._domainkey,em9338,snd._domainkey
    ./dns-query-stats.py themyersbriggs.net --hourly s1._domainkey,snd._domainkey

Token needs **Zone -> Analytics -> Read**. A DNS-edit token does not have it;
without it GraphQL returns an authz error naming the permission. Editing an
existing token's permissions does NOT change the secret.

Read the interpretation traps in README.md before drawing conclusions. Short
version: counts are sampled and quantised to 10 (presence reliable, magnitude
not); NXDOMAIN queries ARE logged, so deleting a record does not blind you; and
common selector names (s1, s2, selector1, default) attract constant internet-wide
probing, so volume on them is not evidence of live mail.
"""
import argparse
import collections
import datetime as dt
import json
import os
import urllib.error
import urllib.request

TOKEN = open(os.path.expanduser("~/GitHub/.tokens/cloudflare")).read().strip()
API = "https://api.cloudflare.com/client/v4"


def rest(path):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + TOKEN})
    return json.load(urllib.request.urlopen(req, timeout=60))


def gql(query, variables):
    req = urllib.request.Request(
        API + "/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        raise SystemExit("HTTP %d %s" % (e.code, e.read().decode()[:400]))
    if d.get("errors"):
        msg = json.dumps(d["errors"])
        if "analytics.read" in msg:
            raise SystemExit("Token lacks Zone -> Analytics -> Read.\n  %s" % msg[:300])
        if "wider than" in msg:
            raise SystemExit("Window too wide for this zone's plan (Free caps at 1 week).\n  %s"
                             % msg[:300])
        raise SystemExit(msg[:500])
    return d


Q_GROUPS = """
query($z:String!,$s:Time!,$u:Time!){viewer{zones(filter:{zoneTag:$z}){
 dnsAnalyticsAdaptiveGroups(limit:5000,filter:{datetime_geq:$s,datetime_leq:$u},
  orderBy:[count_DESC]){count dimensions{queryName queryType responseCode}}}}}
"""

Q_HOURLY = """
query($z:String!,$s:Time!,$u:Time!){viewer{zones(filter:{zoneTag:$z}){
 dnsAnalyticsAdaptiveGroups(limit:5000,filter:{datetime_geq:$s,datetime_leq:$u},
  orderBy:[datetimeHour_ASC]){count dimensions{datetimeHour queryName}}}}}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zone", help="zone name, e.g. themyersbriggs.net")
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--names", default="", help="comma-separated names to report explicitly")
    ap.add_argument("--hourly", default="", help="comma-separated names for an hourly series")
    a = ap.parse_args()

    z = rest("/zones?name=%s" % a.zone)
    if not z.get("result"):
        raise SystemExit("zone not found: %s" % a.zone)
    zone = z["result"][0]
    zid = zone["id"]
    print("zone %s  id=%s  plan=%s" % (zone["name"], zid, (zone.get("plan") or {}).get("name")))

    now = dt.datetime.now(dt.UTC).replace(microsecond=0)
    since = (now - dt.timedelta(days=a.days)).isoformat().replace("+00:00", "Z")
    until = now.isoformat().replace("+00:00", "Z")
    print("window %.1f day(s): %s .. %s\n" % (a.days, since, until))

    rows = gql(Q_GROUPS, {"z": zid, "s": since, "u": until})[
        "data"]["viewer"]["zones"][0]["dnsAnalyticsAdaptiveGroups"]

    agg = collections.defaultdict(lambda: collections.Counter())
    for r in rows:
        n = (r["dimensions"]["queryName"] or "").rstrip(".").lower()
        agg[n][r["dimensions"]["responseCode"]] += r["count"]

    def fq(n):
        n = n.strip().lower().rstrip(".")
        return n if n.endswith(a.zone.lower()) else "%s.%s" % (n, a.zone.lower())

    if a.names:
        print("=== requested names ===")
        print("  %-52s %10s %10s" % ("name", "NOERROR", "NXDOMAIN"))
        for raw in a.names.split(","):
            if not raw.strip():
                continue
            n = fq(raw)
            c = agg.get(n)
            if c is None:
                print("  %-52s %10s %10s   <- never queried (absent from result set)" % (n, "-", "-"))
            else:
                print("  %-52s %10s %10s" % (n, format(c.get("NOERROR", 0), ","),
                                             format(c.get("NXDOMAIN", 0), ",")))
        print()

    print("=== top %d names in zone ===" % a.top)
    print("  %-52s %10s %10s" % ("name", "NOERROR", "NXDOMAIN"))
    for n, c in sorted(agg.items(), key=lambda kv: -sum(kv[1].values()))[:a.top]:
        print("  %-52s %10s %10s" % (n[:52], format(c.get("NOERROR", 0), ","),
                                     format(c.get("NXDOMAIN", 0), ",")))

    nx = [(n, c["NXDOMAIN"]) for n, c in agg.items() if c.get("NXDOMAIN", 0) >= 100]
    if nx:
        print("\n=== names being queried that do NOT resolve (>=100) ===")
        for n, c in sorted(nx, key=lambda kv: -kv[1])[:15]:
            print("  %-52s %s" % (n[:52], format(c, ",")))

    if a.hourly:
        want = [fq(x) for x in a.hourly.split(",") if x.strip()]
        hrows = gql(Q_HOURLY, {"z": zid,
                               "s": (now - dt.timedelta(days=min(a.days, 2))).isoformat().replace("+00:00", "Z"),
                               "u": until})["data"]["viewer"]["zones"][0]["dnsAnalyticsAdaptiveGroups"]
        series = collections.defaultdict(collections.Counter)
        for r in hrows:
            n = (r["dimensions"]["queryName"] or "").rstrip(".").lower()
            if n in want:
                series[n][r["dimensions"]["datetimeHour"]] += r["count"]
        hours = sorted({h for s in series.values() for h in s})
        print("\n=== hourly (mail-driven lookups show a business-hours curve; scanning is flat) ===")
        print("  %-18s %s" % ("hour UTC", "  ".join(n.split(".")[0][:14].rjust(14) for n in want)))
        for h in hours:
            print("  %-18s %s" % (h[:16],
                                  "  ".join(format(series[n].get(h, 0), ",").rjust(14) for n in want)))


if __name__ == "__main__":
    main()
