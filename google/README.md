# Google Workspace API — aionetworking.com

## Tooling

**GAM 7** (Google Apps Manager) is installed and configured for all admin operations.

- Binary: `/Users/fperez2nd/bin/gam7/gam`
- Config dir: `/Users/fperez2nd/.gam/`
- Credentials backup: `~/GitHub/.tokens/google-aionetworking/`

## Tenant Info

| Field | Value |
|-------|-------|
| Domain | aionetworking.com |
| Customer ID | C03mpp5jw |
| Admin email | frank@aionetworking.com |
| GCP Project | gam-project-ujnt3 |
| Service Account | gam-project-ujnt3@gam-project-ujnt3.iam.gserviceaccount.com |

## Credential Files

| File | Location | Purpose |
|------|----------|---------|
| `oauth2.txt` | `~/.gam/oauth2.txt` | Admin OAuth token (frank@aionetworking.com) |
| `oauth2service.json` | `~/.gam/oauth2service.json` | Service account key for domain-wide delegation |
| `client_secrets.json` | `~/.gam/client_secrets.json` | OAuth 2.0 client credentials |

All three are backed up to `~/GitHub/.tokens/google-aionetworking/`.

If credentials are missing (e.g., after a wipe), restore from `.tokens/` or re-run:
```
/Users/fperez2nd/bin/gam7/gam oauth create
```

## Domain-Wide Delegation

The service account has DWD authorized in Google Workspace Admin with these scopes:
- `https://mail.google.com/`
- `https://www.googleapis.com/auth/gmail.modify`
- `https://www.googleapis.com/auth/drive`
- `https://www.googleapis.com/auth/calendar`
- `https://www.googleapis.com/auth/contacts`
- `https://www.googleapis.com/auth/contacts.other.readonly`

To verify delegation is working for a user:
```
/Users/fperez2nd/bin/gam7/gam user <user@aionetworking.com> check serviceaccount
```

To update DWD scopes (e.g., after re-creating credentials):
```
/Users/fperez2nd/bin/gam7/gam user <any_user> check serviceaccount
# Follow the URL it outputs to update the DWD entry in Google Admin
```

## Clearing a User's Data (License Downgrade Prep)

Use case: downgrading a user from Google Workspace to Cloud Identity Free requires
clearing all shared storage (Gmail, Drive, Photos) and optionally Calendar/Contacts.

The account itself, YouTube history, third-party OAuth logins, and Google Authenticator
are NOT affected by these commands.

### Step-by-step

```bash
GAM=/Users/fperez2nd/bin/gam7/gam
USER=user@aionetworking.com

# 1. Gmail — delete all messages in all folders
$GAM user $USER delete messages query "in:anywhere" doit

# 2. Drive — delete all owned files (includes Google Photos)
$GAM user $USER print filelist fields id,name > /tmp/drive_files.csv
$GAM csv /tmp/drive_files.csv gam user $USER delete drivefile id ~id

# 3. Calendar — delete all events from primary calendar
$GAM user $USER delete events primary doit

# 4. Contacts — delete saved contacts (Other Contacts are auto-saved metadata, no quota impact)
$GAM user $USER print contacts fields name > /tmp/contacts.csv
# (batch delete if contacts exist — see notes below)

# 5. Google Photos — requires manual deletion; Photos Library API does not support DWD/service accounts
# Script at clear_photos.py exists but will fail with 403 until Google adds DWD support
# Have user log in to photos.google.com → select all → delete → empty trash
```

### Batch-clear multiple users

```bash
GAM=/Users/fperez2nd/bin/gam7/gam
for USER in user1@aionetworking.com user2@aionetworking.com; do
  echo "=== Clearing $USER ==="
  $GAM user $USER delete messages query "in:anywhere" doit
  $GAM user $USER print filelist fields id > /tmp/files_$USER.csv
  $GAM csv /tmp/files_$USER.csv gam user $USER delete drivefile id ~id
  $GAM user $USER delete events primary doit
done
```

### Check storage usage before/after

```bash
/Users/fperez2nd/bin/gam7/gam user <user@aionetworking.com> show profile
```

## Notes

- **Google Photos**: Photos Library API does not support service accounts or DWD — manual
  deletion only (`photos.google.com` → select all → delete → empty trash). Script
  `clear_photos.py` is ready for if/when Google adds DWD support.
- **Gmail deletion**: Use `clear_gmail.py` (not GAM) — GAM's `delete messages` query returns
  at most 1 message due to a search limitation. The Python script uses `batchDelete` and
  correctly processes all messages in pages of 500 including spam and trash.
- **Other Contacts** (auto-saved from email): not deletable via GAM; they don't count
  toward shared storage quota so they won't block a Cloud Identity Free downgrade.
- **Drive print filelist** only returns files the user *owns*. Files shared with them
  but owned by others are not touched.
- After clearing data, wait a few minutes before changing the license — Google's storage
  reporting can lag behind actual deletions.
- If `gam delete messages` returns 0 messages but storage is still showing used,
  check that Trash has been emptied (Google auto-purges trash after 30 days, or you
  can tell the user to empty it manually before running GAM).
