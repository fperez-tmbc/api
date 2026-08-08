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

To permit a sender on its **header** address, use a **second group** with its own `Both` policy.
Leave the default alone.

| | Group | Matching | Contents |
|---|---|---|---|
| `Default Permitted Senders Policy` | `Permitted senders` | envelope only | ~400 entries, mostly bare domains |
| header-match policy | a second, small group | `Both` | curated, individually vetted |

`Both` was safe to lose on the default because of *scale*, not because header matching is wrong:
351 bare domains × `Both` lets anyone forge a `From:` on any of them. On a small curated group the
same setting is fine. Sizing is the control, so keep that group short and justify every entry in
`notes`.

**Check DMARC before adding a domain to the header group.** A vendor at `p=reject` cannot have its
header From forged past authentication, which is what makes the entry safe. Verified 2026-08-04 —
all ten TMBC permitted-sender vendors publish `p=reject`: hubspot, salesforce, expensify, adobesign,
adp, docusign, myob, atlassian (.com and .net), fidelity. A vendor at `p=none` belongs in the group
as an **individual address**, not a whole domain.

Scoping it as a group rather than per-sender policies is what stops policy sprawl: adding a vendor
becomes a group edit, and the Gateway Policies list stays readable.

### Reading matching mode off the policy LIST — the inference is ONE-WAY

In the Gateway Policies list, the **From** column wraps the value in square brackets when the policy
is **envelope-only**. That direction is reliable:

```
[ @*.adp.com]                 <- envelope only (P1).  Brackets ALWAYS mean envelope-only.
[ Permitted senders]          <- envelope only (P1) - the Default Permitted Senders Policy
```

**The absence of brackets does NOT mean `Both`.** Header-only also renders without brackets, so an
unbracketed row is either `Both` **or** header-only, and the list view cannot distinguish them. The
only way to tell is to open the policy.

```
@*.myob.com                   <- Both OR header-only - list view cannot tell you which
no-reply@sns.amazonaws.com    <- Both OR header-only
```

Corrected 2026-07-30 by Frank, who confirmed from the policy detail pages that in this tenant every
unbracketed policy is in fact `Both` — but that is a fact about the current config, not something the
notation tells you. Do not report an unbracketed policy as `Both` without opening it.

This still makes the list view useful for auditing: it reliably identifies every envelope-only policy,
which matters because Permitted Senders policy config is **not** readable via the API.

### `message-finder/search` is the ONLY way to read the envelope sender

`archive/search` and `archive/get-message-detail` do **not** expose the envelope. Headers come back
without `Return-Path`, and `fromEnv` / `fromHdr` are always null on the archive detail response.
Use `message-finder/search` instead — it returns both:

```python
body = {"data": [{"searchReason": "permit audit",
                  "start": "2026-07-01T00:00:00Z", "end": "2026-07-31T00:00:00Z",
                  "advancedTrackAndTraceOptions": {"from": "noreply@notifications.hubspot.com"}}],
        "meta": {"pagination": {"pageSize": 200}}}
# -> data[0].trackedEmails[].fromEnv.emailAddress / .fromHdr.emailAddress
```

> ### ⚠ `advancedTrackAndTraceOptions.from` is EXACT-domain. It does not match subdomains.
>
> Searching `from: "hubspot.com"` returns **only** mail whose address is at the bare apex. It will
> not surface `noreply@notifications.hubspot.com`. Verified 2026-08-04:
>
> ```
> from: hubspot.com                                111 msgs
> from: notifications.hubspot.com                2,444 msgs   <- invisible to the query above
> from: notifications.transactional.hubspot.com     16 msgs
> ```
>
> This produced a wrong conclusion the same day: two HubSpot permit policies were assessed as
> "matching nothing" when one of them carries the largest HubSpot flow in the tenant by 20x.
>
> **Never enumerate a vendor's sending domains with this parameter.** It can only confirm a domain
> you already named. To *discover* them, use `archive/search` with `<sent select="from">apex</sent>`
> (which does traverse subdomains) and pull `envelopeFrom` / `from` from
> `archive/get-message-detail` per message. That is the only reliable enumeration, and it is what
> the vendor tables in this file are built from.
>
> Note `<sent>` also conflates envelope and header, so the *detail* call is what separates them.

Validation rules that will bite:
- `messageId` **or** `advancedTrackAndTraceOptions`, never both, and neither may be blank.
- `advancedTrackAndTraceOptions` needs at least one of `from`, `to`, `subject`, `senderIP`, `url`.
  A bare `senderDomain` fails with `err_validation_at_least_one_not_null`.
- `senderAddress` and `recipientAddress` come back null; read `fromEnv` / `fromHdr` instead.

Retention is ~30 days, so this answers "what is the envelope today", not historical questions.

**Why it matters:** envelope and header routinely sit on different domains, and every permit
decision depends on which one you are matching. HubSpot, verified 2026-07-30:

