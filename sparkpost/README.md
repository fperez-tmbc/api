# SparkPost API Reference

SparkPost is **VitaNavis's** email service ("A MessageBird company"), owned and administered by TMBC.
Docs: <https://developers.sparkpost.com/api/>

## Account

| Field | Value |
|-------|-------|
| Company name | CPP Inc. |
| Customer ID | 192199 |
| Created | 2017-10-25 |
| Service level | standard, status `active` |
| Plan | `50K-starter-0519` "50K Starter" — 50,000 msg/month, $20/mo recurring, hard limit 150,000, overage enabled |
| `tfa_required` | **false** (see Users) |
| Console | <https://app.sparkpost.com> — login held by Frank |

Usage as of 2026-08-05: **3,800 / 50,000** this billing month (2026-07-13 → 08-13), 84 that day.
Check with `GET /usage`.

## Authentication

```bash
KEY=$(cat ~/GitHub/.tokens/sparkpost)
curl -s -H "Authorization: $KEY" https://api.sparkpost.com/api/v1/account
```

**The header is the raw key. NOT `Bearer`.** Basic auth also works (`Basic base64(key:)`).

Key on file: **`TMBC_Admin`**, created 2026-07-17, at `~/GitHub/.tokens/sparkpost` (chmod 600, never commit).

## Base URL

```
https://api.sparkpost.com/api/v1        # US (ours)
https://api.eu.sparkpost.com/api/v1     # EU — different account namespace, not ours
```

---

## ⚠️ READ THIS FIRST: source IP is everything here

**Every API key on this account is IP-restricted.** Misreading this has already cost a
misdiagnosis ("key revoked") and, separately, a QA email outage.

| Symptom | Actual meaning |
|---|---|
| **200s, plus 403 on `/api-keys` + `/users`** | key valid **and** source IP allowlisted — this is "working" |
| **401 on every endpoint** | auth rejected. **IP not allowlisted OR key revoked/rotated — the API cannot tell you which** |
| **403 on `/api-keys` and `/users` only** | normal and permanent, see below |
| **404 on `/transmissions`, `/snippets`, `/message-events`** | normal, see Endpoint matrix |
| **429** | rate limited, wait 1–5 s |
| **420** | daily/monthly sending cap hit |

**The 401 is not diagnosable from outside.** Verified 2026-08-05: a blocked IP, a deliberately
bogus key, and no `Authorization` header at all return **byte-identical** responses —
`HTTP 401`, `{"errors": [ {"message": "Unauthorized."} ]}`, no distinguishing header. So do not
report "the key is dead" or "the IP was removed" from a 401 alone.

Triage order:

1. **Is GlobalProtect connected, and is the macOS network extension approved?** SparkPost egresses
   the office IP via GP `include-domains` (see below). No GP, or an unapproved extension, means the
   call leaves from your local ISP and 401s.
2. Has `~/GitHub/.tokens/sparkpost` been modified? (`stat -f '%Sm'`)
3. If both are fine and it worked recently, the change was made **in the console** — check
   Configuration → API Keys for both the key's existence and its Allowed IPs.

The useful positive signal is the **403 on `/api-keys`**: if you get that, the key is good and your
source IP is accepted, because auth succeeded and only the endpoint was refused.

`TMBC_Admin` allowlist:

| IP | What it is | Status |
|---|---|---|
| `20.95.36.96` | office egress for **GlobalProtect-tunnelled** traffic | standing |

**SOLVED 2026-08-05: `api.sparkpost.com` is in GP `include-domains` on the `EMPLOYEES` gateway
config, so API calls now egress `20.95.36.96` over the tunnel.** No per-workstation IP allowlisting
is needed any more, and it survives a residential IP change. Frank's home IP was allowlisted
temporarily during diagnosis and then removed — do not re-add it.

