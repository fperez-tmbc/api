#!/usr/bin/env python3
"""
Permanently delete all Gmail messages for a user via service account impersonation.
Usage: python3 clear_gmail.py <user@aionetworking.com>
"""

import sys
import time
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

SERVICE_ACCOUNT_FILE = '/Users/fperez2nd/.gam/oauth2service.json'
SCOPES = ['https://mail.google.com/']

def get_service(user_email):
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES)
    delegated = creds.with_subject(user_email)
    return build('gmail', 'v1', credentials=delegated)

def delete_all_messages(user_email):
    service = get_service(user_email)

    profile = service.users().getProfile(userId='me').execute()
    total = profile.get('messagesTotal', 0)
    print(f"Total messages in profile: {total}")

    deleted = 0
    page_token = None

    while True:
        try:
            kwargs = {'userId': 'me', 'maxResults': 500, 'includeSpamTrash': True}
            if page_token:
                kwargs['pageToken'] = page_token

            result = service.users().messages().list(**kwargs).execute()
            messages = result.get('messages', [])

            if not messages:
                print("No more messages found.")
                break

            print(f"Found {len(messages)} messages in this page, deleting...")
            ids = [m['id'] for m in messages]

            # batchDelete permanently removes messages (bypasses trash)
            service.users().messages().batchDelete(
                userId='me',
                body={'ids': ids}
            ).execute()

            deleted += len(ids)
            print(f"Deleted {deleted} messages so far...")

            page_token = result.get('nextPageToken')
            if not page_token:
                break

            time.sleep(0.5)

        except HttpError as e:
            print(f"Error: {e}")
            break

    print(f"Done. Total deleted: {deleted}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python3 clear_gmail.py <user@domain.com>")
        sys.exit(1)
    delete_all_messages(sys.argv[1])
