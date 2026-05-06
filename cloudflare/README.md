# Cloudflare API — Notes

Field notes from hands-on work against the Cloudflare API.

## Authentication
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

## Gotchas
- A Worker with no routes and no custom domains is unlinked and likely unused
- Zone ID must be looked up by name first — it's not the domain name itself
- **TXT record `content` MUST include surrounding double quotes** — always pass them explicitly in the JSON payload (e.g., `"content": "\"v=spf1 ...\""` ). Cloudflare may add them automatically if omitted, but this is not reliable and has caused malformed records in practice. This applies to SPF, DMARC, DKIM, and any other TXT record.
