# Sophos Email Appliance (SEA) — prodsmtp Field Notes

## Credentials

- **Creds:** `~/GitHub/.tokens/sea` — `USERNAME` / `PASSWORD`
- **Admin URL:** `https://prodsmtp.opp.com:18080/`
- **Version:** 4.5.3.2-2846662

## General

- **Hostname:** prodsmtp (opp.com)
- **Private IP:** 192.168.205.21/24, gateway 192.168.205.254
- **Public IP (NAT):** 20.95.36.140 (PAN loopback.140, object `PRODSMTP.OPP_PUBLIC`)
- **DNS:** 8.8.8.8, 8.8.4.4
- **Timezone:** Europe/London

## Authentication

The web UI uses a JavaScript RPC framework. Auth is two-step:

```bash
CREDS=$(cat ~/GitHub/.tokens/sea)
USER=$(echo "$CREDS" | grep '^USERNAME' | cut -d= -f2)
PASS=$(echo "$CREDS" | grep '^PASSWORD' | cut -d= -f2)

# Step 1: get session cookie + IDREF
curl -sk -c /tmp/sea-cookies.txt "https://prodsmtp.opp.com:18080/Login" -o /tmp/sea-login.html
IDREF=$(grep -o 'content="[a-f0-9]\{32\}"' /tmp/sea-login.html | cut -d'"' -f2)

# Step 2: login
curl -sk -c /tmp/sea-cookies.txt -b /tmp/sea-cookies.txt \
  "https://prodsmtp.opp.com:18080/ajax/Page/Login/ServerLogin" \
  -H "X-IDREF: $IDREF" -H "X-Requested-With: XMLHttpRequest" \
  -H "Content-Type: application/json" \
  -d "{\"user\":\"$USER\",\"password\":\"$PASS\",\"password2\":\"\",\"go\":\"/Dashboard\",\"window\":\"1920x1080\",\"screen\":\"1920x1080\"}"

# Step 3: fetch an authenticated page to get a fresh IDREF
curl -sk -c /tmp/sea-cookies.txt -b /tmp/sea-cookies.txt \
  "https://prodsmtp.opp.com:18080/Dashboard" -o /tmp/sea-dash.html
IDREF=$(grep -o 'content="[a-f0-9]\{32\}"' /tmp/sea-dash.html | cut -d'"' -f2)
```

All subsequent calls use the session cookie + `X-IDREF` header. The IDREF rotates — re-fetch from the latest page response if calls start failing.

## API Pattern

All data calls are:

```bash
curl -sk -b /tmp/sea-cookies.txt \
  "https://prodsmtp.opp.com:18080/ajax/Page/<PageName>/<Method>" \
  -H "X-IDREF: $IDREF" \
  -H "X-Requested-With: XMLHttpRequest" \
  -H "Content-Type: application/json" \
  -d '{...args...}'
```

Response format: `{"args": {...}, "method": "on<Method>"}` on success, or an HTML error page on 4xx/5xx.

## Known Pages and Methods

| Page path | Method | Notes |
|-----------|--------|-------|
| `Login/ServerLogin` | POST | Auth — see above |
| `Setup/GetData` | `{}` | Network, domain, postmaster, antispam mode |
| `NetworkInterface/GetData` | `{}` | IP, gateway, DNS |
| `HostnameProxy/GetData` | `{}` | Hostname, proxy, primary domain |
| `OutboundMailProxy/GetData` | `{}` | Smart host (outbound relay) config |
| `SMTPAuthentication/GetData` | `{}` | SMTP AUTH settings |
| `SMTPOptions/GetData` | `{}` | Postfix tuning parameters |
| `FilteringOptions/GetData` | `{}` | Antispam/AV settings |
| `InternalMailHosts/GetData` | `{}` | Internal mail hosts (empty = not configured) |
| `TrustedRelays/GetData` | `{}` | Trusted relay IPs (empty) |
| `MailDeliveryServers/GetData` | `{}` | Inbound delivery targets (empty) |
| `Search/MessageForensics/Search` | see below | Message log search |
| `Search/MailQueue/GetData` | `{}` | Current mail queue — **returns empty `data: {}` even when messages are queued (API blind spot; check UI)** |
| `Search/Quarantine/GetData` | `{}` | Quarantine |

### MessageForensics Search

