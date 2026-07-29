# Mimecast API Notes

## API 2.0 Setup

- **App name:** tmbc-admin-api (created via Integrations → API and Platform Integrations → old UI)
- **Products:** All products selected
- **Role:** Claude (custom role created for automation)
- **Credentials:** `~/GitHub/.tokens/mimecast` — MIMECAST_CLIENT_ID and MIMECAST_CLIENT_SECRET
- **Auth:** OAuth 2.0 client credentials, token endpoint: `https://api.services.mimecast.com/oauth/token`
- **US base URL:** `https://us-api.services.mimecast.com`
- **Token TTL:** 30 minutes

## API 1.0

- App (claude-code) was created but never activated — **delete it**
- API 1.0 is being deprecated; new app creation restricted since early 2025
- Reference docs: https://integrations.mimecast.com/documentation/endpoint-reference/

## What's Available via API

### Impersonation Protection
- **Policy config:** NOT available in either API 1.0 or 2.0 — admin console only
- **Event logs (read-only):**
  - API 1.0: `Get TTP Impersonation Protect Logs`
  - API 2.0: Security Events product

### API 2.0 Policy Management endpoints (Cloud Gateway)
- Address Alteration (definitions + policies)
- Anti-spoofing Bypass
- Anti-spoofing
- Blocked Senders
- Delivery Route (definitions + policies)
- DNS Authentication Outbound (definitions + policies)
- Greylisting
- Web Security
- TTP URL Protect managed URLs

### NOT available via API — console only
- **Permitted Senders policies.** Only *Blocked* Senders is exposed. Every permitted-sender path
  (`policy/permitted-sender/get-policy`, `policy/permittedsender/...`, `policy/permittedsenders/...`)
  returns `app_forbidden` — *"Resource or method requested does not exist in any product assigned to
  the application."* Same for `policy/spam-scanning/get-policy`, `gateway/get-policy`, `policy/get-policy`.
  Group **membership** is readable (`directory/get-group-members`); the **policy** that consumes the
  group is not.
- Impersonation Protection policy config (see above)

## Permitted Senders — envelope vs header matching

`Administration → Gateway → Policies → Permitted Senders`

Each policy has an **Addresses Based On** field controlling which address it matches:

| Value | Matches |
|---|---|
| `The Return Address (Email Envelope From)` | envelope / P1 only |
| Header address (P2) | `From:` header only |
| `Both (Checks both Envelope and Header)` | either |

**The `Default Permitted Senders Policy` (From `[ Permitted senders ]` → Everyone) is deliberately
set to envelope-only, as an anti-spoofing measure. Do not change it.** Header-from is trivially
spoofable, and that group holds ~435 members of which ~368 are whole domains, so flipping it to
`Both` would let anyone forge a `From:` on any of those 368 domains and bypass spam scanning.

To permit a sender on its **header** address, create a **separate, narrowly scoped policy** with
`Addresses Based On = Both` and `Applies From = Individual Email Address`. Leave the default alone.

Caveat Mimecast prints on that screen: P2 or Both matching **cannot** bypass Greylisting or RBL
checks, which are envelope-based.

## Permitting AWS SNS / SES senders (the amazonses.com trap)

Worked example, resolved 2026-07-29 (SNS CloudWatch/RDS alerts graymailed into the Held Queue).

AWS SNS notification mail splits the two addresses:

| | Value | Stable? |
|---|---|---|
| Header From (P2) | `no-reply@sns.amazonaws.com` | **Yes** — invariant across all messages |
| Envelope From (P1) | `0101019fab39609e-9d2a6856-…-000000@us-west-2.amazonses.com` | **No** — local part is the SES message ID, unique per message |
| Envelope domain | `<region>.amazonses.com`, or bare `amazonses.com` | domain only, and it is **shared** |

Three rules:

1. **Never permit `amazonses.com` or `<region>.amazonses.com`.** Per AWS: *"Messages that you send
   through Amazon SES automatically use a subdomain of `amazonses.com` as the default MAIL FROM
   domain."* That domain is shared by every SES customer without a custom MAIL FROM, so permitting
   it whitelists a large share of the world's bulk mail. Confirmed in-tenant: graymail held from
   `…@amazonses.user.luma-mail.com`.
2. **Never click "Permit" from the Held Queue or a digest for an SES sender.** That captures the
   *envelope* address verbatim, creating a permanently dead entry that matched exactly one message.
   Five such corpses were found in the Permitted senders group (four traceable to specific 2026-07-06
   subscription-confirmation messages). Symptom: someone "already permitted" the sender, yet it keeps
   getting held.
