# Cloudflare API — Notes

Field notes from hands-on work against the Cloudflare API.

## Access Methods

Two ways to interact with Cloudflare — use whichever fits the task:

| Task | Use |
|------|-----|
| DNS record create/update/delete | REST API (token auth) |
| List Workers, get Worker code | MCP (faster, no auth setup) |
| Cloudflare docs lookup | MCP `search_cloudflare_documentation` |
| D1, KV, R2, Hyperdrive inspection | MCP |
| Scripted/automated operations | REST API |

### MCP (Cloudflare Developer Platform)
Available as `mcp__claude_ai_Cloudflare_Developer_Platform__*` tools in claude.ai sessions. No token needed — authenticated via the claude.ai integration. Use `set_active_account` first if multiple accounts are in scope.

Key tools: `workers_list`, `workers_get_worker`, `workers_get_worker_code`, `search_cloudflare_documentation`, `kv_namespaces_list`, `d1_databases_list`, `r2_buckets_list`.

### REST API
- Bearer token: `Authorization: Bearer <TOKEN>` on all requests
- Token stored at `~/GitHub/.tokens/cloudflare`
- Verify token: `GET https://api.cloudflare.com/client/v4/user/tokens/verify`

## Key Concepts
- Resources are scoped to either **account** or **zone** — know which you need before calling
- Multiple accounts may be returned from `GET /accounts`; always check which account owns the resource
- Workers live under **accounts**; DNS records live under **zones** — different base paths

## Useful Endpoints

| Resource | Method | Path |
|---|---|---|
| Verify token | GET | `/client/v4/user/tokens/verify` |
| List accounts | GET | `/client/v4/accounts` |
| List zones | GET | `/client/v4/zones?name=example.com` |
| List Workers | GET | `/client/v4/accounts/{account_id}/workers/scripts` |
| Worker routes | GET | `/client/v4/accounts/{account_id}/workers/scripts/{name}/routes` |
| Worker custom domains | GET | `/client/v4/accounts/{account_id}/workers/scripts/{name}/domains` |
| List DNS records | GET | `/client/v4/zones/{zone_id}/dns_records` |
| Create DNS record | POST | `/client/v4/zones/{zone_id}/dns_records` |
| Delete DNS record | DELETE | `/client/v4/zones/{zone_id}/dns_records/{record_id}` |

## DNS Record Create/Delete
```python
TOKEN = open("~/GitHub/.tokens/cloudflare").read().strip()
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

# Create
requests.post(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
    headers=HEADERS,
    json={"type": "TXT", "name": "test.example.com", "content": "value", "ttl": 60})

# Delete
requests.delete(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
    headers=HEADERS)
```

## DNS Analytics — who is actually querying a record

Answers "is this record still being used" without touching mail logs. A query for
`s1._domainkey.example.com` only happens when a receiver validates a DKIM signature with `s=s1`;
a query for a whitelabel envelope domain only happens when a receiver evaluates SPF on it.

Use the **GraphQL** API (`POST /client/v4/graphql`), not the legacy REST endpoint:

```graphql
query($zone:String!,$since:Time!,$until:Time!){viewer{zones(filter:{zoneTag:$zone}){
  dnsAnalyticsAdaptiveGroups(limit:2000,
    filter:{datetime_geq:$since,datetime_leq:$until}, orderBy:[count_DESC]){
      count dimensions{ queryName queryType responseCode datetimeHour }}}}}
```

**Token scope:** needs **Zone → Analytics → Read** (`com.cloudflare.api.account.zone.analytics.read`).
Without it GraphQL returns an `authz` error naming the permission, and legacy REST returns a bare
`10000 Authentication error`. A DNS-edit token does **not** include it. Editing an existing token's
permissions does not change the token secret — no need to update `~/GitHub/.tokens/cloudflare`.

Verified on a **Free** zone, 2026-07-31:

| Behaviour | Detail |
|---|---|
| Max window | **1 week.** Wider requests fail: *"cannot request a time range wider than 1w"* |
| Legacy REST | `/dns_analytics/report` caps at **6h** on Free (`1034`), and is best avoided |
| Counts | **Sampled, and the quantisation itself varies between queries.** Observed multiples of **10** on one pull and multiples of **1,000** on another over the same 7-day window. Presence is reliable, magnitude is not — never cite these as exact volumes |
| Ingestion lag | ~90 seconds |

**A small non-zero value can be reported as 0.** On a coarse pull, `em7919` showed
`NOERROR 0 / NXDOMAIN 7,000` when a finer pull minutes earlier over the same window had shown
`NOERROR 80 / NXDOMAIN 3,240`. The 80 real lookups — the evidence that a DNS fix had taken
effect — rounded away entirely. **A zero here does not prove absence.** If a small count
matters, re-run with a narrower window and a smaller `limit` to get finer granularity, and
prefer "absent from the result set" over "reported as 0" as your absence signal.

