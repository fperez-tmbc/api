#!/usr/bin/env python3
"""
create-patching-changes.py
Creates two monthly SDP change requests for security patching.

  DEV/TEST/QA  — first Friday after Patch Tuesday
  PROD/LIVE    — third Friday after Patch Tuesday

Scheduled 19:00–23:00 US/Pacific on each date.

Usage:
  python3 create-patching-changes.py [YYYY-MM]
  Defaults to the current month if no argument is given.
"""

import json
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

PACIFIC = ZoneInfo("America/Los_Angeles")
CREDS_FILE = "/Users/fperez2nd/GitHub/.tokens/sdp-changes"
BASE_URL = "https://sdpondemand.manageengine.com/app/itdesk/api/v3"
PORTAL_URL = "https://servicedesk.themyersbriggs.com/app/itdesk/ChangDetails.do"

# Field IDs — sourced from CH-18 and CH-25
TEMPLATE_ID      = "260962000001233127"  # Security Patching Template
CHANGE_OWNER_ID  = "260962000000448625"  # Frank Perez
CHANGE_TYPE_ID   = "260962000000007949"  # Standard
URGENCY_ID       = "260962000000486319"  # Medium
IMPACT_ID        = "260962000000486347"  # Medium
PRIORITY_ID      = "260962000000006803"  # Medium
GROUP_ID         = "260962000000482551"  # Helpdesk
REASON_ID        = "260962000000083101"  # Patch updates

DESCRIPTION = (
    '<div class="personalize-wrapper" style="font-family:&quot;Zoho Puvi&quot;,'
    ' Roboto, sans-serif; font-size:13px"><div>NetOps will deploy and install OS'
    ' security patches and updates to all relevant VMs and servers.<br/></div></div>'
)


def patch_tuesday(year: int, month: int) -> date:
    """Return the second Tuesday of the given month."""
    d = date(year, month, 1)
    days_to_tuesday = (1 - d.weekday()) % 7  # weekday: Mon=0 Tue=1
    return d + timedelta(days=days_to_tuesday + 7)


def nth_friday_after(ref: date, n: int) -> date:
    """Return the Nth Friday strictly after ref (n=1 → first, n=3 → third)."""
    days_to_friday = (4 - ref.weekday()) % 7  # weekday: Fri=4
    if days_to_friday == 0:
        days_to_friday = 7
    first_friday = ref + timedelta(days=days_to_friday)
    return first_friday + timedelta(weeks=n - 1)


def epoch_ms(local_date: date, hour: int) -> int:
    """Convert a Pacific-local date + hour to UTC millisecond epoch."""
    dt = datetime(local_date.year, local_date.month, local_date.day,
                  hour, 0, 0, tzinfo=PACIFIC)
    return int(dt.timestamp() * 1000)


def load_creds() -> dict:
    creds = {}
    with open(CREDS_FILE) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip()
    return creds


def get_token(creds: dict) -> str:
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "client_id": creds["CLIENT_ID"],
        "client_secret": creds["CLIENT_SECRET"],
        "refresh_token": creds["REFRESH_TOKEN"],
    }).encode()
    req = urllib.request.Request(
        "https://accounts.zoho.com/oauth/v2/token",
        data=data, method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
    token = result.get("access_token")
    if not token:
        print(f"ERROR: token refresh failed: {result}", file=sys.stderr)
        sys.exit(1)
    return token


def create_change(token: str, title: str, start_ms: int, end_ms: int) -> dict:
    payload = json.dumps({
        "change": {
            "title": title,
            "description": DESCRIPTION,
            "template":           {"id": TEMPLATE_ID},
            "change_type":        {"id": CHANGE_TYPE_ID},
            "change_owner":       {"id": CHANGE_OWNER_ID},
            "urgency":            {"id": URGENCY_ID},
            "impact":             {"id": IMPACT_ID},
            "priority":           {"id": PRIORITY_ID},
            "group":              {"id": GROUP_ID},
            "reason_for_change":  {"id": REASON_ID},
            "scheduled_start_time": {"value": str(start_ms)},
            "scheduled_end_time":   {"value": str(end_ms)},
        }
    })
    body = urllib.parse.urlencode({"input_data": payload}).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/changes",
        data=body,
        headers={
            "Authorization": f"Zoho-oauthtoken {token}",
            "Accept": "application/vnd.manageengine.sdp.v3+json",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read(), strict=False)


def main():
    if len(sys.argv) > 1:
        year, month = map(int, sys.argv[1].split("-"))
    else:
        today = date.today()
        year, month = today.year, today.month

    pt   = patch_tuesday(year, month)
    dev  = nth_friday_after(pt, 1)
    prod = nth_friday_after(pt, 3)

    print(f"Month:         {year}-{month:02d}")
    print(f"Patch Tuesday: {pt}")
    print(f"DEV/TEST/QA:   {dev}  (1st Friday after Patch Tuesday)")
    print(f"PROD/LIVE:     {prod}  (3rd Friday after Patch Tuesday)")
    print()

    creds = load_creds()
    token = get_token(creds)

    changes = [
        ("DEV/TEST/QA - OS and Security Patches",  dev),
        ("PROD/LIVE - OS and Security Patches",    prod),
    ]

    for title, patch_date in changes:
        resp = create_change(token, title, epoch_ms(patch_date, 19), epoch_ms(patch_date, 23))
        status = resp.get("response_status", {}).get("status_code")
        if status == 2000:
            ch = resp["change"]
            display_id  = ch["display_id"]["display_value"]
            internal_id = ch["id"]
            url = f"{PORTAL_URL}?CHANGEID={internal_id}&tab=conversations&subTab=details"
            print(f"✓  {display_id}  {title}")
            print(f"   {patch_date} 19:00–23:00 Pacific")
            print(f"   {url}")
        else:
            print(f"✗  FAILED — {title}")
            print(f"   {json.dumps(resp, indent=2)}")
        print()


if __name__ == "__main__":
    main()