3. **Permit the header address via a targeted policy.** Safe here because Mimecast validates it at
   the edge: `dkim=pass header.d=sns.amazonaws.com`, `dmarc=pass header.from=amazonaws.com`.

Working config:

| Field | Value |
|---|---|
| Policy Narrative | `Permit AWS SNS Notifications (Header Match)` |
| Permitted Sender Policy | `Permit sender` |
| Addresses Based On | `Both (Checks both Envelope and Header)` |
| Applies From | `Individual Email Address` → `no-reply@sns.amazonaws.com` |
| Applies To | `Everyone` |
| Policy Override | **unchecked** — checked would override Blocked Senders, a bypass you do not want on a shared AWS address |
| Source IP Ranges | **empty** — SES rotates IPs (30 distinct in 30 days), pinning breaks it |

Residual risk, accepted: `no-reply@sns.amazonaws.com` is AWS-shared, so any AWS account's SNS topics
use it. SNS requires subscription confirmation before content flows, so practical exposure is limited
to unsolicited confirmation mail.

## Reading envelope vs header for a message

`message-finder/search` returns `fromEnv` and `fromHdr` per message:

```zsh
curl -s -X POST "https://us-api.services.mimecast.com/api/message-finder/search" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"data":[{"start":"2026-07-01T00:00:00+0000","end":"2026-07-30T00:00:00+0000",
       "advancedTrackAndTraceOptions":{"from":"no-reply@sns.amazonaws.com","route":"inbound"}}]}'
```

- **Start date has a ~30 day cap.** Older values fail with
  `err_track_and_trace_invalid_start_date` and an empty `data` array (`meta.status` is still 200 —
  always check `fail[]`).
- `message-finder/get-message-info` (pass the `id` from search) gives the definitive
  `fromEnvelope` / `fromHeader` pair, plus `spamEvent`, `receiptEvent`, and the `policyInfo` list
  showing which policies actually fired. Use `policyInfo` to confirm a new permit policy is matching.
- `gateway/get-hold-message-list` returns held messages **directly as `data[]`** (not nested under a
  `heldMessages` key). Fields: `from` (envelope), `fromHeader`, `reason`, `reasonCode`, `policyInfo`.

## Impersonation Protection Config (from console screenshots)

### Definitions Summary

| Definition | Sim. Internal Domain | Sim. Monitored External | Newly Observed Domain | Display Name | Reply-to Mismatch | Targeted Threat Dict |
|---|---|---|---|---|---|---|
| Default Impersonation Protect Definition | ✅ | ❌ | ✅ | ✅ | ❌ | ✅ |
| Mark All Inbound Items as External | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Strict Impersonation Protection Definition | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |

---

### Default Impersonation Protect Definition

**Identifier Settings**
- Similar Internal Domain: ✅
- Similar Monitored External Domains: ❌
- Newly Observed Domain: ✅
- Display Name: ✅
  - All Internal Display Names: ✅
  - Custom Display Names: (empty)
- Reply-to Address Mismatch: ❌
- Targeted Threat Dictionary: ✅
  - Mimecast Threat Dictionary: ✅
  - Custom Threat Dictionary: CPP Custom Threat Dictionary
- Number of Hits: 2
- Enable Advanced Similar Domain Checks: ✅
- Ignore Signed Messages: ❌
- Bypass Managed & Permitted Senders: ❌

**Identifier Actions**
- Action: None
- Tag Message Body: ✅ — `*** This Message contains suspicious characteristics and has originated OUTSIDE your organization. ***`
- Tag Subject: ✅ — `[SUSPICIOUS MESSAGE]`
- Tag Header: ✅

**General Actions**
- Mark All Inbound Items as 'External': ❌

**Notifications**
- Notify Group: Admin Notifications
- Notify Overseers: ❌

---

### Mark All Inbound Items as External

**Identifier Settings**
- Similar Internal Domain: ❌
- Similar Monitored External Domains: ❌
- Newly Observed Domain: ❌
- Display Name: ❌
- Reply-to Address Mismatch: ❌
- Targeted Threat Dictionary: ✅
  - Mimecast Threat Dictionary: ❌
  - Custom Threat Dictionary: Flag All Custom Dictionary
- Number of Hits: 1
- Enable Advanced Similar Domain Checks: ❌
- Ignore Signed Messages: ❌
- Bypass Managed & Permitted Senders: ❌

**Identifier Actions**
- Action: None
- Tag Message Body: ❌
- Tag Subject: ❌
- Tag Header: ❌

