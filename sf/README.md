# Salesforce API Field Notes

Hands-on notes covering Salesforce REST API usage, authentication, and scripting patterns.

---

## Platform

- **PROD org:** `themyersbriggs` (login: `https://login.salesforce.com`)
- **Sandbox:** `themyersbriggs--fullsand` (login: `https://test.salesforce.com`)
- **Base URL (REST):** `https://<instance>.salesforce.com/services/data/v<version>/`

---

## Authentication — JWT Bearer Token Flow

Server-to-server authentication using a self-signed X.509 certificate. No password or security token required. Access tokens are short-lived (~2 hours); re-assert the JWT to get a new one — there is no refresh token.

### Credentials file

Stored in `~/GitHub/.tokens/salesforce` (outside the repo). Contains:
- `SF_CONSUMER_KEY_PROD` — Connected App Consumer Key for PROD
- `SF_CONSUMER_KEY_SANDBOX` — Connected App Consumer Key for sandbox
- `SF_USERNAME_PROD` — Salesforce username for PROD
- `SF_USERNAME_SANDBOX` — Salesforce username for sandbox
- `SF_PRIVATE_KEY_PATH` — path to the private key file (e.g. `~/GitHub/.tokens/salesforce.key`)

### Token exchange

The script prints a **JSON object** to stdout (keys `access_token`, `instance_url`, `token_type`), not shell `KEY=value` exports. Do **not** `eval` its output — that fails with `command not found: access_token:`. Parse the JSON:

```bash
TOKENJSON=$(python3 /Users/fperez2nd/GitHub/api/sf/scripts/get_token.py --env prod)   # or --env sandbox
access_token=$(echo "$TOKENJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
instance_url=$(echo "$TOKENJSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['instance_url'])")
```

Use as:

```
Authorization: Bearer <access_token>
```

Token TTL is ~2 hours. Re-run the script to get a fresh token — there is no refresh token. Every new shell (each `Bash` call) needs its own token; shell variables don't persist between calls.

### Connected App location

The app lives under **Setup → Apps → External Client Apps** (not the regular App Manager). Sandbox app is named **IT Automation**, status Enabled.

### Connected App setup (one-time, per org)

Use **Setup → Apps → External Client Apps → New External Client App**.

**Basic Information:**
- External Client App Name: `IT Automation`
- API Name: `IT_Automation`
- Contact Email: team/group email
- Distribution State: `Local`

**API (Enable OAuth Settings):**
- Enable OAuth: checked
- Callback URL: `https://localhost`
- Selected OAuth Scopes: `Manage user data via APIs (api)` + `Perform requests at any time (refresh_token, offline_access)`
- Enable JWT Bearer Flow: checked — certificate upload appears once this is checked
- Upload `server.crt`

**Policies tab (after saving):**
- Select Profiles → add **System Administrator** to Selected column
- Permitted Users: `Admin approved users are pre-authorized`

**Settings tab:** copy the **Consumer Key** into `.salesforce-creds`. The Consumer Secret is not used in JWT flow but store it in 1Password alongside `server.key`.

> Note: `refresh_token` scope is required even though JWT flow doesn't use refresh tokens — omitting it causes a 400 error.

Certificate and key generated via:

```bash
openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 3650 -nodes \
  -subj "/CN=sf-api-automation"
```

1Password record: `Salesforce Connected App — IT Automation (PROD)` — vault: IT Operations. Contains Consumer Key, Consumer Secret, and `server.key` attachment. To restore credentials:
1. Copy `server.key` attachment to `~/GitHub/.tokens/salesforce-app/server.key`
2. Populate `~/GitHub/.tokens/salesforce` with Consumer Keys and usernames from the 1Password entry

---

## Tooling API — Metadata Queries

Named Credentials, External Credentials, and Auth Providers are metadata — use the Tooling API to read them, not the standard REST API.

**Base URL:** `https://<instance_url>/services/data/v62.0/tooling/`

### Query Named Credential by API name

```
GET /services/data/v62.0/tooling/query?q=SELECT+Id,DeveloperName,Endpoint+FROM+NamedCredential+WHERE+DeveloperName='D365_UAT'
```

### Fetch full Named Credential record (includes Metadata blob)

```
GET /services/data/v62.0/tooling/sobjects/NamedCredential/{Id}
```

Returns a `Metadata` block with the full config: URL, linked External Credential, `generateAuthorizationHeader`, OAuth scope, etc.

