#!/usr/bin/env python3
"""
OAuth + discovery for the Google APIs that GAM does not cover:
GA4 (Analytics Admin/Data), Tag Manager, and Search Console.

GAM's `oauth create` only accepts scopes from its own allow-list, which excludes
analytics, tagmanager and webmasters. This script obtains a separate user token
against the same desktop OAuth client and stores it alongside the GAM creds.

Deliberately does NOT use Application Default Credentials: ADC is a single global
file shared with any other Google account configured on the machine, so writing to
it would clobber an unrelated tenant.

Usage:
    tmbc-marketing.py auth        # run the browser flow, write the token
    tmbc-marketing.py discover    # list what this account can actually see

Paths may be overridden with GOOGLE_TMBC_CLIENT_SECRETS and GOOGLE_TMBC_TOKEN.
"""

import json
import os
import sys

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

CLIENT_SECRETS = os.environ.get(
    "GOOGLE_TMBC_CLIENT_SECRETS",
    os.path.expanduser("~/.gam/tmbc/client_secrets.json"),
)
TOKEN_FILE = os.environ.get(
    "GOOGLE_TMBC_TOKEN",
    os.path.expanduser("~/GitHub/.tokens/google-tmbc/marketing-token.json"),
)

SCOPES = [
    "https://www.googleapis.com/auth/analytics.readonly",
    "https://www.googleapis.com/auth/analytics.edit",
    "https://www.googleapis.com/auth/analytics.manage.users",
    "https://www.googleapis.com/auth/tagmanager.readonly",
    "https://www.googleapis.com/auth/tagmanager.edit.containers",
    "https://www.googleapis.com/auth/tagmanager.manage.accounts",
    "https://www.googleapis.com/auth/webmasters",
]


def load_credentials(interactive=False):
    creds = None
    if os.path.exists(TOKEN_FILE):
        creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    elif interactive:
        flow = InstalledAppFlow.from_client_secrets_file(CLIENT_SECRETS, SCOPES)
        creds = flow.run_local_server(port=0, prompt="consent")
    else:
        sys.exit("No usable token. Run: tmbc-marketing.py auth")

    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    with open(TOKEN_FILE, "w") as fh:
        fh.write(creds.to_json())
    os.chmod(TOKEN_FILE, 0o600)
    return creds


def section(title):
    print(f"\n=== {title} ===")


def discover(creds):
    section("GA4 accounts")
    try:
        admin = build("analyticsadmin", "v1beta", credentials=creds)
        accounts = admin.accounts().list().execute().get("accounts", [])
        if not accounts:
            print("  none visible to this account")
        for acct in accounts:
            print(f"  {acct['name']}  {acct.get('displayName')}")
            props = (
                admin.properties()
                .list(filter=f"parent:{acct['name']}")
                .execute()
                .get("properties", [])
            )
            for prop in props:
                print(f"    property: {prop['name']}  {prop.get('displayName')}")
    except HttpError as exc:
        print(f"  ERROR: {exc.reason}")

    section("Tag Manager accounts")
    try:
        gtm = build("tagmanager", "v2", credentials=creds)
        accounts = gtm.accounts().list().execute().get("account", [])
        if not accounts:
            print("  none visible to this account")
        for acct in accounts:
            print(f"  {acct['path']}  {acct.get('name')}")
            containers = (
                gtm.accounts()
                .containers()
                .list(parent=acct["path"])
                .execute()
                .get("container", [])
            )
            for cont in containers:
                print(f"    container: {cont.get('publicId')}  {cont.get('name')}")
    except HttpError as exc:
        print(f"  ERROR: {exc.reason}")

    section("Search Console properties")
    try:
        sc = build("searchconsole", "v1", credentials=creds)
        sites = sc.sites().list().execute().get("siteEntry", [])
        if not sites:
            print("  none visible to this account")
        for site in sites:
            print(f"  {site['siteUrl']}  ({site.get('permissionLevel')})")
    except HttpError as exc:
        print(f"  ERROR: {exc.reason}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "discover"
    if cmd == "auth":
        creds = load_credentials(interactive=True)
        print(f"Token written: {TOKEN_FILE}")
        with open(TOKEN_FILE) as fh:
            print(f"Granted scopes: {len(json.load(fh).get('scopes', []))}")
    elif cmd == "discover":
        discover(load_credentials())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