**NXDOMAIN queries ARE logged, so deleting a record does not blind you.** This is the key property:
analytics is query-driven, not record-driven, and `responseCode` is a dimension. Proven three ways
on one zone — a name that never existed logged 57,100 NXDOMAIN/week; a deliberately random name
queried 61 times appeared ~90s later as NXDOMAIN; and a record created mid-window showed **both**
NXDOMAIN (before) and NOERROR (after) under the same `queryName`. So you can remove a record and
keep watching whether anything still asks for it, which is strictly better signal than leaving it
published — every subsequent query is then a known-failed lookup.

Interpretation traps:
- **An "empty non-terminal" answers NOERROR, not NXDOMAIN.** `_domainkey.example.com` with
  `s1._domainkey` beneath it exists in the DNS tree with no records of its own. Do not cite such a
  name as evidence that non-existent names get logged.
- **Absent from the result set ≠ zero.** Given sampling, a genuinely tiny trickle can fail to appear
  at all. Distinguish "never queried" from "low volume" carefully.
- **Selector probing inflates common names.** `s1`, `s2`, `selector1`, `default` and bare
  `_domainkey` attract constant internet-wide scanning, so non-zero volume on them is not evidence
  of live mail. Compare against an unusually-named sibling (e.g. SendGrid's `snd2`) which scanners
  never guess and which sat at exactly 0. Mail-driven lookups also show a business-hours curve;
  scanning is flat.

## ⚠ Before editing an SPF record — check its non-mail consumers

**"No mail depends on this mechanism" does not mean "nothing depends on this mechanism."** An SPF
record can be dereferenced by things that are not receiving mail servers, and those consumers are
invisible to DMARC-report or mail-log analysis.

Known consumer at TMBC: **Mimecast `Anti-Spoofing SPF Bypass` policies**. They resolve the SPF record
of a configured domain and exempt connections whose IP is in it. Removing `include:sendgrid.net` from
`themyersbriggs.net` on 2026-07-31 was verified safe for mail authentication — and rejected **81
messages** starting **six minutes later**, because the bypass policy matched the SendGrid IP only
through that include. Resolved by putting `include:em3639.themyersbriggs.net` /
`include:em7919.themyersbriggs.net` in the apex instead, which keeps the bypass policy on the apex
(consistent with every other domain) while narrowing what it resolves to from 237,056 addresses to 1.
Full write-up in `../mimecast/README.md` under Anti-Spoofing.

Checklist before removing an SPF mechanism:

1. Which envelope domains actually use it? (`api/dmarc/analyze-reports.py`, single-`<spf>` records)
2. Do the sending subdomains publish their **own** SPF? If so the apex is not in their path — but
   that also means the apex may exist for something else entirely. Ask what.
3. **Mimecast Anti-Spoofing SPF Bypass policy list** — console only, not API-readable.
4. Anything else that resolves the record by name: monitoring, allow-lists, partner configs.
5. Prefer **narrowing to the specific whitelabel domain** over deleting. For a mail vendor, replace
   `include:vendor.com` with `include:<your-whitelabel>.<your-domain>` — you inherit the vendor's own
   record scoped to your account (often a single dedicated IP) instead of their whole shared space,
   and the mechanism stops looking like removable cruft.
6. **Only put it in the apex if it resolves narrowly to IPs assigned to us.** If the include pulls in a
   vendor's shared space, keep the dependency in the Mimecast bypass policy instead — the apex SPF is a
   public statement about who may send as the bare domain, and should not be widened to a vendor's whole
   range to satisfy an anti-spoofing policy. **Narrow -> DNS; broad -> policy.**
7. Add a **record comment** naming the dependency — the only warning visible at the point of edit.
   Keep it short: 87 chars took, ~230 returned HTTP 400.

## ⚠ Reading DNS answers — four traps that produce confident wrong conclusions

Every DNS error in the 2026-07-31 → 08-10 email-authentication audit came from **misreading an
answer**, not from a failed call. `dig` is not a source of truth about a zone. The zone dump is.

### 1. Wildcard occlusion — a wildcard stops covering a name the moment that name exists

**RFC 4592: a wildcard is consulted only for names that do not exist.** Any RRset at a name — of
*any* type — makes that name exist and ends wildcard coverage for it, for **every** record type,
permanently.

`*.themyersbriggs.co` publishes `v=spf1 -all` (`c74667d64ff0604ee2b8c2853e44f093`). But
`notifications.themyersbriggs.co` carries Mimecast **MX** records, which make the name exist — so
the wildcard SPF was never consulted for it. That subdomain had **no SPF at all** and was
spoofable, while reading as "inherits the wildcard" to everyone who looked. Fixed 2026-07-31 with an
explicit `v=spf1 -all` (`40ee6e96c6d6c8b8cc006f1950714a61`). Same fix for `assessment.opp.co.uk`
(`03cfd5324ae096dcc4da150d58436136`), which had no wildcard to inherit in the first place.

Worth remembering on its own: **adding an MX record to a subdomain silently removes its wildcard
SPF.** Routine action, non-obvious security consequence, no warning from any tool.

### 2. The inverse — an answer that is present but synthesized

Under a wildcarded zone **every undefined name returns a plausible answer**. Probing
`_mta-sts.themyersbriggs.co` or `_smtp._tls.themyersbriggs.co` returns `v=spf1 -all` off the `*`
record, which reads as "MTA-STS is configured." It is not.

This is worst for **DKIM selectors, which cannot be enumerated from DNS** — you can only query a
name you already know, so every wrong guess comes back with content. `opp.com` and `vitanavis.com`
were both wrongly reported as having no Mimecast DKIM after two guessed selector names missed; the
real selector was `mimecast20220323` in both. **Enumerate the zone instead** —
`dns_records?per_page=1000` here, `list-resource-record-sets` on Route 53. A guessed lookup is a
coin flip; the zone dump is the fact.

**Detect a wildcard before trusting any probe:** query a known-nonexistent control name in the same
zone. If it answers, every probe in that zone is suspect.

### 3. Chunked TXT records — naive joining corrupts them

Any TXT over 255 characters is split into multiple strings. This produced **four** wrong readings
during the DKIM audit: a valid 2048-bit key reported as `b64 err`, a correct Route 53 record
measured at 395 chars instead of 392, Mimecast keys called 1024-bit off a bad length count, and —
the expensive one — a *genuine defect dismissed as a parser bug*.

- **Cloudflare** stores chunks in `content` as `"aaa" "bbb"`. The `" "` is a **separator, not key
  material** — strip it before measuring or decoding.
- **Route 53** stores the same way inside a single `ResourceRecords[].Value`. Extract with
  `re.findall(r'"([^"]*)"', value)` and join. Never concatenate the raw value.

**When a decode fails, do not decide between "my parser is wrong" and "the record is wrong" by
reasoning — pull the vendor's source value from their console and diff it.** Three 2021/2022-era
Mimecast DKIM records (`cpp.com`, `opp.com`, `themyersbriggs.com`) each carried one stray space that
was absent from the vendor's value. RFC 6376 permits folding whitespace inside `p=` so verifiers
tolerate it, but it is still a defect; fixed 2026-08-10 by re-PATCHing the whitespace-stripped value
(identity-preserving — same key, no rotation).

### 4. `dig NS <public zone>` can return INTERNAL nameservers

Split-horizon zones resolve from inside. `dig +short NS opp.co.uk` from a domain-joined Mac returns
`mkpdvdmc01.opp.local` / `mkpdvdmc02.opp.local`, because `opp.co.uk` is served publicly by Cloudflare
**and** internally by the opp.local DCs. Probing "the authoritative NS" then reported
`_dmarc.assessment.opp.co.uk` absent while Cloudflare plainly had it. `themyersbriggs.co` was
unaffected — its `dig NS` returns Cloudflare — so **the failure is silent and per-zone**.

**Get the authoritative NS from the zone object** (`GET /zones?name=<zone>` → `name_servers[]`),
never from `dig NS` against the system resolver, and cross-check against `@1.1.1.1` and `@8.8.8.8`.
When a zone dump and an "authoritative" dig disagree, suspect split-horizon before suspecting the
data. See `../dns/README.md` for the internal-DNS side of this.

## Gotchas
- A Worker with no routes and no custom domains is unlinked and likely unused
- Zone ID must be looked up by name first — it's not the domain name itself
- **Read-after-write race on PATCH/DELETE.** The API returns `success: true` and the new value, but
  querying DNS within a second or two — *including the zone's own authoritative nameservers* — can
  still return the old record. Re-check after a few seconds before concluding a change failed. This
  produced two false "it didn't apply" reports on 2026-07-31.
- **Query each zone's own authoritative nameservers.** Cloudflare assigns a different NS pair per
  zone (`jim`/`monroe` for one, `moura`/`bryce` for another). Verifying zone B against zone A's
  nameservers silently falls back to a cached recursive answer and reads as a stale result.
- **Apex `NS` records in the zone are inert.** Imported zones often carry leftover registrar NS
  records (e.g. `ns3.worldnic.com`). Cloudflare serves its own delegation regardless, so these are
  cosmetic — confirm with `dig NS <zone> @<cloudflare-ns>` before assuming they do anything, and
  they are safe to delete.
- **`created_on` is the zone-import date** for bulk-imported records, not when the record was
  authored. Do not date a record's origin from it.
- **TXT record `content` MUST include surrounding double quotes** — always pass them explicitly in the JSON payload (e.g., `"content": "\"v=spf1 ...\""` ). Cloudflare may add them automatically if omitted, but this is not reliable and has caused malformed records in practice. This applies to SPF, DMARC, DKIM, and any other TXT record.
