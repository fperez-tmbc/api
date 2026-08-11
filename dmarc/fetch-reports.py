#!/usr/bin/env python3
"""Phase 1 — download DMARC aggregate report attachments from a mailbox to disk.

TMBC's RUA target is domainr@themyersbriggs.com, which collects reports for nine
domains. This fetches every attachment, decompresses gzip/zip, and writes raw XML
to ./reports/. Existing files are skipped, so re-running only picks up new ones.

Split from the analysis deliberately: the download is ~1,900 sequential Graph
calls (10-15 min) and you should not repeat it every time the question changes.

    ./fetch-reports.py
    ./fetch-reports.py --mailbox x@y.com --out /tmp/r

Auth: claude-m365 cert, app-only, Mail.Read tenant-wide.
"""
import argparse
import base64
import gzip
import io
import json
import os
import time
import zipfile

import msal
import requests

TOK_DIR = os.path.expanduser("~/GitHub/.tokens/claude-m365")
GRAPH = "https://graph.microsoft.com/v1.0"
DEFAULT_MAILBOX = "domainr@themyersbriggs.com"


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


def get_json(url, hdr, tries=4, allow_fail=False):
    """Graph occasionally returns a corrupt gzip stream mid-pagination
    (zlib "invalid distance too far back"). Ask for identity encoding and retry."""
    h = dict(hdr)
    h["Accept-Encoding"] = "identity"
    last = None
    for n in range(tries):
        try:
            r = requests.get(url, headers=h, timeout=120)
            if allow_fail and r.status_code != 200:
                return None
            r.raise_for_status()
            return r.json()
        except Exception as e:                                    # noqa: BLE001
            last = e
            time.sleep(2 * (n + 1))
    if allow_fail:
        return None
    raise SystemExit("Graph failed after %d tries: %s" % (tries, last))


def decompress(name, blob):
    """Return [(inner_name, xml_bytes)] for gz / zip / bare xml, else []."""
    low = name.lower()
    if low.endswith(".gz"):
        return [(name[:-3], gzip.decompress(blob))]
    if low.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(blob)) as z:
            return [(n, z.read(n)) for n in z.namelist()]
    if low.endswith(".xml"):
        return [(name, blob)]
    return []


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--mailbox", default=DEFAULT_MAILBOX)
    ap.add_argument("--out", default=os.path.join(here, "reports"))
    ap.add_argument("--folder", default=None,
                    help="Restrict to one folder. Accepts a folder id or a well-known "
                         "name. Use 'recoverableitemsdeletions' to harvest reports the "
                         "retention tag already deleted -- /users/{id}/messages does NOT "
                         "reach the Recoverable Items subtree, so they are invisible "
                         "without this.")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    hdr = {"Authorization": "Bearer " + get_token()}

    # Page to the end. An unpaged call silently truncates -- that once produced a
    # baseline built on 65 of 1,911 reports and understated a selector's signing
    # count by more than an order of magnitude.
    scope = ("/users/%s/mailFolders/%s/messages" % (a.mailbox, a.folder) if a.folder
             else "/users/%s/messages" % a.mailbox)
    msgs, url = [], (GRAPH + scope +
                     "?$select=id,subject,receivedDateTime,hasAttachments"
                     "&$filter=hasAttachments eq true&$top=100")
    while url:
        d = get_json(url, hdr)
        msgs.extend(d.get("value", []))
        url = d.get("@odata.nextLink")
    print("messages with attachments: %d" % len(msgs), flush=True)

    written = skipped = 0
    for i, m in enumerate(msgs, 1):
        ar = get_json(GRAPH + "/users/%s/messages/%s/attachments"
                      % (a.mailbox, m["id"]), hdr, allow_fail=True)
        if ar is None:
            print("  attachment fetch failed for %s, skipping" % m["id"][:12], flush=True)
            continue
        for att in ar.get("value", []):
            cb = att.get("contentBytes")
            if not cb:
                continue
            for name, xml in decompress(att.get("name", ""), base64.b64decode(cb)):
                safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
                p = os.path.join(a.out, safe)
                if os.path.exists(p):
                    skipped += 1
                    continue
                with open(p, "wb") as f:
                    f.write(xml)
                written += 1
        if i % 100 == 0:
            print("  ...%d/%d messages, %d new xml" % (i, len(msgs), written), flush=True)

    print("done: %d new, %d already present -> %s" % (written, skipped, a.out), flush=True)


if __name__ == "__main__":
    main()
