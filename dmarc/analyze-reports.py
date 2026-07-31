#!/usr/bin/env python3
"""Phase 2 — analyse cached DMARC aggregate reports for one domain.

    ./analyze-reports.py themyersbriggs.net
    ./analyze-reports.py themyersbriggs.net --grep s1,s2,em9338
    ./analyze-reports.py --list          # just the per-domain breakdown

Reports must already be on disk (see fetch-reports.py). Everything is grouped by
<policy_published><domain> first, because one RUA mailbox collects reports for
several domains and mixing them silently corrupts every count.

Two parsing rules this enforces, both learned the hard way:

  * A <record> can hold SEVERAL <spf> or <dkim> elements when the reporter
    documents every identity it evaluated. gosecure.net emits HELO + envelope +
    header-from in one record. Counting each element as an independent
    observation fabricated a phantom "this domain sends from its bare apex
    envelope" finding. Records with exactly one <spf> give the real envelope;
    records with several are one message seen from multiple angles, so they are
    reported separately rather than folded in.

  * policy_evaluated is per-record, not per-signature. Attributing it to every
    selector in a multi-signature record inflates pass counts.
"""
import argparse
import collections
import datetime as dt
import glob
import os
import xml.etree.ElementTree as ET


def load(reports):
    for p in sorted(glob.glob(os.path.join(reports, "*"))):
        try:
            yield p, ET.parse(p).getroot()
        except ET.ParseError:
            continue


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("domain", nargs="?", help="policy_published domain to scope to")
    ap.add_argument("--reports", default=os.path.join(here, "reports"))
    ap.add_argument("--grep", default="", help="comma-separated selectors/domains to hunt for")
    ap.add_argument("--list", action="store_true", help="only show the per-domain breakdown")
    a = ap.parse_args()

    hunt = [x.strip().lower() for x in a.grep.split(",") if x.strip()]
    by_domain = collections.Counter()
    rec_by_domain = collections.Counter()
    sel = collections.Counter()
    sel_dom = collections.defaultdict(set)
    spf_single = collections.Counter()
    spf_multi = collections.Counter()
    disp = collections.Counter()
    evaluated = collections.Counter()
    orgs = collections.Counter()
    hits = []
    lo = hi = None
    parsed = target_reports = 0

    for p, root in load(a.reports):
        parsed += 1
        pol = root.find("policy_published")
        pdom = ((pol.findtext("domain") if pol is not None else "") or "").lower().strip()
        nrec = sum(1 for _ in root.iter("record"))
        by_domain[pdom or "(none)"] += 1
        rec_by_domain[pdom or "(none)"] += nrec

        if a.list or not a.domain or pdom != a.domain.lower():
            continue
        target_reports += 1

        md = root.find("report_metadata")
        if md is not None:
            orgs[md.findtext("org_name") or "?"] += 1
            rng = md.find("date_range")
            b = rng.findtext("begin") if rng is not None else None
            if b and b.isdigit():
                b = int(b)
                lo = b if lo is None else min(lo, b)
                hi = b if hi is None else max(hi, b)

        for rec in root.iter("record"):
            row = rec.find("row")
            auth = rec.find("auth_results")
            cnt, src = 1, ""
            if row is not None:
                c = row.findtext("count")
                cnt = int(c) if c and c.isdigit() else 1
                src = row.findtext("source_ip") or ""
                pe = row.find("policy_evaluated")
                if pe is not None:
                    disp[pe.findtext("disposition") or "?"] += cnt
                    evaluated[(pe.findtext("dkim") or "?", pe.findtext("spf") or "?")] += cnt
            if auth is None:
                continue

            spfs = auth.findall("spf")
            doms = [(s.findtext("domain") or "").lower().rstrip(".") for s in spfs]
            if len(spfs) == 1:
                spf_single[(doms[0], spfs[0].findtext("result") or "?")] += cnt
            elif spfs:
                spf_multi[tuple(sorted(doms))] += cnt

            flagged = None
            for k in auth.findall("dkim"):
                s_ = (k.findtext("selector") or "").lower()
                d = (k.findtext("domain") or "").lower()
                sel[(s_, k.findtext("result") or "?")] += cnt
                sel_dom[s_].add(d)
                if s_ in hunt:
                    flagged = "dkim selector %s (d=%s)" % (s_, d)
            for d in doms:
                if any(h in d for h in hunt):
                    flagged = "spf domain %s" % d
            if flagged:
                hits.append({"file": os.path.basename(p), "count": cnt,
                             "source_ip": src, "why": flagged})

    print("xml files parsed: %d\n" % parsed)
    print("=== reports per policy_published domain (whole corpus) ===")
    for d, n in by_domain.most_common():
        print("  %-32s %4d reports  %7d records" % (d, n, rec_by_domain[d]))
    if a.list or not a.domain:
        return

    print("\n########## scoped to %s ##########" % a.domain)
    print("reports: %d" % target_reports)
    if lo:
        print("date range: %s .. %s UTC"
              % (dt.datetime.fromtimestamp(lo, dt.UTC).strftime("%Y-%m-%d"),
                 dt.datetime.fromtimestamp(hi, dt.UTC).strftime("%Y-%m-%d")))
    print("reporting orgs: %d distinct" % len(orgs))
    for o, n in orgs.most_common(8):
        print("    %-34s %d" % (o, n))

    print("\n=== DKIM selectors ===")
    tot = collections.Counter()
    for (s_, _), c in sel.items():
        tot[s_] += c
    for s_, n in tot.most_common(20):
        res = {r: c for (ss, r), c in sel.items() if ss == s_}
        print("  %-22s %8s  %-34s d=%s"
              % (s_ or "(empty)", format(n, ","), res, ",".join(sorted(sel_dom[s_]))[:40]))

    print("\n=== SPF envelope domains (single-element records = the real envelope) ===")
    tot = collections.Counter()
    for (d, _), c in spf_single.items():
        tot[d] += c
    for d, n in tot.most_common(20):
        res = {r: c for (dd, r), c in spf_single.items() if dd == d}
        print("  %-44s %8s  %s" % (d or "(empty)", format(n, ","), res))
    if spf_multi:
        print("\n  multi-element records (ONE message, several identities -- do not fold in):")
        for combo, c in spf_multi.most_common(8):
            print("    %-6s %s" % (format(c, ","), " | ".join(combo)))

    print("\n=== policy evaluated ===")
    for k, v in evaluated.most_common():
        print("  dkim=%-10s spf=%-10s %s" % (k[0], k[1], format(v, ",")))
    print("disposition: %s" % dict(disp))

    if hunt:
        print("\n=== records matching --grep %s ===" % a.grep)
        if not hits:
            print("  NONE")
        for h in hits[:40]:
            print("  %s" % h)


if __name__ == "__main__":
    main()
