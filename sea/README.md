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
| `Search/MailQueue/GetData` | `{}` | Current mail queue |
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
Each `row_data` entry: `[base64_detail, timestamp, from, to, subject, relay_dest, ...]`
The base64 field decodes to a tab-delimited MTA log line.

## Current Configuration

| Setting | Value |
|---------|-------|
| Antispam mode | **passthrough** — no scanning |
| SMTP auth | Disabled |
| Outbound smart host | `us-smtp-outbound-1.mimecast.com:25`, TLS, no auth |
| Inbound delivery | → 192.168.205.20 (internal OPP Exchange/mail server) |
| Postmaster / alerts | servicedesk@opp.com |

## Mail Flow (as observed)

**Outbound:** `live_postmaster@opp.com` → `_itinfrastructure@opp.com` ~2×/day (system heartbeat)

**Inbound:** External senders → `(2) Staging_QuestionnairesReceived@themyersbriggs.com`
- Sources: direct SMTP, Brevo (sender-sib.com), Mailchimp (rsgsv.net)
- These are OPP assessment questionnaire responses from participants
- Delivered internally to 192.168.205.20

## PAN NAT

Bi-directional static NAT rule `PRODSMTP.OPP.COM`:
- ASPDVSEA01 (192.168.205.21) ↔ PRODSMTP.OPP_PUBLIC (20.95.36.140)
- Inbound allowed from: `Grp-Message_Labs` (11 MessageLabs IP ranges) + `MIMECAST`
- Outbound relay: `ASPDVSEA01` + `SVEXCHDC01` → `MIMECAST`

## Decommission / IP Move Notes

- **IP move**: Sophos appliance config requires **no changes** — private IP (192.168.205.21) is unaffected. Update PAN loopback + address object, Cloudflare A record, and Mimecast (both inbound delivery target and outbound allowed sender IP).
- **Decommission blocker**: Appliance actively receives OPP questionnaire responses. The OPP team must confirm an alternative inbound path before decommissioning.