```bash
curl -sk -b /tmp/sea-cookies.txt \
  "https://prodsmtp.opp.com:18080/ajax/Page/Search/MessageForensics/Search" \
  -H "X-IDREF: $IDREF" -H "X-Requested-With: XMLHttpRequest" \
  -H "Content-Type: application/json" \
  -d '{
    "date_from": "04/01/2026",
    "date_to": "05/11/2026",
    "count": 500,
    "page": 1,
    "sort_by": 0,
    "fresh": true,
    "reverse": true
  }'
```

Date format: `MM/DD/YYYY`. Response includes `rowcount` and `row_data` array.

**`row_data` field order (corrected):**

| Index | Field |
|-------|-------|
| 0 | base64-encoded MTA log line |
| 1 | timestamp |
| 2 | from |
| 3 | to |
| 4 | relay_source (e.g. Mimecast IP, or SEA itself for outbound) |
| 5 | relay_dest |
| 6 | subject |

**Decoded MTA log line** — tab-delimited, fields include:
`source_IP`, `timestamp`, `action` (e.g. `ACCEPT`), `from`, `message_id`, `relay_dest`, `relay_source`, `recipients`, `classification`, `subject`, `size`, `RULE`, `relay_tls`, `direction`, `queue_ids`, `archive_refs`

Decode with:
```bash
echo "<base64_field>" | base64 -d
```

### MessageDetails Popup

The web UI uses a JS popup class (`Popup__MessageDetails`) opened with a `logdata` key from row_data[0]. The underlying endpoint **exists** but is not programmatically accessible:

- `POST /ajax/Popup/MessageDetails/GetData` with `{logdata: <key>}` → HTTP 200 but returns `"logdata was not declared"` (Perl backend rejects the parameter)
- `GET /Popup/MessageDetails.tabcontent?logdata=<key>` → 404
- Parameter name variations (`log_data`, `ref`, `message_id`) → all rejected

**Bottom line:** email headers and full message details are only accessible via the browser UI, not via curl.

## Current Configuration

| Setting | Value |
|---------|-------|
| Antispam mode | **passthrough** — no scanning |
| SMTP auth | Disabled |
| Outbound smart host | `us-smtp-outbound-1.mimecast.com:25`, TLS, no auth |
| Inbound delivery | → 192.168.205.20 (internal OPP Exchange/mail server) |
| Postmaster / alerts | servicedesk@opp.com |

## Mail Flow (as observed)

**Outbound:** `live_postmaster@opp.com` → `_itinfrastructure@opp.com` ~2×/day
- SEA's own postmaster sender identity (system heartbeat) — not an external source
- Relayed outbound via Mimecast smart host

**Inbound:** External senders → `(2) Staging_QuestionnairesReceived@themyersbriggs.com`
- Sources: direct SMTP, Brevo (sender-sib.com), Mailchimp (rsgsv.net)
- Full chain: Internet → Mimecast/MessageLabs → **SEA (192.168.205.21)** → **ASPDVFNP11 (192.168.205.20)** → **SVEXCHDC01 (10.70.16.178)**
- ASPDVFNP11 is a **Windows Server 2008 IIS SMTP relay** — not Exchange; it forwards to SVEXCHDC01 via internal DNS MX
- Internal DNS (ASPDVDMC01, 192.168.207.1) resolves `themyersbriggs.com` MX to `owa.themyersbriggs.com` → `SVEXCHDC01.cpp-db.com` (bypasses Mimecast for internal delivery)
- ASPDVFNP11 also receives relay from **SVMONDC02 (10.70.16.102)** — two relay sources total
- **Decommission dependency:** Both SEA and SVMONDC02 must be reconfigured before ASPDVFNP11 can be decommissioned

## PAN NAT

Bi-directional static NAT rule `PRODSMTP.OPP.COM`:
- ASPDVSEA01 (192.168.205.21) ↔ PRODSMTP.OPP_PUBLIC (20.95.36.140)
- Inbound allowed from: `Grp-Message_Labs` (11 MessageLabs IP ranges) + `MIMECAST`
- Outbound relay: `ASPDVSEA01` + `SVEXCHDC01` → `MIMECAST`

## Decommission / IP Move Notes

- **IP move**: Sophos appliance config requires **no changes** — private IP (192.168.205.21) is unaffected. Update PAN loopback + address object, Cloudflare A record, and Mimecast (both inbound delivery target and outbound allowed sender IP).
- **Decommission blocker**: Appliance actively receives OPP questionnaire responses. The OPP team must confirm an alternative inbound path before decommissioning.
