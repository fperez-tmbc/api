#!/usr/bin/env python3
"""How long has each domain been sending DMARC aggregate reports to the RUA mailbox?

Answers "how far back can this data possibly see", which bounds every conclusion
drawn from the reports. Uses only subject + receivedDateTime, so it needs no
attachment downloads and runs in seconds.

    ./report-coverage.py
    ./report-coverage.py --mailbox x@y.com

Verified 2026-07-31 on domainr@themyersbriggs.com: five domains all begin on the
SAME day (2026-06-28) and the mailbox itself only goes back to 2026-04-28. A
simultaneous start across unrelated zones is when rua= was set or began being
honoured, not coincidence -- so anything older is invisible here. That is why the
Mimecast archive (reaching ~2015) is the long record and these reports are not.
"""
import argparse
import collections
import json
import os
import re
import time

import msal
import requests

TOK_DIR = os.path.expanduser("~/GitHub/.tokens/claude-m365")
GRAPH = "https://graph.microsoft.com/v1.0"
DEFAULT_MAILBOX = "domainr@themyersbriggs.com"

DOM = re.compile(r"(?:report\s*domain|domain)\s*[:=]\s*([A-Za-z0-9.\-]+)", re.I)
SUB = re.compile(r"submitter\s*[:=]\s*([A-Za-z0-9.\-]+)", re.I)


def get_token():
    cfg = json.load(open(os.path.join(TOK_DIR, "config.json")))
    app = msal.ConfidentialClientApplication(
        cfg["appId"],
        authority="https://login.microsoftonline.com/" + cfg["tenantId"],
        client_credential={
            "private_key": open(os.path.join(TOK_DIR, "key.pem")).read(),
            "thumbprint": cfg["thumbprint"],
            "public_certificate": open(os.path.join(TOK_DIR, "cert.pem")).read(),
        },
    )
    r = app.acquire_token_for_client(["https://graph.microsoft.com/.default"])
    if "access_token" not in r:
        raise SystemExit("token failure: %s" % r.get("error_description"))
    return r["access_token"]


def get_json(url, hdr, tries=4):
    """Graph occasionally returns a corrupt gzip stream mid-pagination
    (zlib "invalid distance too far back"). Ask for identity encoding and retry."""
    h = dict(hdr)
    h["Accept-Encoding"] = "identity"
    last = None
    for n in range(tries):
        try:
            r = requests.get(url, headers=h, timeout=120)
            r.raise_for_status()
            return r.json()
        except Exception as e:                                    # noqa: BLE001
            last = e
            time.sleep(2 * (n + 1))
    raise SystemExit("Graph failed after %d tries: %s" % (tries, last))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mailbox", default=DEFAULT_MAILBOX)
    a = ap.parse_args()

    hdr = {"Authorization": "Bearer " + get_token()}
    msgs, url = [], (GRAPH + "/users/%s/messages"
                     "?$select=subject,receivedDateTime"
                     "&$orderby=receivedDateTime asc&$top=200" % a.mailbox)
    while url:
        d = get_json(url, hdr)
        msgs.extend(d.get("value", []))
        url = d.get("@odata.nextLink")

    print("total messages in %s: %d" % (a.mailbox, len(msgs)))
    if msgs:
        print("mailbox span: %s .. %s"
              % (msgs[0]["receivedDateTime"][:10], msgs[-1]["receivedDateTime"][:10]))

    per = collections.defaultdict(lambda: {"n": 0, "first": None, "last": None,
                                           "submitters": collections.Counter()})
    unparsed = []
    for m in msgs:
        s = m.get("subject") or ""
        when = m["receivedDateTime"]
        d = DOM.search(s)
        if not d:
            unparsed.append((when[:10], s[:80]))
            continue
        e = per[d.group(1).lower().rstrip(".")]
        e["n"] += 1
        e["first"] = when if e["first"] is None else min(e["first"], when)
        e["last"] = when if e["last"] is None else max(e["last"], when)
        sm = SUB.search(s)
        if sm:
            e["submitters"][sm.group(1).lower()] += 1

    print("\n=== reports per reported domain, by first-seen ===")
    print("%-34s %6s  %-12s %-12s" % ("domain", "count", "first seen", "last seen"))
    for dom, e in sorted(per.items(), key=lambda kv: kv[1]["first"]):
        print("%-34s %6d  %-12s %-12s" % (dom, e["n"], e["first"][:10], e["last"][:10]))

    firsts = {e["first"][:10] for e in per.values()}
    if per and len(firsts) < max(2, len(per) // 2):
        print("\n  NOTE: multiple domains share a first-seen date -- that is when rua= was")
        print("  set or began being honoured, and is the true floor on visibility.")

    if unparsed:
        print("\n=== non-report messages in the mailbox (%d) -- first 10 ===" % len(unparsed))
        for w, s in unparsed[:10]:
            print("  %s  %s" % (w, s))


if __name__ == "__main__":
    main()