```
fromHdr: noreply@notifications.hubspot.com          stable
fromEnv: 1axb1ik3bj...@notifybf1.na2.hubspot.com    per-message VERP, shared bounce pool
```

2,811 of 2,881 messages had the envelope on `notifybf1.na2.hubspot.com` while every group entry
named the *header* domain — under the envelope-only default policy those permits fired on 70 of
2,881. Do not assume the two addresses share a domain.

### Choosing the matching mode: does the envelope stay in the vendor's own domain tree?

That is the whole test.

| Vendor | Envelope domains | Header From | Setting |
|---|---|---|---|
| ADP | `adp.com`, `emailservice.`, `m1.`, `m2.`, `list.` | `noreply@adp.com` | envelope only |
| Fidelity | `fidelity.com`, `mail.`, `bounce.mail.` | `Fidelity.Alerts@Fidelity.com` | envelope only |
| Adobe Sign | `mail.na1/na4/eu1.adobesign.com` | `adobesign@adobesign.com` | envelope only |
| DocuSign | `docusign.net`, `eumail.docusign.net` | `dse_NA3@docusign.net` | envelope only |
| MYOB | **`mandrillapp.com`** — third party, out of tree | `@apps.myob.com` | **Both** |

In-tree means an `@*.vendor.com` wildcard policy matches the envelope, and the permit fires there —
so the header never needs matching, even when the header From sits at the apex and the envelope at a
subdomain. Pair the wildcard with the **apex as an exact group entry** to cover apex envelopes,
because a wildcard does not match the apex.

Prefer envelope-only whenever the envelope is in-tree: all these vendors publish enforcing DMARC, so
a forged header From fails authentication before any permit is consulted. `Both` buys no coverage and
widens the surface a forged header could exploit.

**Trap:** "envelope-only would match the subdomain but not the apex" sounds like a gap and is not
one. The subdomain *is* the envelope. Matching it is sufficient. This reasoning error produced two
wrongly-configured policies on 2026-07-30.

### Wildcards: policies only, never groups

`@*.domain.com` wildcards work in an **individual policy**. Profile groups are **exact match only** —
a root domain in a group does **not** cover its subdomains, and wildcards cannot be added to a group.

> ### ⚠ `@*.vendor.com` appears to match ONE label only. Prefer a group entry.
>
> Measured 2026-08-04 against the 7,500-message held queue. **Every held envelope belonging to a
> vendor that has a wildcard policy was a multi-label subdomain:**
>
> ```
> 8x  bounces@mail.na4.adobesign.com          <- policy [ @*.adobesign.com ] exists, held daily
> 7x  <verp>.<verp>.<region>.bnc.salesforce.com  <- policy @*.salesforce.com exists, held
> ```
>
> `mail.na4.adobesign.com` was held **8 days running** on an identical daily notification while
> `[ @*.adobesign.com]` was active and enabled. The consistent reading is that `*` substitutes a
> single label: `@*.adobesign.com` covers `na4.adobesign.com` but not `mail.na4.adobesign.com`.
>
> **Group entries, by contrast, have a perfect record: 353 permitted domains against 7,500 held
> messages produced zero collisions.** Exact-match works; the wildcard is the unreliable half.
>
> Not proven from the console (Permitted Senders config is not API-readable), and single-label
> subdomains are too low-volume to test by absence of holds. But the remediation is the same either
> way, so it has not been worth chasing further: **enumerate the subdomains as group entries.**

**Default to group entries, not a wildcard policy.** 159 of the 351 bare-domain entries in
`Permitted senders` are already subdomains (`bounce.zoom.com`, `bounce.1password.com`,
`bounces.rapid7.com`, `alerts.bounces.google.com`, …). That is the house pattern and it is the one
that demonstrably works.

| Envelope situation | Where it goes | New policies |
|---|---|---|
| In vendor's own tree, subdomains enumerable | `Permitted senders` group | **0** |
| Per-message VERP subdomains (unenumerable), in-tree or not | header-match group + one shared policy | **0** after setup |
| On shared third-party infra (`amazonses.com`, `mandrillapp.com`, `sendgrid.net`) | header-match group + one shared policy | **0** after setup |
| Genuinely unpredictable *and* header unusable | `@*.vendor.com` policy, knowing the one-label caveat | 1 per vendor |

Row 4 should be rare. Reach for it last, not first.

**Do not infer subdomain coverage from mail being delivered.** Delivery is the default; a permit only
bypasses spam scanning. Confusing the two produced a wrong conclusion on 2026-07-29.
Equally, **do not infer that a permit fired because a message was not held** — only ~4% of inbound
trips spam signature, so a quiet subdomain proves nothing. Judge coverage from the *held* queue.
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

## Permitting Zoom — the contrasting case (group entry, no policy)

