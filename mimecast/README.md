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
- **Anti-spoofing policy** (`policy/antispoofing/get-policy`) → `app_forbidden`.
  `policy/antispoofing-bypass/get-policy` exists but needs a specific `id`, so it can't be enumerated.
- **Group membership WRITES.** `directory/add-group-member` and `directory/remove-group-member` both
  exist and pass schema validation, but every call against the `Permitted senders` group fails with
  `err_xdk_operation_forbidden_for_address` — *"0003 Forbidden To Perform Operation For Address"*.
  Reads work, writes do not. **Group edits must be done in the console.** Verified 2026-07-29 across
  23 entries: 0 succeeded, member count unchanged, no partial state.
- Impersonation Protection policy config (see above)

### Group IDs: always resolve dynamically
Group IDs are ~250-char base64 blobs and are trivially corrupted by copy-paste. A truncated ID gives
`HTTP 400` with an **empty response body**, which is easy to misread as a transient failure. Never
hardcode one; look it up by description each run:

```python
j = call("directory/find-groups", {"data":[{"source":"cloud"}],
                                  "meta":{"pagination":{"pageSize":200}}})
gid = next(f["id"] for f in j["data"][0]["folders"]
           if f["description"] == "Permitted senders")
```

### Group members carry `notes`, `name` and `type` — always read them

`directory/get-group-members` returns far more than the address. **Pull these before judging any
entry**; they frequently contain the justification and change the verdict.

```python
{"emailAddress": "jeff-hayes1@comcast.net", "name": "", "internal": False,
 "domain": "comcast.net", "type": "created_manually",
 "notes": "Jeff Hayes's personal email address. Thad approved it."}
```

| Field | Meaning |
|---|---|
| `notes` | Free-text justification an admin typed in the console |
| `name` | Display name captured when the entry was created |
| `type` | `created_manually` / `created_by_email` / `contact_from_ldap` — how it got there |

Bare-domain entries have `emailAddress: ""` and the domain in `domain`; address entries populate both.

Verified 2026-07-30 on the `Permitted senders` group (405 members, 30 with notes) and
`Blocked Senders` (122 members, 50 with notes). Blocked entries are typically well annotated
(*"Jeff phishing"*, *"pretending to be HR"*, *"A copycat/impostor site. Do Not Use."*); permitted
entries much less so. **An undocumented bare-domain permit is more likely accumulated residue than a
decision** — the deliberate ones tend to say why (*"HR Benefits"*, *"We use this product (Centrify)"*,
*"Requested by Nicole per SD ticket #84579"*).

Paging: `meta.pagination.pageSize` up to 500, follow `meta.pagination.next` → `pageToken`.
A single unpaged call silently caps at 999 (a `/groups` pull returned 999 of 1093).

### Pagination and sort order will mislead you

`archive/search` returns **newest first**. A `page-size` smaller than the true result count therefore
gives you the most recent slice, not a sample of the whole. Verified 2026-07-30: a 30-row pull of
`gmx.com` returned nothing but 2021 subscription scams and supported "the block is correct"; the full
132 rows showed roughly 60% legitimate German customer and job-applicant correspondence, and the
opposite conclusion. **Before characterising what a sender carries, page to the end or raise
`page-size` past the total.**

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

### Reading matching mode off the policy LIST (no need to open each policy)

In the Gateway Policies list, the **From** column wraps the value in square brackets when the policy
is **envelope-only**; no brackets means **Both**:

```
[ @*.adp.com]                 <- envelope only (P1)
[ Permitted senders]          <- envelope only (P1)  - the Default Permitted Senders Policy
@*.myob.com                   <- Both (P1 + P2)
no-reply@sns.amazonaws.com    <- Both (P1 + P2)
```

Verified 2026-07-29 against three policies whose detail pages were open at the same time. This is the
fast way to audit matching mode across the whole list, which matters because Permitted Senders policy
config is **not** readable via the API.

### Wildcards: policies only, never groups

`@*.domain.com` wildcards work in an **individual policy**. Profile groups are **exact match only** —
a root domain in a group does **not** cover its subdomains, and wildcards cannot be added to a group.

So a vendor using subdomains needs both:
- an individual policy `@*.vendor.com` for the subdomains, and
- an exact group entry `vendor.com` for the apex (the wildcard is not known to cover the apex; TMBC
  mirrors this pattern for Salesforce, Expensify, Atlassian, ADP and Fidelity).

**Do not infer subdomain coverage from mail being delivered.** Delivery is the default; a permit only
bypasses spam scanning. Confusing the two produced a wrong conclusion on 2026-07-29.
`message-finder/get-message-info` → `policyInfo` reports the policy *type* and *action*
(`Permitted Senders` / `Permit sender`) but **not** the policy narrative, so it cannot tell you which
of two candidate policies matched.

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

## Archive Search — full retention (`archive/search`)

**Use this, not `message-finder/search`, for any "when did we last get mail from X" question.**
`message-finder` caps at ~30 days. Archive search reaches back to **at least 2015** (verified: probed
2016 / 2018 / 2020 / 2022 / 2024, all returned results).

