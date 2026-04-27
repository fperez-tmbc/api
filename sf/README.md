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

Stored in `.salesforce-creds` at the repo root (gitignored). Contains:
- `SF_CONSUMER_KEY_PROD` — Connected App Consumer Key for PROD
- `SF_CONSUMER_KEY_SANDBOX` — Connected App Consumer Key for sandbox
- `SF_USERNAME_PROD` — Salesforce username for PROD
- `SF_USERNAME_SANDBOX` — Salesforce username for sandbox
- `SF_PRIVATE_KEY_PATH` — path to the private key file (also gitignored)

### Token exchange

```bash
source .salesforce-creds

# Build and sign the JWT assertion
JWT=$(python3 scripts/jwt_token.py --env prod)   # or --env sandbox

# Exchange for an access token
curl -s -X POST "https://login.salesforce.com/services/oauth2/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  -d "assertion=$JWT"
```

Returns `access_token` and `instance_url`. Use as:

```
Authorization: Bearer <access_token>
```

### Connected App setup (one-time, per org)

Use **Setup → App Manager → New External Client App** (the new UI — classic Connected Apps are replaced by External Client Apps).

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

1Password record: `Salesforce Connected App — IT Automation (PROD)` — vault: IT Operations. Contains Consumer Key, Consumer Secret, and `server.key`.

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
- API version used: `v62.0` — bump as needed; older versions may not expose all fields
- Standard SOQL applies: `WHERE`, `LIKE`, `ORDER BY`, `LIMIT` all work

---

## Gitignore

```
.salesforce-creds
server.key
server.crt
```