Requirement: the **GlobalProtect macOS network extension must be user-approved**
(System Settings → General → Login Items & Extensions → Network Extensions). Domain-based split
tunnel is implemented via that extension; until it is approved the domain entry is silently inert.
The portal `split-tunnel-option` does **not** need changing — it is `network-traffic` here and the
domain entry works fine. PAN documents the DNS option as supplementary, not required.

### Do not use `route get` to test this

Domain-based split tunnel installs **no per-IP host routes**. It captures matched flows in the
extension and there is a `default` route on the GP `utun`. So `route -n get <resolved-ip>` reports
`en0` even while the traffic is tunnelling correctly. This misled the 2026-08-05 diagnosis badly.

**Test with the API response instead** — it is the only reliable signal:

```bash
KEY=$(cat ~/GitHub/.tokens/sparkpost)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: $KEY" \
  https://api.sparkpost.com/api/v1/api-keys     # 403 = auth OK (key + IP good). 401 = not.
```

Also note `api.ipify.org` is **not** a valid egress probe for this: it is not in `include-domains`,
so it reports the direct path while SparkPost tunnels.

The allowlist is editable **only** in the console (Configuration → API Keys → Allowed IPs), and
SparkPost keeps **no per-source-IP auth log** in either the API or the GUI — so "is the old IP
still in use?" is remove-and-watch, never a lookup.

`api.sparkpost.com` resolves to **rotating AWS IPs with a 60 s TTL** — 18 unique addresses across
18 different /16s observed in a 5-minute sample. Do not try to pin it by IP anywhere.

---

## Endpoint matrix (empirically verified 2026-08-05 with `TMBC_Admin`)

| Endpoint | GET | Notes |
|---|:---:|---|
| `/account` | 200 | 13 fields incl. subscription + options |
| `/usage` | 200 | current period consumption |
| `/sending-domains` | 200 | 2 |
| `/tracking-domains` | 200 | 1 |
| `/templates` | 200 | 1 (unused sample) |
| `/recipient-lists` | 200 | 1 (test list) |
| `/suppression-list` | 200 | paginated via `links`, no `total_rows` |
| `/sending-ips` | 200 | 0 — shared pool, no dedicated IPs |
| `/ip-pools` | 200 | 1 (`default`) |
| `/metrics` | 200 | discovery root |
| `/metrics/deliverability` | 200 | needs `from`, `to`, `metrics` |
| `/events/message` | 200 | needs `from`, `to`; **this is the current events API** |
| `/webhooks` | 200 | 1 |
| `/subaccounts` | 200 | 0 — none configured |
| `/inbound-domains` | 200 | 0 |
| `/relay-webhooks` | 200 | 0 |
| `/transmissions` | 404 | POST-only in practice; GET needs an id |
| `/snippets` | 404 | none defined; GET needs an id |
| `/message-events` | 404 | **deprecated**, use `/events/message` |
| `/data-privacy/...` | 404 | POST-only |
| `/seeds` | **403** | Seed List Deliverability not in our plan |
| `/api-keys` | **403** | see below |
| `/users` | **403** | see below |

### There is no user or API-key management API. At all.

Confirmed both from the docs and empirically: `/users` and `/api-keys` return **403 even with a
fully-granted key**. No "API Keys" or "Users" grant exists to enable them. This is a product
limitation, not a permissions problem, so:

- **Listing users → console CSV export only.** Account → Users → export.
- **Creating/rotating/deleting keys → console only.**
- **Reading or editing a key's IP allowlist → console only.**

Practical consequence for offboarding: you cannot script SparkPost access removal.

### Key grants held by `TMBC_Admin`

account, sending-domains, webhooks, ip-pools, sending-ips, subaccounts, transmissions.

---

## Users — only two, both shared, neither has 2FA

Export 2026-08-05:

| Username | Email | Role | 2FA | Notes |
|---|---|---|:---:|---|
| `it-9638` | it@vitanavis.com | **Admin** | ❌ | the console login Frank uses |
| `msmith-2941` | msmith@vitanavis.com | **Developer** | ❌ | **shared** dev login |