### The two gotchas that cost an hour on 2026-07-29

1. **`"admin": true` is REQUIRED in the data object.** Without it every query returns
   `meta.status: 200` with `data[0].items == []` — a silent empty result, not an error. This looks
   exactly like "no permission" or "no such mail" and will send you chasing the wrong problem.
   It is easy to conclude the archive is unlicensed. It is not.
2. **`query` is Mimecast search XML**, passed as a JSON *string*. A plain string like
   `"from:x@y.com"` fails with `err_invalid_search_xml`.

### Working recipe (verified)

```python
RF = "".join(f"<return-field>{f}</return-field>" for f in
             ("subject","receiveddate","displayfrom","displayto","status","id","smash"))

query = ('<?xml version="1.0"?><xmlquery trace="iql,muse">'
         '<metadata query-type="emailarchive" archive="true" active="false"'
         ' page-size="3" startrow="0">'
         '<mailboxes/><smartfolders/>'                       # empty = org-wide (with admin:true)
         f'<return-fields>{RF}</return-fields></metadata>'
         '<muse><text></text>'
         '<date select="between" from="2015-01-01T00:00:00Z" to="2026-07-30T00:00:00Z"/>'
         '<sent select="from">example.com</sent>'            # address OR bare domain
         '</muse></xmlquery>')

body = {"data": [{"admin": True, "query": query}]}           # <-- admin:true is the magic
```

### Query notes
- `<sent select="from">` accepts a **full address or a bare domain**, and matches the envelope as
  well as the header. Searching a parent domain also catches subdomain senders (searching
  `analytics.getsafebase.com` surfaced mail whose envelope was `em377.analytics.getsafebase.com`).
- **To filter by recipient, use `<sent select="to">…</sent>`.** It combines with
  `<sent select="from">` in the same `<muse>` block to answer "what did X send to Y".
  Verified 2026-07-30: `hotmail.com` org-wide returned 10 hits, and adding
  `<sent select="to">amoore@themyersbriggs.com</sent>` narrowed it to 3.

  **`<received select="to">`, `<to>` and `<recipient>` are silently ignored** — no error, no
  `err_invalid_search_xml`, the query just returns the unfiltered org-wide result. This is the
  dangerous failure mode: results look plausible and are wrong. If every recipient you test
  returns the same senders and the same count, the filter is not being applied. Sanity-check by
  running the query with and without the filter and confirming the count actually drops.
- `<text>` is **loose relevance matching, NOT substring search. Do not use it for forensics.**
  Verified 2026-07-29: `<text>Websense</text>` returned South Ayrshire MBTI enquiries with no
  connection to Websense, and `<text>mbtithinkbox</text>` returned generic ADReport / Desktop Central
  scheduled reports whose bodies (checked via `messageBodyPreview`) contain no such string. It behaves
  like a relevance-ranked recent-mail query. Use `<sent>` for sender questions, and always verify any
  `<text>` hit by pulling `archive/get-message-detail` → `messageBodyPreview` before believing it.
- `<date>` accepts `select="between"` with `from`/`to`, or named ranges like `select="last_year"`.
- Results come back **newest first**, so `page-size="1..3"` is enough to answer "last seen".
- Response shape varies: results may be `data[0]["items"]` **or** a flat `data[]` list of messages.
  Handle both:
  ```python
  d = j.get("data", [])
  items = d[0]["items"] if (d and isinstance(d[0], dict) and "items" in d[0]) else d
  ```
- Paging uses `meta.pagination.next` → pass back as `meta.pagination.pageToken`.
- `archive/create-search` and `archive/get-search-results` are **`app_forbidden`**; only
  `archive/search` and `archive/get-archive-search-logs` are available.

## Audit log — the change-history tool (`audit/get-audit-events`)

**Best available answer to "what changed, when, and who did it."** Requires `startDateTime` and
`endDateTime`; both are mandatory or you get two `err_validation_null`.

```zsh
curl -s -X POST "https://us-api.services.mimecast.com/api/audit/get-audit-events" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"data":[{"startDateTime":"2026-07-29T00:00:00+0000",
                "endDateTime":"2026-07-30T00:00:00+0000"}],
       "meta":{"pagination":{"pageSize":100}}}'
```

Returns `id`, `auditType`, `user`, `eventTime`, `eventInfo`, `category`. **`eventInfo` contains the
full policy definition**, which is how you reconstruct a policy you can no longer read via the
policy endpoints:

```
2026-07-29T19:27:28  New Policy  Anti-Spoofing [TEMP]
  F(@themyersbriggs.net) T(Internal) [Active] [Apply Anti-Spoofing (Exclude Mimecast IPs)]
```

- **Retention is ~60-90 days.** Verified 2026-07-29: single-day probes return rows for 2026-06-15
  through today, zero for 2026-05-01 and anything older. Useless for migration-era archaeology.
- `auditType` values seen: `New Policy`, `Policy Deleted`, `Existing Policy Changed`,
  `Domain Adjustments`, `Profile Group (unlink) Log Entry`.
