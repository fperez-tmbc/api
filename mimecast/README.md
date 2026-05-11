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