**General Actions**
- Mark All Inbound Items as 'External': ✅
- Tag Message Body: ✅ — `*** This message originated OUTSIDE your organization. ***`
- Tag Subject: ✅ — `[EXTERNAL]`
- Tag Header: ❌

**Notifications**
- Notify Group: (none)
- Notify (Internal) Recipient: ❌
- Notify Overseers: ❌

---

### Strict Impersonation Protection Definition

**Identifier Settings**
- Similar Internal Domain: ✅
- Similar Monitored External Domains: ❌
- Newly Observed Domain: ✅
- Display Name: ✅
  - All Internal Display Names: ✅
  - Custom Display Names: (empty)
- Reply-to Address Mismatch: ✅
- Targeted Threat Dictionary: ✅
  - Mimecast Threat Dictionary: ✅
  - Custom Threat Dictionary: CPP Custom Threat Dictionary
- Number of Hits: 1
- Enable Advanced Similar Domain Checks: ✅
- Ignore Signed Messages: ❌
- Bypass Managed & Permitted Senders: ❌

**Identifier Actions**
- Action: **Hold for Review**
- Hold Type: User
- Moderator Group: (none)
- Tag Message Body: ✅ — `*** This Message contains suspicious characteristics and has originated OUTSIDE your organization. ***`
- Tag Subject: ✅ — `[SUSPICIOUS MESSAGE]`
- Tag Header: ✅

**General Actions**
- Mark All Inbound Items as 'External': ❌

**Notifications**
- Notify Group: Admin Notifications
- Notify (Internal) Recipient: ✅
- Notify Overseers: ❌

---

### Policies

#### Exclusion / Override Policies (5 rows)

| From | To | Policy (Definition) | Duration | Narrative |
|---|---|---|---|---|
| @*salesforce.com | Internal | Default Impersonation Protect Definition | Eternal | Exclude Salesforce (Default) |
| @*salesforce.com | Internal | Strict Impersonation Protection Definition | Eternal | Exclude Salesforce (Strict) |
| Exclude from Mark All External | Internal | Mark All Inbound Items as External | Eternal | Exclude from Mark All External |
| Exclude from Impersonation | Internal | Default Impersonation Protect Definition | Eternal | Excluded Domains (Default) |
| Exclude from Impersonation | Internal | Strict Impersonation Protection Definition | Eternal | Excluded Domains (Strict) |

#### Targeted / Per-Sender Policies (VIP protection)

These apply the Strict definition to specific named individuals to prevent display-name spoofing of executives/VIPs. Each is Eternal.

| From (display name) | To | Definition | Narrative |
|---|---|---|---|
| adobedesign@adobedesign.com | Internal | Default Impersonation Protect Definition | Adobe E Sign |
| Bill Chapman | Internal | Strict | From Bill Chapman |
| Bryan Martin | Internal | Strict | From Bryan Martin |
| Cal Finch | Internal | Strict | From Cal Finch |
| Calvin Finch | Internal | Strict | From Calvin Finch |
| Calvin W. Finch | Internal | Strict | From Calvin W. Finch |
| Dayna Williams | Internal | Strict | From Dayna Williams |
| Eugene Pace | Internal | Strict | From Eugene Pace |
| Finch Calvin | Internal | Strict | From Finch Calvin |
| Hayes, Jeffrey | Internal | Strict | From Hayes, Jeffrey |
| Jeff Hayes | Internal | Strict | From Jeff Hayes |
| Jeffrey Hayes | Internal | Strict | From Jeffrey Hayes |
| John Maketa | Internal | Strict | From John Maketa |
| Liam Oconnor | Internal | Strict | From Liam Oconnor |
| Liam O'Connor | Internal | Strict | From Liam O'Connor |
| Robin Robbins | Internal | Strict | From Robin Robbins |
| Thaddious G. Stephens | Internal | Strict | From Thaddious G. Stephens |
| Thad Stephens | Internal | Strict | From Thad Stephens |
| Tracey Skates | Internal | Strict | From Tracey Skates |
| William Chapman | Internal | Strict | From William Chapman |

## Useful Commands

```bash
# Get OAuth token
source ~/GitHub/.tokens/mimecast
curl -s -X POST "https://api.services.mimecast.com/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${MIMECAST_CLIENT_ID}&client_secret=${MIMECAST_CLIENT_SECRET}"
```

## Chrome Headless (for JS-rendered pages)

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --headless --dump-dom --virtual-time-budget=8000 "<URL>" 2>/dev/null
```
