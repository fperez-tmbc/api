# Jamf Pro API

Tenant: `https://themyersbriggs.jamfcloud.com`

**Jamf is retired at TMBC.** This API access exists to shut down leftovers, not to manage
devices. The three Jamf enterprise apps still present in Entra (`Jamf Pro`,
`Jamf Connect`, `Jamf Pro Azure AD Connector`) are separate cleanup items.

## Tooling

### `jamf` — use this for all Jamf Pro API tasks

```bash
cd ~/GitHub/api/jamf
./jamf /v2/smtp-server                          # GET
./jamf PUT /v2/smtp-server '{"enabled":false, ...}'
```

Paths may be given with or without the `/api` prefix — `/v2/smtp-server` and
`/api/v2/smtp-server` are equivalent. Anything starting `/JSSResource` routes to the Classic
API untouched, but note the wrapper sends/expects JSON; for Classic XML use `curl` directly
(see the SMTP example below).

## Credentials

- **File:** `~/GitHub/.tokens/jamf` (outside any git repo, `chmod 600`, shell-sourceable)
- **Source of truth:** 1Password → vault **IT Operations** → item **Jamf API - automation**
- **Type:** API Client (OAuth client credentials), client name `automation`

```
POST $JAMF_URL/api/oauth/token
Content-Type: application/x-www-form-urlencoded
client_id=...&client_secret=...&grant_type=client_credentials
```

### Read the JSON blob field, NOT the standalone fields

The 1Password item carries three credential fields: `Client ID`, `Client secret`, and
`client credentials` (a JSON blob Jamf gives you at client-creation time).

**Use the `client credentials` blob.** On 2026-08-13 the standalone `Client ID` field was
stale — it still held the id of a retired `automation (1)` client while `Client secret` held
the *new* client's secret. That mismatched pair authenticates as:

```json
{"error": "invalid_client"}
```

which reads like a bad secret and sends you looking in the wrong place. The blob is always a
self-consistent `client_id` + `client_secret` pair because Jamf emits both together.

---

## Gotchas

### Disabling SMTP is blocked on v2, but NOT on the Classic API

`PUT /v2/smtp-server` with `"enabled": false` returns **403** even with
`Read SMTP Server` + `Update SMTP Server`:

```json
{"httpStatus":403,"errors":[{"description":
 "Use of this endpoint to disable SMTP server requires Self Service App Request read permission."}]}
```

Jamf needs a configured SMTP server for the Self Service **App Request** feature, so v2 guards
*disabling* SMTP behind that feature's read privilege. The privilege is named exactly
**`Read App Request Settings`** (verified against `/v1/api-role-privileges` on this tenant,
which lists 524 privileges total; the only four matching SMTP or App Request are
`Read SMTP Server`, `Update SMTP Server`, `Read App Request Settings`,
`Update App Request Settings`).

Reading and updating SMTP need only the two SMTP privileges; it is specifically the transition
to `enabled: false` that trips the check. Nothing in the `/v2/smtp-server` reference mentions
this, only the runtime error.

**The Classic API has no such guard.** This works with only `Update SMTP Server`, and is how
SMTP was actually disabled on 2026-08-13:

```bash
set -a; . ~/GitHub/.tokens/jamf; set +a
tok=$(curl -sS -X POST "$JAMF_URL/api/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=$JAMF_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_secret=$JAMF_CLIENT_SECRET" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -sS -X PUT -H "Authorization: Bearer $tok" -H "Content-Type: application/xml" \
  --data '<smtp_server><enabled>false</enabled></smtp_server>' \
  "$JAMF_URL/JSSResource/smtpserver"        # -> HTTP 201
```

Classic also accepts a **partial** body — just the one field you want to change. Verify through
either path; both reflect the change immediately.

So: prefer v2 generally, but when v2 403s on a privilege you don't want to chase, check whether
the Classic equivalent has the same guard. Often it doesn't.

### Access token lifetime is a per-client setting

The Jamf **default is 59 seconds**, which is far shorter than most vendors and will break any
script that caches a token. On this client the lifetime was raised to `2147483647` seconds
(~68 years) on 2026-08-13, so `expires_in` now comes back as `2147483646`.

`jamf` fetches a fresh token per invocation regardless, which is correct under either setting.

### `PUT /v2/smtp-server` is a full-object write, not a patch

`enabled`, `authenticationType`, and `senderSettings` are all **required**. GET-modify-PUT;
a lone `{"enabled": false}` is invalid. Enum for `authenticationType`:
`NONE` | `BASIC` | `GRAPH_API` | `GOOGLE_MAIL`.

Neither API returns the stored password (Classic shows `<password_sha256>********</password_sha256>`),
so a `BASIC` config cannot be round-tripped unchanged — re-PUTting as `BASIC` without a password
will error or blank the credential. The Classic partial-update avoids this entirely.

### The scoped role cannot enumerate its own privileges

`/v1/api-roles` and `/v1/api-role-privileges` both 403 unless the role grants them. You cannot
discover exact privilege strings via the API with a narrow client; read them off the console
picker at **Settings → System → API Roles and Clients**.

---

## Background: why this access exists

Jamf Pro's SMTP config held stale credentials for
`netops@myersbriggsco.onmicrosoft.com` and attempted SMTP AUTH against
`smtp.office365.com:587` **daily at 08:00 UTC**, plus ad-hoc runs, every attempt failing with
Entra error `50126` (invalid credentials). Last successful auth on that account was
2026-05-19, so Jamf notification mail had been failing silently for ~3 months.

Found 2026-08-13 while triaging an unrelated Entra ID Protection alert. The failed sign-ins
came from `140.150.103.6`, which RIPE attributes to **JAMF LTD** (the old Wandera range,
GB-registered). Entra's sign-in log geolocates that IP as "Portland, US", which is wrong —
trust the whois, not the GeoIP column.

Config as found (now `enabled: false`):

```json
{"enabled": true, "authenticationType": "BASIC",
 "senderSettings": {"displayName": "Jamf Pro Server",
                    "emailAddress": "netops@myersbriggsco.onmicrosoft.com"},
 "connectionSettings": {"host": "smtp.office365.com", "port": 587,
                        "encryptionType": "TLS_1_2", "connectionTimeout": 5}}
```

The stale credential is still *stored* (`authorization_required: true`, username intact); only
the transport is off. That is deliberate — it keeps the change trivially reversible. To also
clear the dead credential, PUT v2 with `authenticationType: NONE` (needs the App Request
privilege) or overwrite the Classic `<username>`/`<password>` fields.

Per-notification checkboxes are **not** a fix: Jamf's docs note some notifications
(CA expiration among them) are "enabled by default and cannot be disabled". Removing the
transport is the only way to stop all of them.
