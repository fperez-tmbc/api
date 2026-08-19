# Google APIs

Two separate Google tenants are configured on this machine. They share the GAM binary
and the gcloud CLI but nothing else. Keeping them apart is deliberate: pick the wrong
selector and you administer the wrong company.

| Tenant | Type | Selector |
|--------|------|----------|
| themyersbriggs.com | Corporate, Workspace Business Standard | **all defaults** — bare `gam`, `gcloud`, `bq`, `gsutil`, ADC |
| aionetworking.com | Personal, RETIRED | `gam select personal` / `gcloud --configuration=default` |

**Everything defaults to CORPORATE as of 2026-08-19.** `gam.cfg` has `section = tmbc`
in `[DEFAULT]`, the active gcloud configuration is `tmbc`, and ADC carries quota project
`tmbc-fperez-automation`. A bare command administers the company, with no warning.

The personal tenant is retired and reachable only by naming it explicitly. Assume any
unqualified Google command in a script or a copied snippet targets production.

---

# Corporate: themyersbriggs.com

Set up 2026-08-19. Workspace Business Standard, 5 licensed users. Mail does NOT route
to Google (MX points at Exchange).

**Productivity apps are effectively unused, but the tenant is not idle.** Measured from
the Reports API on 2026-08-15: Gmail 0 MB stored with a single email and one webmail
user; Drive 218 MB with one active user in 30 days; Meet, Classroom, ChromeOS and Apps
Script all zero.

What is actually live is **identity and devices**: 27 authorized third-party SaaS apps
using Google as an SSO provider, and 4 managed endpoints over 30 days across 2 users,
one of them flagged risky.

Practical consequence: the missing domain-wide delegation below costs nothing real,
since there are no mailboxes or Drive content to reach. Do not relax the org key policy
to obtain it without a concrete need. But do not treat this tenant as dormant either.

## Identifiers

| Field | Value |
|-------|-------|
| Primary domain | themyersbriggs.com (aliases: mbti.com, test-google-a.com) |
| Workspace Customer ID | C0314gz35 |
| GCP Organization ID | 714796663328 |
| GCP Project | tmbc-fperez-automation (number 560233548565) |
| Service account | tmbc-automation-sa@tmbc-fperez-automation.iam.gserviceaccount.com |
| Admin account | fperez@themyersbriggs.com (super admin) |

OAuth client ID and secret are in 1Password: **Employee vault → "Google Workspace API -
tmbc-fperez-automation"**. This is Frank's own access, so it lives in Employee, not a
shared vault.

## Usage

```bash
# Workspace admin (40 scopes, user OAuth)
gam print users              # bare gam = corporate
gam info customer
gam select personal info customer   # explicit personal

# GCP (bare gcloud is corporate)
gcloud projects describe tmbc-fperez-automation

# GA4 / Tag Manager / Search Console
~/GitHub/.venv-google/bin/python tmbc-marketing.py discover
```

## Credential files

Config section `[tmbc]` in `~/.gam/gam.cfg` points `config_dir` at `~/.gam/tmbc/`.

| File | Purpose |
|------|---------|
| `~/.gam/tmbc/client_secrets.json` | OAuth desktop client |
| `~/.gam/tmbc/oauth2.txt` | GAM user token, 40 admin scopes |
| `.tokens/google-tmbc/marketing-token.json` | GA4 / GTM / Search Console, 7 scopes |

All backed up to the `google-tmbc` tokens directory.

## Org-level access

Frank holds `roles/resourcemanager.organizationAdmin` at the org root, granted
2026-08-19. Matt Humora holds the same; asherwood holds `roles/cloud.admin`.

Frank also holds `roles/orgpolicy.policyAdmin`, granted 2026-08-19, since
`organizationAdmin` does not confer `orgpolicy.policy.set` on its own (verified by live
test). That makes the key constraints below *changeable* by him, though they have not
been changed.

This org is actively used, not a shell for automation. Other projects in it, all owned
by mhumora, relate to a B2C build:

| Project | Name | Created |
|---------|------|---------|
| `tmbc-b2c-prod` | tmbc-b2c-prod | 2026-08-19 |
| `dev-b2cproject` | tmbc-b2c-dev | 2026-03-12 |
| `hardy-force-505017-s5` | GoogleTagManagerAccess | 2026-08-09 |

Treat anything outside `tmbc-fperez-automation` as someone else's production.

## Service account keys are blocked at org level

Both of these org policies are **enforced and inherited** from the organization:

- `constraints/iam.disableServiceAccountKeyCreation`
- `constraints/iam.disableServiceAccountKeyUpload`

They are Google secure-by-default policies applied automatically to organizations
created after May 2024. Confirmed by live test, not by reading policy: creating a
Google-generated key and uploading a locally-generated 4096-bit public key both fail
with `FAILED_PRECONDITION`.

**Consequence:** the service account has no key, so **domain-wide delegation is not
configured**. Everything runs on user OAuth instead. That covers all directory admin
(users, groups, org units, devices, roles, licences, audit reports) but NOT acting as
another user to reach their Gmail or Drive.

Relaxing this needs `roles/orgpolicy.policyAdmin` at the org, and should be scoped to a
single project rather than the whole org if it is ever done.

## Gotchas

- **GAM validates scopes** against its own allow-list. `cloud-platform`, `apps.alerts`,
  `admin.directory.group.member` and `cloud-identity` are all rejected. Pass a bad scope
  and GAM prints the full valid list, which is the fastest way to discover it.
- **Analytics, Tag Manager and Search Console scopes are not in GAM's list at all.** They
  need the separate token that `tmbc-marketing.py` manages.
- **ADC is global, not per-configuration.** `gcloud auth application-default login` writes
  one file shared by every account on the machine. Running it for corporate silently
  clobbers the personal tenant's ADC. `tmbc-marketing.py` deliberately avoids ADC.
- **`gam ... use project` needs a real TTY.** Running it via a non-interactive shell dies
  with `EOFError` at the "Enter your Client ID" prompt. The browser half of the flow
  survives (GAM runs a local capture server) but the paste-back half does not.
- **No API exists to create an OAuth client ID.** That step is unavoidably the Cloud
  Console. Everything downstream of it can be scripted.
- As of setup, this account had **no** GA4 properties, GTM containers or Search Console
  sites attached. Verified negative: the API calls succeeded and returned empty.

---

# Personal: aionetworking.com (RETIRED)

**This tenant was spun up to migrate off, and that migration is complete.** The stored
OAuth token stopped refreshing after 2026-05-12 and now fails with "Reauthentication is
needed", which is expected for a tenant that is no longer in use.

The `[personal]` section in `gam.cfg` is kept only as a way back if something turns out
to still be needed. Everything below is historical reference, not a live runbook. Do not
assume any of it still works without re-authenticating first.

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

## Updating GAM

**Never run the GAM update installer in a background Claude Code task.** The installer
is interactive — it prompts "Please answer yes or no" for alias/profile updates and will
loop forever if there is no TTY, filling disk. This caused a 787 GB runaway file in May 2026.

To update GAM, run it directly in a terminal:
```bash
bash <(curl -s -S -L https://gam-shortn.appspot.com/gam-install)
```

If a non-interactive update is ever needed, set `ANSWER_YES=1` and `NONINTERACTIVE=1`
before running the installer, and verify the installer honors those flags first.

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