Resolved 2026-08-04. Same symptom as AWS SNS (graymail held), opposite fix, because Zoom keeps its
envelope **in its own tree** while AWS does not.

| Header From | Envelope domain | 30d | Held |
|---|---|---|---|
| `no-reply@zoom.us` | `bounce-sg.zoom.us` | 131 | 5 |
| `customer-success-advisor@zoom.us` | `gshemail.zoom.us` | 15 | **6** |
| `noreply-marketplace@zoom.us` | `bounce-sg.zoom.us` | 3 | 0 |
| `teamzoom@zoom.com` | `bounce.zoom.com` | 4 | 0 |

`zoom.us` was already a group entry, but groups are exact-match and the default policy is
envelope-only, so it never fired — the envelope is always on a subdomain. `bounce.zoom.com` is the
control: it *is* an exact group entry, and it has held nothing.

**Fix: two group entries, `bounce-sg.zoom.us` and `gshemail.zoom.us`. No policy.** Leave `zoom.us`,
`zoom.com`, `bounce.zoom.com` alone.

Two things worth carrying forward:

- **`no-reply@zoom.us` is actively forged at the envelope.** 61 messages in 3 weeks, all rejected on
  `IP Found in RBL`, all aimed at opp.com / opp.co.uk (`108.165.185.37` ×44, `183.237.228.212` ×17).
  The apex group entry permits that envelope; RBL is what is catching them, not the permit layer.
  Subdomain entries do not widen this, but do not add anything that loosens the apex.
- **The two Zoom subdomains are not equally tight**, which is the same distinction as the SendGrid
  `em*` case:
  ```
  gshemail.zoom.us    v=spf1 ip4:168.245.42.152 -all      one dedicated IP, hard fail
  bounce-sg.zoom.us   v=spf1 include:sendgrid.net ~all    SendGrid's shared /17, softfail
  ```
  Permitting `bounce-sg.zoom.us` means any SendGrid tenant who forges that MAIL FROM gets a
  spam-scanning bypass with an arbitrary header From. Narrower than the `amazonses.com` trap (one
  vendor subdomain, not a shared apex) and accepted here, but it is the reason to prefer the
  dedicated-IP subdomain when a vendor offers both.

## Graymail holds — a separate lever from Permitted Senders

`Administration → Gateway → Policies` → `Relaxed - Ignore Graymail`
(Message Scan Definition `Relaxed - Ignore Graymail`, group `Ignore Graymail - Company`).