Nobody is provisioned individually. A contractor listed as having a SparkPost "Developer" role
has **no account to delete** — offboarding them means **rotating the shared `msmith-2941`
password**. `msmith@vitanavis.com` is also a proxyAddress on the `DL VitaNavis Development`
distribution list, i.e. a legacy shared identity rather than a person.

Account-level `tfa_required` is **false** and neither user has 2FA enabled. Worth fixing.

API-key rotation is **not** an offboarding trigger here, since every key is IP-restricted and
therefore unusable off-network.

---

## Domains

### Sending

| Domain | DKIM | SPF | Ownership | Compliance |
|---|---|---|:---:|---|
| `email.vitanavis.com` | **valid** (`scph1017`) | unverified | ✅ | valid |
| `bounces.vitanavis.com` | unverified | unverified | ✅ | valid |

**Neither is set as the default bounce domain** (`is_default_bounce_domain` unset on both). So
SparkPost's real Return-Path is its **shared** `spmailtechno.com`: SPF passes but is **unaligned**,
and mail survives DMARC (`p=quarantine`) on **DKIM alignment alone**. To add SPF alignment, set
`bounces.vitanavis.com` as the default bounce domain in the console — no DNS change needed.

### Tracking

`tracking.vitanavis.com` — verified, CNAME valid, `secure: false`, TLS status unknown (so click/open
tracking links are **http**).

### Sending IPs

None dedicated. Shared pool `default`.

---

## Webhooks

| Name | Target |
|---|---|
| `VitaNavis` | `https://culrmaho7k.execute-api.us-west-2.amazonaws.com/prod/email-statuses` |

Basic auth, active. Subscribed events: bounce, click, delay, delivery, generation_failure,
generation_rejection, initial_open, injection, link_unsubscribe, list_unsubscribe, open,
out_of_band. Last failure recorded 2026-05-26. Events land in `sparkpost_message_events`.

---

## Rate limits

- **429** = rate limited. Wait **1–5 s** and retry.
- `POST /transmissions` is **not** rate limited; `DELETE` requests are.
- **420** = daily or monthly sending cap reached (distinct from 429).

---

## Where SparkPost is used

Four surfaces, per `task-tracker/projects/vitanavis-mission-offboarding/sparkpost-to-ses.md`:

1. Main app REST
2. Notifications microservice REST
3. EDW / Kettle SMTP
4. Inbound event webhooks → `sparkpost_message_events`

A migration to **SES** is on the backlog. The technical argument is that SES authenticates by
IAM role/key rather than an IP allowlist, which removes this whole class of breakage. Full phased
plan in that same doc.

Prod egresses via the stable NAT EIP `52.27.47.230`. Dev-space boxes egress via their own public
IPs, which is why only QA broke on 2026-07-17 when the t2→t3 change moved them.

---

## Snippets

```bash
KEY=$(cat ~/GitHub/.tokens/sparkpost); H="Authorization: $KEY"
B=https://api.sparkpost.com/api/v1

# sanity check: 403 here means key + source IP are both good (see triage above)
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" $B/api-keys
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" $B/account

# current month usage
curl -s -H "$H" $B/usage | python3 -m json.tool

# deliverability for a window
curl -s -H "$H" "$B/metrics/deliverability?from=2026-08-01T00:00&to=2026-08-05T00:00\
&metrics=count_targeted,count_delivered,count_bounce,count_rejected" | python3 -m json.tool

# message events (NOT /message-events, that's deprecated)
curl -s -H "$H" "$B/events/message?from=2026-08-04T00:00Z&to=2026-08-05T00:00Z&per_page=10" \
  | python3 -m json.tool

# sending domain auth status
curl -s -H "$H" $B/sending-domains | python3 -c "
import json,sys
for d in json.load(sys.stdin)['results']:
    s=d.get('status',{})
    print(d['domain'], s.get('dkim_status'), s.get('spf_status'), s.get('compliance_status'))
"
```