### Query External Credential by API name

```
GET /services/data/v62.0/tooling/query?q=SELECT+Id,DeveloperName,MasterLabel,AuthenticationProtocol+FROM+ExternalCredential+WHERE+DeveloperName='D365_UAT'
```

### Notes

- Use the `Id` from a query result to fetch the full record via `/sobjects/{type}/{Id}`
- `SamlSsoConfig` and `TransactionSecurityPolicy` are **not** Tooling API sObjects (`INVALID_TYPE` / "not supported"). Read them via the SOAP Metadata API instead (see below).
- API version used: `v62.0` — bump as needed; older versions may not expose all fields
- Standard SOQL applies: `WHERE`, `LIKE`, `ORDER BY`, `LIMIT` all work
- `get_token.py` outputs JSON, not shell exports — parse it, don't `eval` it (see [Token exchange](#token-exchange))
- `totalSize` in a query response reflects rows returned (respects `LIMIT`), not the full table count — use `SELECT COUNT(Id)` for a true total

---

## SOAP Metadata API — org settings and SSO

Org-wide settings (`SecuritySettings`, `SessionSettings`) and SSO/connected-app config are not
exposed as REST or Tooling sObjects. Use the SOAP Metadata API at
`https://<instance_url>/services/Soap/m/62.0` with the OAuth access token as the `sessionId`.

`readMetadata` envelope (SOAPAction: `readMetadata`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"
 xmlns:met="http://soap.sforce.com/2006/04/metadata">
  <env:Header><met:SessionHeader><met:sessionId>ACCESS_TOKEN</met:sessionId></met:SessionHeader></env:Header>
  <env:Body><met:readMetadata>
    <met:type>SecuritySettings</met:type>
    <met:fullNames>SecuritySettings</met:fullNames>
  </met:readMetadata></env:Body>
</env:Envelope>
```

Swap `readMetadata` for `listMetadata` (add `<met:asOfVersion>62.0</met:asOfVersion>`) to enumerate
`SamlSsoConfig`, `AuthProvider`, or `ConnectedApp` full names first, then read them.

Useful types:

| Type | Contains |
|------|----------|
| `SecuritySettings` | `networkAccess.ipRanges` (Trusted IP Ranges), `passwordPolicies`, full `sessionSettings` |
| `SamlSsoConfig` | IdP issuer, `loginUrl`, validation cert |
| `ConnectedApp` | `ipRelaxation` (`ENFORCE` / `BYPASS`), `ipRanges` |

### IP restriction surfaces — where to look

Four separate places, only one of which actually blocks a login:

1. **Profile Login IP Ranges** — the only hard block. Read per profile:
   `GET /services/data/v62.0/tooling/sobjects/Profile/{Id}` → `Metadata.loginIpRanges`.
   Querying `Metadata` in a Tooling SOQL `SELECT` returns one record max, so list profile Ids
   first (`SELECT Id, Name FROM Profile`) then fetch each record individually.
2. **Network Access → Trusted IP Ranges** (`SecuritySettings.networkAccess`) — never blocks.
   Only exempts from identity verification challenges.
3. **Session settings** — `enforceIpRangesEveryRequest` (re-check IP mid-session) and
   `lockSessionsToIp` (kill session on IP change).
4. **Connected App `ipRelaxation`** — `ENFORCE` makes that OAuth client honor 1 and 2.

Cross-check empirically with `SELECT SourceIp, Status, LoginType FROM LoginHistory ORDER BY
LoginTime DESC LIMIT 200`. If successful logins already come from residential IPs, nothing is
gating on source IP.

**When SSO is in play the SF-side settings are usually moot.** PROD federates to Entra ID
(`SamlSsoConfig` = `Entra ID SSO`, tenant `d5c15341`), so location enforcement lives in Entra
Conditional Access, not Salesforce. Check
`az rest --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies` and
`.../namedLocations` as well.

---

## Credentials location

All credential files live outside the repo in `~/GitHub/.tokens/`:

| File | Purpose |
|------|---------|
| `~/GitHub/.tokens/salesforce` | Creds file (`SF_CONSUMER_KEY_*`, `SF_USERNAME_*`, `SF_PRIVATE_KEY_PATH`) |
| `~/GitHub/.tokens/salesforce-app/server.key` | RSA private key for JWT signing (sourced from 1Password attachment) |