> ### ⚠ A PERMIT is what stops these holds. Graymail status is a red herring.
>
> Measured 2026-08-04 against a 90-message random sample of the held queue, plus the full queue:
>
> ```
> permittedSender.info on HELD messages:  none 88,  ignored 2,  whitelist 0
> greyEmail            on HELD messages:  False 73, True 17
> ```
>
> **`whitelist` never appears in the held queue.** A permitted sender is not held, full stop. And
> graymail status does not predict a hold in either direction: 17 of 90 held messages *are* graymail,
> and they were held because they had no permit.
>
> Control case, `hr.sage@themyersbriggs.co`:
> ```
> status=archived  detectionLevel=""  greyEmail=True  permittedSender=whitelist
> ```
> It is graymail, it is delivered, and it carries a permit from the `themyersbriggs.co` entry in
> `Permitted senders`. **Its `Ignore Graymail - Company` membership is very likely redundant** — the
> permit already explains the delivery, and no permitted sender is held regardless of graymail status.
>
> An earlier revision of this file drew the opposite conclusion from hr.sage ("a permit does not stop
> a graymail hold, hr.sage still needed a graymail entry"). That was an inference from the fact that
> both were present, never tested. It was wrong. **Do not send a held-mail problem to the graymail
> group because `spamScore` is 0** — check `permittedSender.info` first, and if it reads `none`, the
> missing permit is the problem.

| | `Default Permitted Senders` | `Relaxed - Ignore Graymail` |
|---|---|---|
| Group size | ~400 entries | 4 entries |
| Effect of a match | bypass spam scanning | scan with graymail detection off |
| Effect of a false match | spam reaches the inbox | graymail reaches the inbox, still spam-scanned |

- **`Addresses Based On` is `The Return Address` and the field is NOT editable.** So this group matches
  the **envelope only**, and a header address added to it will never fire. Same trap as the default
  Permitted Senders policy, with no option to flip it to `Both`.
- `Applies To = Internal Addresses`, Policy Override unchecked, Source IP Ranges empty.
- `greyEmail` in `message-finder/get-message-info` → `spamProcessingDetail` is a **working field**, not
  a broken one: it reads `True` on 17 of 90 sampled held messages and on `hr.sage`. So when it read
  `false` on all 41 held `themyersbriggs.co` HubSpot messages, that was the truth — those are not
  graymail, and a graymail exemption would not have released them.

### HubSpot sending domains: `bfNN.<region>` are SHARED pools, and the lookalikes bite

TMBC marketing goes out through HubSpot portal `243772180` and re-enters inbound. The envelope is
HubSpot's, the header is ours, so only the envelope side can be matched here:

```
header    peoplefirst@themyersbriggs.co
envelope  1axb4nl...@bf10.na2.hubspotemail.net
```

Measured 2026-08-04 against the held queue. **The `.na2.` segment is the region, not a customer
marker** — sibling pools carry no TMBC mail at all:

```
held  envelope domain                      TMBC  other
  33  bf10.na2.hubspotemail.net              30      3    <- ours
  11  transactional.na2.hubspotemail.net     11      0    <- ours, 130/130 over 12mo
  16  bf05.na2.hubspotemail.net               0     16
  12  bf07.na2.hubspotemail.net               0     12
  10  bf01.na2.hubspotemail.net               0     10
  20  bf10x.hubspotemail.net                  0     20    <- LOOKALIKE, not ours
```

`bf10x.hubspotemail.net` is one character from `bf10.na2.hubspotemail.net` and shares none of our mail.

**Why permitting a shared HubSpot pool is acceptable here (and permitting `amazonses.com` is not):**
HubSpot enforces DNS-based domain verification before a customer may put their own domain in the
header From. Per HubSpot: *"you cannot send emails with your domain in the From address
(e.g. user@company.com) until you connect that domain to HubSpot by setting up DKIM."* Unverified
senders get their From rewritten to a HubSpot-owned domain. Confirmed on all three third-party
senders observed on `bf10.na2`:

```
mail.theswensongroup.com   dkim=pass d=mail.theswensongroup.com s=hs1-21634638   dmarc=pass p=quarantine
clarus.com                 dkim=pass d=clarus.com               s=hs2            dmarc=pass p=reject
preferredcfo.com           dkim=pass d=preferredcfo.com          s=hs2-3018756    dmarc=pass p=quarantine
```

Portal-numbered selectors (`hs1-21634638`, `hs2-3018756`, ours is `hs2-243772180`) are the tell that
DNS control was proven. `amazonses.com` has no equivalent gate, which is why that one stays banned.

So the co-tenants on a HubSpot pool are domain-verified senders, not anonymous ones. Frank accepted
the residual on that basis, 2026-08-04.

**Durable fix, not yet done:** HubSpot supports a custom return-path so the envelope lands on our own
domain. Configured for portal 243772180, the envelope becomes `<x>.themyersbriggs.co` and the
shared-pool exposure disappears. That is exactly what `em3639`/`em7919.themyersbriggs.net` already are
for SendGrid, which is why those two sit in this group cleanly.

## Reading envelope vs header for a message

`message-finder/search` returns `fromEnv` and `fromHdr` per message:

```zsh
curl -s -X POST "https://us-api.services.mimecast.com/api/message-finder/search" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"data":[{"start":"2026-07-01T00:00:00+0000","end":"2026-07-30T00:00:00+0000",
       "advancedTrackAndTraceOptions":{"from":"no-reply@sns.amazonaws.com","route":"inbound"}}]}'
```

- **Start date has a ~30 day cap, and it is strict to the day.** Older values fail with
  `err_track_and_trace_invalid_start_date` and an empty `data` array (`meta.status` is still 200 —
  always check `fail[]`). Verified 2026-07-31: a `start` of exactly 30 days back still failed;
  back off a few days rather than probing one day at a time.
- **`senderIP` is a first-class search key and is the way to attribute mail to a sending host.**
  `advancedTrackAndTraceOptions: {"senderIP": "203.0.113.10"}` alone is a valid query and returns
  `fromEnv`, `fromHdr`, `to`, `route`, `subject`, `status` per message. This is how you answer
  "what is this IP in our SPF record actually sending" — see the worked example below.
- `message-finder/get-message-info` (pass the `id` from search) is **less useful than it looks**.
  Verified 2026-07-31 on an inbound archived message: `fromEnvelope` and `fromHeader` both came
  back `null`, and the response carried only
  `['deliveredMessage','id','recipientInfo','retentionInfo','spamInfo','status']` — no `spamEvent`,
  no `receiptEvent`, no `policyInfo`. Do not rely on it for the envelope pair or for which policies
  fired; take the envelope from `message-finder/search` (`fromEnv`) and the authentication verdict
  from `archive/get-message-detail` headers instead.
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

### Full headers — `archive/get-message-detail` (the DKIM/SPF/DMARC answer)

**This is the only way to read a message's actual authentication result.** It returns the full
header set, including `Authentication-Results` and the complete `Received` chain, plus
`envelopeFrom` — which `archive/search` does not expose.

The payload is fussy and fails in misleading ways. Verified 2026-07-31:

```python
# WORKS — the bare form. Defaults to context DELIVERED and returns everything.
call("/api/archive/get-message-detail", {"data": [{"id": ARCHIVE_ID, "admin": True}]})
```

| Payload | Result |
|---|---|
| `{"id": <id>, "admin": true}` | **works** — full headers, `envelopeFrom`, `from`, `replyTo`, `messageBodyPreview` |
| `{"id": <id>, "context": "archive", ...}` | `err_validation_value_not_allowed` — *"Field must be one of [DELIVERED,RECEIVED]"*. `"archive"` is the value `archive/search` uses; it is **not** valid here |
| `{"id": <smash>, "admin": true}` | `xdk_failure 0007 Invalid token` — the `smash` hash is **not** interchangeable with `id` |
| `wantHeaders: true` | not required; ignored |

Empty `data: []` with `meta.status: 200` means the payload was rejected — **always read `fail[]`**,
which carries the real error. An empty result here is never "no such message".

Response shape:

```python
rec = det["data"][0]
rec["envelopeFrom"]["emailAddress"]   # P1 / return-path
rec["from"]["emailAddress"]           # P2 / header From
rec["headers"]                        # list of {"name": ..., "values": [...]}
rec["messageBodyPreview"]
```

Headers arrive as a list of dicts with `values` as a **list**, so join before regexing.

**Worked example — attributing an SPF `ip4:` entry to a real application (2026-07-31).**
Question: is `202.44.98.236` in `themyersbriggs.net`'s SPF still sending? Method:

1. `message-finder/search` with `advancedTrackAndTraceOptions: {"senderIP": "202.44.98.236"}`
   → 26 messages, `route: inbound`, `no-reply@themyersbriggs.net` → `accounts.ap@themyersbriggs.com`,
   subjects `Invoice Payment Notification - NNNN`.
2. `archive/search` on `<sent select="from">` + `<sent select="to">` to get the archive `id`.
3. `archive/get-message-detail` → headers:

```
Authentication-Results: relay.mimecast.com;
  dkim=none;
  dmarc=pass (policy=quarantine) header.from=themyersbriggs.net;
  spf=pass (... designates 202.44.98.236 as permitted sender)
Received: from bp-dvmh-smtpr-02.inf.bulletproof.net (202.44.98.236) by relay.mimecast.com
Received: from ap.themyersbriggs.com (10.30.15.1) by bp-dvmh-smtpr-02 (Postfix)
Received: from cpp-dvmh-web-03 ([127.0.0.1]) by ap.themyersbriggs.com with Microsoft SMTPSVC
```

The `Received` chain is what identifies the originating app. `dkim=none` plus a `dmarc=pass` that
rests only on SPF is the signature of a sender that will break on any forward — worth flagging
whenever you see it, since it fails intermittently and per-recipient.

### Full message bodies and attachments — `archive/get-file`

**`messageBodyPreview` is hard-capped at 100 characters.** It is a list-view teaser, not the body.
Verified 2026-08-03 across 12 messages: every one returned exactly 100 chars, whether the message was
21 KB or 1.4 MB. There is no `wantBody` flag and no other body field on the detail response, so
`get-message-detail` alone can never answer "what did this email say".

**`archive/get-file` is the answer, and it accepts either an attachment id or a message id:**

| `data[0].id` | What you get |
|---|---|
| an `attachments[].id` from `get-message-detail` | that attachment's bytes |
| the **message** `id` (the same one `get-message-detail` takes) | the complete **`.eml`** — all headers, all MIME parts |

The message-id form is the only way to read a full body; parse the result with Python's `email` module.
Unlike `get-message-detail`, the `smash` hash is still not interchangeable with `id`.

**It returns JSON containing short-lived pre-signed URLs, NOT the file bytes.** Always two steps:

```python
r = call("/api/archive/get-file", {"data": [{"id": file_or_message_id}]})
url = r["data"][0]["urls"][0]        # us-a1.download.api.services.mimecast.com
blob = urllib.request.urlopen(url).read()
```

The URL carries its own credentials in a `context` blob, so do **not** send the bearer token on the
download GET. `admin: true` is accepted but not required. If you write the JSON response straight to
disk you get a ~3.7 KB file starting `{"meta":` instead of the PDF you expected.

### `attachmentcount` undercounts — enumerate `get-message-detail` instead

The `archive/search` return-field `attachmentcount` counts only conventional attachments and skips
inline / `cid:` parts. Verified 2026-08-03 on a 12-message vendor thread: search reported 12
attachments in total, `get-message-detail` listed 21. One 1 MB message reported `attachmentcount=0`
while carrying four inline PNGs. **Never conclude "no attachments" from a search row** — read
`get-message-detail` → `attachments[]`, which carries `filename`, `size`, `extension`, `contentId`,
`contentType`, `bodyType` and `sha256`.

Use `sha256` to collapse a thread before downloading. Quoted signature images reappear on every reply
with a different `id` and sometimes a different filename but an identical hash — in that thread the
same Crayon banner appeared 10 times under 3 filenames, and 21 attachment slots held only 7 unique
files.

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

> ### ⚠ An `Anti-Spoofing SPF Bypass` policy is a CONSUMER of your SPF record
>
> **Before removing ANY mechanism from an SPF record, check the SPF-bypass policies.** These policies
> resolve the SPF record of a *configured domain* and ask "is the connecting IP in it". That is a
> completely separate evaluation from normal SPF authentication, which runs on the **envelope**
> domain. A mechanism can be provably unused for mail authentication and still be load-bearing here.
>
> **Outage, 2026-07-31.** `include:sendgrid.net` was removed from `themyersbriggs.net`'s apex SPF
> after verifying no mail used the bare apex as an envelope — correct, and irrelevant. The
> `Anti-Spoofing SPF Bypass` policy listed only `themyersbriggs.net`, and the SendGrid sending IP
> `168.245.48.216` matched it *solely* via that include (`sendgrid.net` → `168.245.0.0/17`). Removing
> it silently un-exempted the flow:
>
> ```
> 03:54:22 UTC  include:sendgrid.net removed from apex SPF
> 04:00:07 UTC  first rejection, SIX MINUTES later
>               -> "Anti-Spoofing Header Lockout", "Rejected prior to DATA acceptance"
> 14:16:11 UTC  last rejection
>
> 81 messages rejected: 52 via em3639, 24 via em7919, 5 with a bare sendgrid.net envelope.
> Invoices, Elevate licence-expiry (EN/FR/NL), Salesforce summaries, JIT errors, sales-order reviews.
> All recipients internal, so customer-bound copies (which never traverse Mimecast) were unaffected.
> ```
>
> **Scope this with `senderIP`, not sender addresses.** A first pass searching two known `from`
> addresses found 26 of 81, missed `em7919` completely, and mis-dated the first rejection by four
> hours. One `advancedTrackAndTraceOptions: {"senderIP": "..."}` query catches every whitelabel and
> every sender behind that IP.
>
> **The misleading part:** `get-message-info` → `spamProcessingDetail` showed `spf: {allow: true}`,
> because normal SPF *did* pass on the envelope `em3639.themyersbriggs.net`, which has its own
> record. That passing result was wrongly read as exonerating the DNS change. **The SPF result in
> `spamProcessingDetail` tells you nothing about whether a bypass policy matched.**
>
> **Fix — keep the bypass on the apex, and fix what the apex resolves to.** The bypass policy points
> at `themyersbriggs.net` only, which is how every other TMBC domain's bypass is configured. What
> changed is the apex SPF: it now carries `include:em3639.themyersbriggs.net` and
> `include:em7919.themyersbriggs.net` in place of `include:sendgrid.net`. Those publish
> `v=spf1 ip4:168.245.48.216 -all`, so the bypass resolves to **one dedicated IP** instead of
> SendGrid's shared `/17` (~32,768 addresses of other customers' space).
>
> Two properties this buys:
>
> - **Config consistency.** No per-domain special-casing in the policy layer. Every bypass policy has
>   the same shape, so nobody has to remember which domains got whitelabel entries.
> - **The load-bearing mechanism is self-documenting.** `include:sendgrid.net` looked exactly like
>   removable vendor cruft with no observed traffic, which is why it got removed.
>   `include:em3639.themyersbriggs.net` names the specific thing that needs it, in your own namespace.
>
> **This is NOT a general "always fix it in DNS" rule — it is conditional on scope.** Frank,
> 2026-07-31: *"The reason that I am okay with including the SendGrid em* domains in the SPF record is
> because they are scoped down to 1 IP address that's assigned to us. If it were broader, then I would
> have kept it inside the bypass policy."*
>
> | Include resolves to | Put it in |
> |---|---|
> | a narrow set of IPs **assigned to us** (`em3639` -> one dedicated IP) | the **apex SPF** |
> | a vendor's **shared/broad** space (`sendgrid.net` -> 237,056 addresses) | the **bypass policy** |
>
> The apex SPF is a public statement about who may send as the bare domain. Widening it to a vendor's
> shared range just to satisfy an anti-spoofing policy is the wrong trade — scope the policy instead.
>
> Belt and braces: the SPF TXT record carries a Cloudflare comment, *"Mimecast Anti-Spoofing SPF
> Bypass resolves this record. Do NOT remove the em* includes."* — visible in the dashboard where the
> edit actually happens. Comment limit is low: 87 chars took, ~230 returned HTTP 400.
>
> Both arrangements verified by test send along the identical path (same header From, same `em3639`
> envelope, same source IP): `status: accepted` where it had been `rejected`.
>
> Anti-spoofing config is **console-only**, not API-readable, so no API-side verification will ever
> surface this dependency. It has to be checked by hand in
> `Administration → Gateway → Policies → Anti-Spoofing SPF Bypass`.

