# Supabase Management API

Backend for the B2C platform. Org **The Myers Briggs Company** (Pro), two projects on
AWS us-east-1.

## Auth

| File | Token |
|------|-------|
| `.tokens/supabase` | `claude-automation` |
| `.tokens/supabase-experimental` | `claude-automation-experimental` |

Both are bare single-line `sbp_` values, 44 chars, mode 600. Documented in 1Password,
**Employee** vault. One credential per file, deliberately.

```bash
T=$(cat ~/GitHub/.tokens/supabase)
curl -H "Authorization: Bearer $T" https://api.supabase.com/v1/projects
```

Base URL `https://api.supabase.com/v1`. Rate limit 120 req/min per user per project or
org; analytics endpoints 30/min. Exceeding it returns `429`.

## Scope warning

A Supabase personal access token carries **the same privileges as the user account** and
**cannot be scoped**. There is no team-scope or project-scope option as there is on
Vercel. Frank is an org Owner, so these tokens can delete projects and read project API
keys. Treat them as root on the org.

## Three gotchas that will cost you time

**1. Copying from the dashboard can capture the token name too.** The value must be the
`sbp_` string alone, 44 characters, nothing else. Anything extra and every call returns
`401 {"message":"JWT could not be decoded"}`, which reads like a bad token rather than a
malformed file.

**2. Supabase returns `403 Forbidden` to Python's default `urllib` User-Agent.** Same
token via `curl` returns `200`. A 403 here is not necessarily an auth failure; check the
client before you suspect the credential.

```python
# fails with 403 regardless of token validity
urllib.request.Request(url, headers={"Authorization": f"Bearer {t}"})
# works: set a real User-Agent, or just use curl / requests
```

**3. Never put two tokens in one file.** `$(cat file)` then yields both, and a curl using
it still returns `200` because the embedded newline truncates the HTTP header, silently
sending only the first. It appears to work while doing something other than what you
intended.

## Identifiers

| Field | Value |
|-------|-------|
| Org | The Myers Briggs Company |
| Org slug / id | `qrvelzzyayvmmhicfwlc` |
| Project ref, prod | `zlpkzfzacplkpvptieup` |
| Project ref, dev | `mtptbxbrihsizvdzuodk` |

## Useful calls

```bash
T=$(cat ~/GitHub/.tokens/supabase)
ORG=qrvelzzyayvmmhicfwlc
PROD=zlpkzfzacplkpvptieup
api() { curl -s -H "Authorization: Bearer $T" "https://api.supabase.com$1"; }

api /v1/organizations
api "/v1/organizations/$ORG/members"
api /v1/projects
api "/v1/projects/$PROD/config/auth"            # see warning below
api "/v1/projects/$PROD/ssl-enforcement"
api "/v1/projects/$PROD/network-restrictions"
api "/v1/projects/$PROD/functions"
```

## Do not retrieve these

- **`/v1/projects/{ref}/api-keys`** returns the project `anon` and `service_role` keys.
  `service_role` bypasses row-level security entirely and is effectively database root
  for the application. Management and inventory tasks never need it.
- **`/v1/projects/{ref}/config/auth`** includes OAuth provider **client secrets**
  alongside the settings. Extract only the fields you need (`site_url`, `external_*_enabled`,
  password policy, MFA flags) rather than dumping the object.

## Landscape

Findings live in the `knowledge-base` repo at `landscape/supabase.md`.