- `audit/get-audit-categories`, `account/get-audit-events` and `audit/search` are all unavailable.
- Page via `meta.pagination.next` → `pageToken`.

**Use this to timestamp your own changes before drawing conclusions from mail flow.** On 2026-07-29
an anti-spoofing policy was created at 19:27:28 and messages at 19:00:05 were wrongly cited as proof
it hadn't broken anything. The audit log is what caught it.

## Anti-Spoofing — semantics that are not obvious

- **Anti-Spoofing OVERRIDES Permitted Senders.** Per Mimecast, a message from a Permitted Sender is
  still rejected if detected as spoofing. So an anti-spoofing policy outranks the whole permit layer.
  Never assume a permit entry protects a flow from anti-spoofing.
- **Anti-Spoofing does NOT honour your SPF record.** That is why Mimecast ships a separate
  `Anti-Spoofing SPF Bypass` policy type; it would be redundant otherwise. Independent confirmation:
  Salesforce's KB for `550 Anti-Spoofing policy - Inbound not allowed` (post-Hyperforce) tells
  customers to configure a Mimecast SPF-based bypass, **not** to fix SPF. Correct SPF is not a
  defence against anti-spoofing rejection.
- **`Default Anti-Spoofing Allow Policy` is an exception holder, not an enforcement policy.** Its
  documented use is Everyone→Everyone with **Policy Override** ticked and legitimate third-party
  sender IPs in **Source IP Ranges**. It is disabled at TMBC and should stay that way; enabling it as
  a blanket `Apply Anti-Spoofing` would (a) lack the Mimecast IP exclusion that every per-domain
  policy has, breaking journaling/forwarding loopback, and (b) sit above the entire Permitted Senders
  layer.
- **Correct per-domain baseline** (all 19 TMBC internal domains, verified 2026-07-29):
  `Apply Anti-Spoofing (Exclude Mimecast IPs)`, `Addresses Based On = Both`, From = Email Domain,
  To = Internal Addresses, Enable, Always On, no Policy Override, no Bi Directional, empty Source IPs.
- Mimecast guidance: every internal domain needs either an `Apply Anti-Spoofing (exclude Mimecast IPs)`
  policy **or** a `Take No Action` policy restricted by source IP. Nothing should be uncovered.
- Beware SPF-bypass policies containing broad cloud ranges (O365, Google) — same shared-infrastructure
  trap as `amazonses.com`.
- See `Anti-Spoofing Header Lockout Resolution` in Mimecast docs if a broad policy locks something out.

### Internal Directories ↔ auto-created policy drift

`Users & Groups → Internal Directories` drives the `Auto Created Anti-Spoofing Policy` set, but
**removing an internal directory does NOT remove its auto-created policy.** TMBC had 8 orphaned
policies for domains that were no longer internal directories (some no longer even registered), plus
3 internal directories with no policy at all. Diff both lists whenever auditing; neither side is
authoritative on its own. Adding a domain auto-creates the policy, so no global catch-all is needed.

## Auditing permitted senders for dead entries — methodology

Learned the hard way on 2026-07-29. **DNS status alone is NOT sufficient to declare a permitted
sender dead.**

A sender can transmit with an envelope domain that does **not resolve publicly**. Real example:
`em7919.themyersbriggs.net` is `NXDOMAIN` on 1.1.1.1 / 8.8.8.8 / 9.9.9.9 with no SPF record, yet it
carried **1,878 messages in 30 days** of live D365 notification mail (outbound via SendGrid,
re-entering inbound). A DNS-only audit would have deleted it and dumped that flow into the held queue.

DNS absence proves **SPF cannot pass**. It does **not** prove mail is not arriving.

Correct order of evidence:
1. **`archive/search` receipt history** (authoritative — is this sender actually in use?)
2. DNS existence + records (can it be used, and can a forged envelope be contradicted?)
3. SPF presence (`v=spf1 -all` with no includes = hard-fenced, not forgeable; `~all` = softfail,
   partly forgeable; shared-platform includes = forgeable by anyone on that platform)

Also note "has A but no MX" is **not** dead — send-only domains legitimately lack MX
(`email.asana.com`, `office.com`, `atlassian.net`, `themyersbriggs.net`).

Watch for **rotated ESP subdomains**: `em366.themyersbriggs.net` (last mail 2021) and
`em7919.themyersbriggs.net` (live) are the same SendGrid flow after a subuser rotation. The dead
predecessor lingers in the group; the live successor must be kept.

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

> **⚠ UNVERIFIED — do not cite this table as fact. Re-read it from the console before acting.**
>
> Transcribed 2026-05-11 (`61c006a`). On 2026-07-29 the row `Eugene Pace` was shown to be
> **fabricated**: Entra holds exactly one Pace (`Elayne Pace`, `epace@`, disabled), and 11 years of
> archive show "Elayne Pace" 56 times and "Eugene Pace" zero times. The name was inferred from the
> `epace@` local part rather than read from the console.
>
> Since one row was invented, none of the rows can be trusted. Impersonation Protection config is
> **not** API-readable, so the console is the only source of truth. Treat the list below as a hint
> about which people are covered, not as the configuration.

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
