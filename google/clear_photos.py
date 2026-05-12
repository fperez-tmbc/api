#!/usr/bin/env python3
"""
Delete all Google Photos media items for a user via service account impersonation.
Usage: python3 clear_photos.py <user@domain.com>
"""

import sys
import time
import requests
from google.oauth2 import service_account

SERVICE_ACCOUNT_FILE = '/Users/fperez2nd/.gam/oauth2service.json'
SCOPES = ['https://www.googleapis.com/auth/photoslibrary']

def get_credentials(user_email):
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES)
    return creds.with_subject(user_email)

def list_media_items(session, page_token=None):
    params = {'pageSize': 100}
    if page_token:
        params['pageToken'] = page_token
    r = session.get('https://photoslibrary.googleapis.com/v1/mediaItems', params=params)
    r.raise_for_status()
    return r.json()

def delete_media_items(session, ids):
    r = session.post(
        'https://photoslibrary.googleapis.com/v2/mediaItems:batchDelete',
        json={'mediaItemIds': ids}
    )
    return r

def clear_photos(user_email):
    creds = get_credentials(user_email)
    session = requests.Session()

    def refresh_token():
        import google.auth.transport.requests
        creds.refresh(google.auth.transport.requests.Request())
        session.headers.update({'Authorization': f'Bearer {creds.token}'})

    refresh_token()

    print(f"Listing media items for {user_email}...")
    total_deleted = 0
    page_token = None

    while True:
        try:
            result = list_media_items(session, page_token)
        except requests.HTTPError as e:
            print(f"Error listing: {e.response.text}")
            break

        items = result.get('mediaItems', [])
        if not items:
            print("No more items found.")
            break

        print(f"Found {len(items)} items, attempting delete...")
        ids = [item['id'] for item in items]

        r = delete_media_items(session, ids)
        if r.status_code == 200:
            total_deleted += len(ids)
            print(f"Deleted {total_deleted} items so far...")
        elif r.status_code == 401:
            refresh_token()
            r = delete_media_items(session, ids)
            if r.status_code == 200:
                total_deleted += len(ids)
                print(f"Deleted {total_deleted} items so far...")
            else:
                print(f"Delete failed: {r.status_code} {r.text}")
                break
        else:
            print(f"Delete failed: {r.status_code} {r.text}")
            break

        page_token = result.get('nextPageToken')
        if not page_token:
            break

        time.sleep(0.3)

    print(f"Done. Total deleted: {total_deleted}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python3 clear_photos.py <user@domain.com>")
        sys.exit(1)
    clear_photos(sys.argv[1])
