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