- **Anti-Spoofing OVERRIDES Permitted Senders.** Per Mimecast, a message from a Permitted Sender is
  still rejected if detected as spoofing. So an anti-spoofing policy outranks the whole permit layer.
  Never assume a permit entry protects a flow from anti-spoofing. Seen live 2026-07-31: the rejected
  invoices showed `permittedSender: {allow: true, info: "whitelist"}` and were rejected anyway.
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

## Synchronisation Engine (MSE) — Exchange tasks

Console path: `Governance & Compliance → Archive` → the **Governance, Compliance & Insights (GCI)**
page → **Exchange Services** (under *Administration*; *"Manage folder replication, calendar
synchronization, and mailbox management features"*). The MSE instances themselves are
**Synchronization Engine Sites** on that same page. The in-page breadcrumb reads
`Archive > Exchange Services`, which is not a navigable path on its own.

TMBC runs **one** MSE site, **SVAZADSYNCDC01**
(10.70.16.41 — the AAD Connect box), engine **4.5.0.525**, service `msesrv` as
`NT AUTHORITY\NetworkService`. Three tasks, each on its own daily schedule (the CAL one is
`TheMBC Daily Sync Schedule 08:00`), all scoped to the **same distribution list**:

| Task | Code | Name | Fires |
|---|---|---|---|
| 11359 | `MMS` | TheMBC Folder Replication | 00:00 |
| 11360 | `CAL` | TheMBC Calendar Sync | 08:00 |
| 11361 | `MDS` | TheMBC Mailbox Permission Sync | 16:00 |

**MSE task and definition config is NOT API-readable** — console only, same as Permitted Senders.
The engine's own logs on the host are the only real diagnostic surface; see
`reference-svazadsyncdc01` memory for the log paths, the `DDMMYYYY` timestamp format, and the
`ProgramData\Mimecast Synchronisation Engine\Logs\CUSA34A243\` per-task log.

> ### ⚠ "contains no mailboxes" means the DL never RESOLVED. The group is not empty.
>
> ```
> Task wasn't started because CN=<guid>,DC=myersbriggsco,DC=onmicrosoft,DC=com contains no mailboxes
> ```
>
> Diagnosed 2026-08-06. The message is a prerequisite-check failure, and the wording sends you off
> to audit group membership, which is a dead end. The MSE log shows what actually happens:
>
> ```
> DirectoryDistributionListResolver | Resolving name with Office 365
> PowershellController          | getting recipient <guid>@myersbriggsco.onmicrosoft.com
> WARN PowershellController     | recipient with identifier <guid>@myersbriggsco.onmicrosoft.com not found
> DirectoryDistributionListResolver | was not resolved
> WARN AbstractModularExecutor  | prerequisite check failed: ... contains no mailboxes
> ```
>
> MSE takes the stored DN, sees an `onmicrosoft.com` suffix, picks its **Office 365** resolver, and
> joins `CN` + `DC` parts into a recipient identity — `<guid>@myersbriggsco.onmicrosoft.com`. EXO
> `Get-Recipient` cannot resolve that: it parses as an SMTP address and is not one of the group's
> `proxyAddresses`. Zero mailboxes resolved → "contains no mailboxes".
>
> **The real cause is WHICH directory tree the group was picked from.** Mimecast Directory Sync
> holds two copies of every synced group, and their DNs are shaped differently:
>
> | Mimecast tree | DN shape | MSE resolver |
> |---|---|---|
> | `myersbriggsco.onmicrosoft.com` (Azure AD / O365 connector) | `CN=<Entra objectId>,DC=myersbriggsco,DC=onmicrosoft,DC=com` | Office 365 → **fails**, CN is a GUID |
> | `cpp-db.com → TheMBC → Groups → Distribution` (on-prem AD connector) | `CN=DL Workforce,…,DC=cpp-db,DC=com` | CN is the real group name |
>
> ### ⚠ NEITHER TREE WORKS on an O365-bound site. Tested 2026-08-06→08, both fail.
>
> All three tasks were re-created against the **on-prem AD** copy. They still fail, and the log
> shows the resolver does something different with that DN shape:
>
> ```
> getting recipient CN=DL Workforce,OU=Distribution,OU=Groups,OU=TheMBC,DC=cpp-db,DC=com
> was not resolved
> ```
>
> **MSE passes the whole DN verbatim when the DN contains OU components, and only does the
> CN + DC → SMTP conversion when it does not.** That is why the two shapes fail differently:
>
> | Source tree | DN | Identity MSE sends to `Get-Recipient` | Why it fails |
> |---|---|---|---|
> | Azure AD | `CN=<objectId>,DC=myersbriggsco,DC=onmicrosoft,DC=com` | `<objectId>@myersbriggsco.onmicrosoft.com` | composed address; not one of the group's proxy addresses |
> | on-prem AD | `CN=DL Workforce,OU=Distribution,OU=Groups,OU=TheMBC,DC=cpp-db,DC=com` | the raw DN, unchanged | EXO resolves the *cloud* DN (`…,OU=Microsoft Exchange Hosted Organizations,DC=…PROD.OUTLOOK.COM`), not an on-prem one |
>
> So on a site bound `host: O365`, the picker offers no group whose DN the Office 365 resolver can
> consume. **This is not fixable from the console** — it needs Mimecast.
>
> Verified across six scheduled runs 2026-08-06 16:00 → 2026-08-08 08:00, all three task types.
>
> **Proven against Exchange Online 2026-08-08** (app-only, module pinned to 3.9.2). The two
> identities MSE actually sends are precisely the two that fail; everything else about the group is
> fine:
>
> ```
> NOT FOUND | CN=DL Workforce,OU=Distribution,OU=Groups,OU=TheMBC,DC=cpp-db,DC=com
> NOT FOUND | 1d7f28c3-5260-4470-81e3-49f9c1bc1320@myersbriggsco.onmicrosoft.com
> RESOLVED  | 1d7f28c3-5260-4470-81e3-49f9c1bc1320          <- bare GUID, no domain
> RESOLVED  | DLWorkforce@themyersbriggs.com
> RESOLVED  | DL Workforce
> RESOLVED  | CN=DL CPP Workforce,OU=myersbriggsco.onmicrosoft.com,OU=Microsoft Exchange
>             Hosted Organizations,DC=NAMPR08A005,DC=PROD,DC=OUTLOOK,DC=COM
> ```
>
> **MSE holds the correct identifier and ruins it by appending a domain.** That GUID is the group's
> `ExternalDirectoryObjectId` in Exchange Online — passed alone it resolves instantly; composed as
> `<guid>@<tenant>.onmicrosoft.com` it is an address no object owns. Note EXO knows the group as
> **`DL CPP Workforce`**, not `DL Workforce`; the two directories are not interchangeable.
>
> There is no third DN shape to try. Mimecast's directory holds exactly two trees — `cpp-db <- com`
> (1159 folders) and `onmicrosoft <- com` (1092) — and exactly two copies of the group, both tested.
>
> **Prerequisites verified met — the failure is not permissions.** Mimecast document MSE against
> Office 365 as a supported configuration requiring a mailbox-enabled service account with access to
> the target mailboxes. `svcmimecasteo` is a `UserMailbox` and holds `Mail Recipients` (which is what
> grants `Get-Recipient`), `Mail Recipient Creation`, `ApplicationImpersonation` ×3 and
> `Application EWS.AccessAsApp`. Impersonation is why there are no per-mailbox Full Access entries.
> Their own bind-time `ExchangeAccessValidator.ValidatePowershellConnection` probe also passes.
>
> **Worth ruling out explicitly:** if the resolver's account could not see recipients at all, every
> identity would return not-found and the "wrong identity string" reading would be wrong. It can see
> them, so that explanation is eliminated. Note the EXO tests above were run as `claude-m365`, not as
> `svcmimecasteo` — they prove the identities resolve, not that MSE's account can resolve them; the
> RBAC check is what closes that gap.
>
> ⚠ **The "Mimecast defect" characterisation is an inference from behaviour, NOT confirmed against
> their documentation.** Every Mimecast KB page 403s to WebFetch and to curl with a browser UA, so
> only search-result summaries have been read, never the article text. Reportable claim, still to be
> checked against the docs: *the Office 365 DL resolver composes `<CN>@<DC parts>`; Exchange Online
> resolves the bare CN (it is the ExternalDirectoryObjectId) but not the composed address.*
> One lead not yet run down: a search summary of the MSE Troubleshooting Guide attributes "no
> mailboxes" to a *binding* issue fixed by running MSE on Windows Server 2022+. This host is Server
> 2025, so that remedy cannot apply, but the underlying passage has never been read.
>
> **Verify the group before believing the error.** `directory/find-groups` + `get-group-members`
> showed `DL Workforce` populated in *both* trees (129 and 128 flattened members, 86–87 users plus
> 42 nested DLs, all `internal: true`). Entra shows only **4 direct** members — a nested group plus
> three users — because Mimecast's sync flattens nesting and Graph does not. A "4 members" reading
> from Graph is not evidence of an empty group.
>
> To tell which tree a group came from, walk `parentId` up the `find-groups` result:
> ```python
> byid = {f['id']: f for f in folders}          # page fully: pageSize 500 + follow meta.pagination.next
> # DL Workforce <- myersbriggsco <- onmicrosoft <- com          => Azure AD connector
> # DL Workforce <- Distribution <- Groups <- TheMBC <- cpp-db <- com  => on-prem AD connector
> ```
>
> The Mimecast **audit log carries no MSE task/definition events** (66 days checked, only Directory
> Sync / policy / logon types), so it cannot date when a task was re-pointed.

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
