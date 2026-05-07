# D365 F&O — OData API Notes

Field notes from hands-on work against TMBC's D365 Finance & Operations environments.
Covers authentication, tenant setup, entity discovery, and known limitations.

---

## Tenant Structure

TMBC runs two relevant Entra tenants:

| Tenant | Display Name | Domain | Tenant ID |
|--------|-------------|--------|-----------|
| **Corporate / Exchange Online** | The Myers-Briggs Company | `themyersbriggs.com` | `d5c15341-dfce-470a-bfdf-72c3dab91e7c` |
| **D365** | The Myers-Briggs Company - D365 | `themyersbriggs.onmicrosoft.com` | `43ca37ec-5cc6-4dc3-a1ee-ad4ccede8a02` |

D365 F&O environments authenticate against the **D365 tenant** (`43ca37ec`). App registrations for OData API access must be in this tenant (or be multi-tenant with consent granted here).

Exchange Online lives in the **corporate tenant** (`d5c15341`). App registrations for Graph `Mail.Send` must be in that tenant.

### Listing and resolving all tenants

```bash
# Get all tenant IDs the current account can access
az account tenant list --query "[].tenantId" --output tsv

# Resolve display name + domain for any tenant ID (public endpoint — no auth required to that tenant)
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='<tenant-id>')" \
  --query "{id:tenantId, name:displayName, domain:defaultDomainName}"
```

To list and resolve all at once:

```bash
az account tenant list --query "[].tenantId" --output tsv | while read -r tid; do
  result=$(az rest --method get \
    --url "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$tid')" \
    --output json 2>/dev/null)
  name=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('displayName','?'))")
  domain=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('defaultDomainName','?'))")
  printf "  %-45s  %-35s  %s\n" "$name" "$domain" "$tid"
done
```

---

## App Registrations

### D365 F&O API Access (OData + LCS)

| Field | Value |
|-------|-------|
| Display name | `D365 F&O API Access` |
| Client ID | `c5b7d1c7-1d84-4ee1-b8c8-54fefc3c1355` |
| Tenant | The Myers-Briggs Company - D365 (`43ca37ec`) |
| Permissions | Dynamics ERP — `user_impersonation` (delegated, admin consented); Dynamics Lifecycle Services — `user_impersonation` (delegated, admin consented) |
| Secret expires | 2028-04-25 |
| Credentials | `~/GitHub/.tokens/d365-odata` |

The LCS `user_impersonation` permission (resource SP `913c6de4-2a4a-4a61-a9ce-945d2b2ce2e0`, scope ID `a8737248-d2c2-4a7c-9759-3dfaad5c2f19`) was added in May 2026 to allow this app to call the LCS REST API. LCS uses a **password grant** flow, not client credentials — see LCS API section below.

### D365 Companion Apps — DEV (OData)

Shared SP used by all D365 Companion App Azure Functions targeting the DEV environment. Registered in D365 DEV under System Administration → Security → Azure Active Directory Applications.

| Field | Value |
|-------|-------|
| Display name | `D365_DEV_CompanionApps` |
| Client ID | `ea25e4c0-3bb8-40cb-9270-d4cbf713e308` |
| Tenant | The Myers-Briggs Company - D365 (`43ca37ec`, `themyersbriggs.onmicrosoft.com`) |
| KV secret | `D365-CLIENT-SECRET` in `kv-d365compapps-dev-us` (Elevate subscription `1110ac76`) |
| DEV registration | Confirmed working 2026-04-27 |

### D365 Companion Apps — PROD (OData)

| Field | Value |
|-------|-------|
| Client ID | `165d9e2d-155e-467b-96ba-7f89008eb9f4` |
| Tenant | The Myers-Briggs Company - D365 (`43ca37ec`) |
| KV secret | TBD |

**One-time D365 UI step required per environment:** Go to **System Administration → Setup → Microsoft Entra ID applications**, add the client ID and map it to a sysadmin user. Without this, the token will acquire successfully but all OData calls will return 401.

### D365 F&O Email Relay (Graph Mail.Send)

| Field | Value |
|-------|-------|
| Display name | `D365 F&O Email Relay` |
| Client ID | `f8c10ac8-b944-452d-a8e9-c8d6f201131a` |
| Tenant | The Myers-Briggs Company (`d5c15341`) |
| Permission | Microsoft Graph — `Mail.Send` (application, admin consented) |
| Secret expires | 2028-04-25 |
| Credentials | `~/GitHub/.tokens/d365-exo` |

---

## Authentication

D365 F&O OData uses OAuth 2.0 client credentials flow. Tokens are issued by the D365 tenant and scoped to the specific environment URL.

### Token acquisition

```bash
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/43ca37ec-5cc6-4dc3-a1ee-ad4ccede8a02/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=c5b7d1c7-1d84-4ee1-b8c8-54fefc3c1355" \
  -d "client_secret=<secret>" \
  -d "scope=https://tmbc-uat.sandbox.operations.dynamics.com/.default" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

Change the `scope` URL to match the target environment (UAT, prod, etc.).

### Making OData calls

```bash
curl -s -X GET \
  "https://tmbc-uat.sandbox.operations.dynamics.com/data/<EntityName>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json"
```

---

## Base URLs

Full environment inventory retrieved from LCS API (project 1362199) on 2026-05-06.

| Environment | LCS Type | OData Base URL |
|-------------|----------|----------------|
| TMBC | Production | `https://tmbc.operations.dynamics.com/data/` |
| TMBC-UAT | Sandbox | `https://tmbc-uat.sandbox.operations.dynamics.com/data/` |
| TMBC-DEVTEST39 | DevTestBuild | `https://tmbc-devtest399b0871be35c27446aos.axcloud.dynamics.com/data/` |
| TMBC-QA | DevTestBuild | `https://tmbc-qa8d63c1875ae9cc21aos.axcloud.dynamics.com/data/` |
| TMBC-DEV-3 | DevTestDev | `https://tmbc-dev-3f335a64232a605bedevaos.axcloud.dynamics.com/data/` |
| TMBC-DEV2-1 | DevTestDev | `https://tmbc-dev2-12aaf1f839cdfbb79devaos.axcloud.dynamics.com/data/` |
| TMBC-DEV39-2 | DevTestDev | `https://tmbc-dev39-2a29122b06525d8f9devaos.axcloud.dynamics.com/data/` |
| TMBC-MergeMain-2 | DevTestDev | `https://tmbc-mergemain-2bd831be92d982723devaos.axcloud.dynamics.com/data/` |
| TMBC-DEMO | Demo | `https://tmbc-demo885092553074bab1aos.axcloud.dynamics.com/data/` |
| DEMO47 | Demo | `https://demo473a2298c780ca82a3aos.axcloud.dynamics.com/data/` |

The token scope must match the target environment's base URL (without `/data/`). For PROD use `https://tmbc.operations.dynamics.com/.default`, for TMBC-QA use `https://tmbc-qa8d63c1875ae9cc21aos.axcloud.dynamics.com/.default`, etc.

---

## Entity Discovery

### List all entities

```bash
curl -s "https://tmbc-uat.sandbox.operations.dynamics.com/data/\$metadata" \
  -H "Authorization: Bearer $TOKEN" \
  | grep "EntityType Name" \
  | sed 's/.*Name="//;s/".*//'
```

### Inspect fields for a specific entity

```bash
curl -s "https://tmbc-uat.sandbox.operations.dynamics.com/data/\$metadata" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, re
xml = sys.stdin.read()
match = re.search(r'<EntityType Name=\"<EntityName>\".*?</EntityType>', xml, re.DOTALL)
if match:
    for p in re.findall(r'<Property Name=\"([^\"]+)\"', match.group(0)):
        print(p)
"
```

### Search metadata for entities by keyword

```bash
curl -s "https://tmbc-uat.sandbox.operations.dynamics.com/data/\$metadata" \
  -H "Authorization: Bearer $TOKEN" \
  | grep "EntityType Name" \
  | grep -i "<keyword>" \
  | sed 's/.*Name="//;s/".*//'
```

---

## Known Entities

### Companies

**Endpoint:** `GET /data/Companies`

Field names use PascalCase in responses (unlike what you might expect from OData conventions).

| Field | Notes |
|-------|-------|
| `DataArea` | Company code (e.g., `DAT`) — **not** `DataAreaId` |
| `Name` | Company display name |
| `KnownAs` | Alternate name |
| `LanguageId` | e.g., `en-us` |

### EmailParameters

**Endpoint:** `GET /data/EmailParameters`

Controls outbound email settings. Only **SMTP** fields are exposed via OData — Exchange Online provider credentials are **not** available here and must be configured via the D365 UI.

| Field | Type | Notes |
|-------|------|-------|
| `ID` | int | Always `0` — singleton record |
| `MailerNonInteractive` | string | Current provider: `SMTP`. Other values unknown — switching to `Exchange` via OData is possible but credentials cannot be set this way |
| `MailerInteractiveEnabled` | string | `None` when disabled |
| `SMTPRelayServerName` | string | SMTP server hostname |
| `SMTPPortNumber` | int | e.g., `587` |
| `SMTPRequireSSL` | string | `Yes` / `No` |
| `SMTPUseNTLM` | string | `Yes` / `No` |
| `SMTPUserName` | string | e.g., `apikey` (SendGrid) |
| `MaximumEmailAttachmentSize` | int | In MB |

**Limitation:** The Exchange Online provider (OAuth) configuration — client ID, client secret, tenant domain — is stored in internal D365 system tables not exposed as OData data entities. These must be set in the D365 UI: **System Administration → Setup → Email → Email parameters**.

---

## D365 F&O Email Configuration — UI Reference (UAT observations)

### Page location

**System Administration → Setup → Email → Email parameters** (URL: `SysEmailParameters`)

### Configuration tab

- **Batch email provider** dropdown — controls which provider handles non-interactive/batch email (e.g., invoices). Options observed: `SMTP`, `Exchange`, `Graph`.
- **Enabled interactive email providers** — dual-column list (Available / Enabled). In UAT: Exchange and SMTP are both in the Enabled column.
- **Email throttling** — per-provider rate limits. UAT values: Exchange = 30/min, Graph = 30/min, SMTP = 30/min.
- **Email history** — retain for 15 days.

### SMTP settings tab

Configures the SMTP provider. UAT state as of 2026-04-25 (broken — SendGrid credentials were cleared):

| Setting | Value |
|---------|-------|
| Outgoing mail server | *(empty)* |
| SMTP port number | `587` |
| SSL/TLS required | Yes |
| Authentication required | Yes |
| User name | `apikey` *(stale SendGrid credential)* |
| Password | *(empty — causes warning banner)* |

The warning banner *"The SMTP username needs a valid password"* appears whenever a username is present but the password field is empty.

### Microsoft Graph settings tab

This is the configuration screen for the **Exchange Online / Graph email provider** — not a separate "Exchange" tab. Supports two authentication modes:

**Mode 1 — Client secret (simpler):**
- Toggle **Use federated credentials** → Off
- Enter **Application ID** — the Entra app client ID
- Enter **Application secret** — the client secret

**Mode 2 — Federated credentials (secretless, more secure):**
- Toggle **Use federated credentials** → On
- **Issuer** — typically `https://login.microsoftonline.com/<tenant-id>/v2.0`
- **Subject identifier** — the federated identity subject claim from the issuing workload

UAT state as of 2026-04-25: federated credentials toggled **On**, Issuer and Subject identifier pre-populated (likely by D365 implementation team — SAGlobal), Application ID and Application secret both **empty**. The Exchange provider is therefore not functional despite appearing in the Enabled list.

**Pre-populated federated credential values in UAT:**
- **Issuer:** `https://login.microsoftonline.com/43ca37ec-5cc6-4dc3-a1ee-ad4ccede8a02/v2.0` *(The Myers-Briggs Company - D365 tenant)*
- **Subject identifier:** `/eid1/c/pub/t/7DfKQ8Zcw02h7q1Mzt6KAg/a/NzTBlPCgbUeSZy6hZONy5A/1bb54f1f-eeb2-4ef2-848c-e41dee7dfd78`

Test buttons on this page: **Test authentication** and **Test federated credential authentication**.

### Cross-tenant limitation — D365 Graph email does not work across Entra tenants

**The Myers-Briggs Company - D365** (`43ca37ec`) hosts D365 F&O. **The Myers-Briggs Company** (`d5c15341`) hosts Exchange Online. These are separate Entra tenants.

D365 F&O's Microsoft Graph email integration always authenticates against its own Entra tenant. All three cross-tenant approaches were tested and confirmed blocked on 2026-04-25:

#### Attempt 1 — Single-tenant app in corporate tenant + client secret

D365 uses `ClientCredentialRequest` (MSAL). Looks up the app in the D365 tenant, app is not there.

```
AADSTS700016: Application with identifier 'f8c10ac8-...' was not found
in the directory 'The Myers-Briggs Company - D365'.
```

#### Attempt 2 — Single-tenant app in corporate tenant + federated credential

When federated credentials are configured, D365 switches to `FederatedManagedIdentityAuthenticator` → `ManagedIdentityTokenAcquirer`. D365 uses its own managed identity (subject: `/eid1/c/pub/t/7DfKQ8Zcw02h7q1Mzt6KAg/a/NzTBlPCgbUeSZy6hZONy5A/1bb54f1f-eeb2-4ef2-848c-e41dee7dfd78`) to acquire the assertion. Still calls the D365 tenant token endpoint, still fails for the same reason.

```
AADSTS700016: Application with identifier 'f8c10ac8-...' was not found
in the directory 'The Myers-Briggs Company - D365'.
```

#### Attempt 3 — Multi-tenant app + admin consent in D365 tenant + federated credential

Made the app multi-tenant (`AzureADMultipleOrgs`), granted admin consent in `43ca37ec` (creating a service principal there). The app is now found — AADSTS700016 is gone. New error:

```
AADSTS70052: The identity must be a managed identity, a single tenant app, or a service account.
```

D365's `FederatedManagedIdentityAuthenticator` explicitly rejects multi-tenant apps. This is a deliberate Microsoft restriction, not a misconfiguration.

#### Conclusion — Graph email requires same-tenant D365 and Exchange Online

All three paths are blocked. The error codes confirm this is by design:
- AADSTS700016 blocks external apps
- AADSTS70052 blocks multi-tenant apps from the federated managed identity flow

The only path that would work is registering the app in the D365 tenant (`43ca37ec`) as single-tenant — but Exchange Online is not in that tenant, so a Graph token from `43ca37ec` has no authority over mailboxes in `d5c15341`. Full tenant merger is the only real fix.

**Note on SAGlobal config:** The pre-populated Issuer/Subject identifier values in D365 UAT (`43ca37ec` issuer, `/eid1/c/pub/...` subject) suggest SAGlobal attempted this path and knew D365's managed identity subject. Their configuration was incomplete (no app registered in `43ca37ec`, Application ID and secret fields empty). Even if complete, it would hit AADSTS70052 because no single-tenant app in `43ca37ec` can access Exchange Online in `d5c15341`.

**Recommended alternatives:** See `~/GitHub/task-tracker/projects/d365-exchange-online-email/README.md` for Option A (Exchange Online HVE) and Option B (Postfix relay with Exchange Online inbound connector).

### Email history

Accessible via **Configuration → Email history → View email history** or the Options menu on the Email parameters page.

- Shows per-message detail: sender, subject, sent date/time, recipients, provider used, status, attachment count
- Confirmed sender mailbox for D365 UAT invoice emails: **`creditcontrol@themyersbriggs.com`**
- Last confirmed working: SMTP provider, emails sent 2026-04-14 with status `Sent`

---

## Security Role Management

### Entity map — three different entities, three different purposes

| Entity Set | Use | Writable |
|-----------|-----|---------|
| `SecurityRoles` | Catalog of all roles in the system | No |
| `SecurityUserRoles` | Read current role assignments for a user | No (reads only) |
| `SecurityUserRoleAssociations` | **Write** global (non-company-restricted) role assignments | **Yes — use this for POST** |
| `SecurityUserRoleOrganizations` | Write company-restricted role assignments (AU/SG users only) | Yes |

The D365 UI data entity "System security user role organization" maps to **`SecurityUserRoleAssociations`**.
The D365 UI data entity "System security user role organization assignment" maps to **`SecurityUserRoleOrganizations`**.

### Global role assignment (no company restriction)

POST to `SecurityUserRoleAssociations`. **`SecurityRoleName` is required** in the body — the role identifier alone will return a validation error ("Security role '' with identifier value '...' is not valid").

```bash
curl -s -X POST "${BASE_URL}/data/SecurityUserRoleAssociations" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "UserId": "jsmith",
    "SecurityRoleIdentifier": "DOCENTRICAXVIEWER",
    "SecurityRoleName": "Docentric AX Viewer",
    "AssignmentMode": "Manual",
    "AssignmentStatus": "Enabled"
  }'
```

Fields returned on success: `UserId`, `SecurityRoleIdentifier`, `AssignmentStatus`, `AssignmentMode`, `SecurityRoleName`.

### Check a user's current role assignments

```bash
curl -s -G "${BASE_URL}/data/SecurityUserRoles" \
  --data-urlencode "\$filter=UserId eq 'jsmith'" \
  --data-urlencode "\$select=UserId,SecurityRoleIdentifier,SecurityRoleName,AssignmentMode,AssignmentStatus" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json"
```

### Find role identifiers by name

```bash
curl -s -G "${BASE_URL}/data/SecurityRoles" \
  --data-urlencode "\$select=SecurityRoleIdentifier,SecurityRoleName" \
  --data-urlencode "\$top=500" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['value']:
    if 'KEYWORD' in r.get('SecurityRoleIdentifier','').upper():
        print(r['SecurityRoleIdentifier'], '|', r['SecurityRoleName'])
"
```

### Docentric role identifiers (UAT/PROD confirmed 2026-05-06)

| Identifier | Role Name |
|-----------|-----------|
| `DOCENTRICAXADMIN` | Docentric AX Administrator |
| `DOCENTRICAXALERTADMIN` | Docentric AX Alert Administrator |
| `DOCENTRICAXELECTRONICSIGNATUREUSER` | Docentric AX Electronic Signature User |
| `DOCENTRICAXEMAILTEMPLATEEDITOR` | Docentric AX Email Template Editor |
| `DOCENTRICAXLICENSEMANAGER` | Docentric AX License Manager |
| `DOCENTRICAXPOWERUSER` | Docentric AX Power User |
| `DOCENTRICAXPRINTARCHIVEPDFPASSWORDREADER` | Docentric AX Print Archive PDF Password Reader |
| `DOCENTRICAXREPORTATTACHMENTSUSER` | Docentric AX Report Attachments User |
| `DOCENTRICAXTEMPLATEEDITOR` | Docentric AX Template Editor |
| `DOCENTRICAXUSERDEFINEDLABELSUSER` | Docentric AX Report Labels User |
| `DOCENTRICAXVIEWER` | Docentric AX Viewer |

---

## User Lookup

### UAT users are anonymized

In UAT, `PersonName` is blank for all users and email is set to `no-reply@themyersbriggs.net`. Use the `Alias` field — it contains the real email address.

```bash
# Find user by real email (use Alias, not PersonName or Email)
curl -s -G "${BASE_URL}/data/SystemUsers" \
  --data-urlencode "\$filter=Alias eq 'jsmith@themyersbriggs.com'" \
  --data-urlencode "\$select=UserId,Alias,PersonName,NetworkAlias" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json"
```

User IDs follow a first-initial + last-name pattern, truncated to ~8 characters (e.g., `jsmith`, `csamwort`, `swhitema`). PROD and UAT use the same user IDs.

### Legal entity company codes (UAT/PROD confirmed)

| Code | Notes |
|------|-------|
| `1000` | Appears on some roles; exact entity unclear |
| `2100` | Primary Americas entity |
| `2200` | SG/AU entity |

AU/SG users have roles assigned to specific company codes via `SecurityUserRoleOrganizations`. All other users receive global assignments via `SecurityUserRoleAssociations` (no company restriction).

---

## OData Query Patterns

```bash
# Top N records
GET /data/<Entity>?$top=5

# Filter
GET /data/<Entity>?$filter=DataArea eq 'USMF'

# Select specific fields
GET /data/<Entity>?$select=Field1,Field2

# Order by
GET /data/<Entity>?$orderby=Name asc

# Count
GET /data/<Entity>?$count=true&$top=0
```

---

## Gotchas

### Field names are PascalCase
D365 OData returns PascalCase field names (`DataArea`, not `dataAreaId`). The field name in the entity schema matches what comes back in the response — always check `$metadata` or do a `$top=1` read first.

### `EmailParameters` Exchange credentials not in OData
When Microsoft added Exchange Online as an email provider in D365 F&O, the OAuth credentials (client ID, secret, tenant) were not surfaced as OData data entity fields. There is no programmatic way to set these via the API — UI configuration is required.

### Registering the app in D365 is required even with a valid token
A correctly issued token (from the right tenant, right scope) will still get a `401` on all OData calls unless the app's client ID has been registered in **System Administration → Setup → Microsoft Entra ID applications** and mapped to a D365 user. This step is per-environment (DEV, UAT, and prod are separate).

To verify programmatically whether an SP is registered in a given environment, acquire a token and make a lightweight OData call — a `200` confirms registration, `401` means it is not registered:

```bash
SECRET=$(az keyvault secret show --vault-name <vault> --name <secret-name> --query "value" -o tsv)

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/43ca37ec-5cc6-4dc3-a1ee-ad4ccede8a02/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=<client-id>" \
  -d "client_secret=$SECRET" \
  -d "scope=<d365-base-url>/.default" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))")

curl -s -o /dev/null -w "%{http_code}" \
  "<d365-base-url>/data/Companies?\$top=1" \
  -H "Authorization: Bearer $TOKEN"
# 200 = registered and working; 401 = not registered
```

### Enum fields require full type namespace in OData `$filter`

D365 F&O custom enum fields (e.g. `CPP_IntegrationStatus`) are exposed as named OData types. Filtering with a plain integer or bare string returns `400 Bad Request`. The correct syntax requires the full `Microsoft.Dynamics.DataEntities.*` namespace prefix:

```bash
# Wrong — returns 400
$filter=Status eq 0
$filter=Status eq 'Unprocessed'

# Correct — returns 200
$filter=Status eq Microsoft.Dynamics.DataEntities.CPP_IntegrationStatus'Unprocessed'
```

To find the correct type name for any enum field, inspect `$metadata`:

```bash
curl -s "<base-url>/data/\$metadata" -H "Authorization: Bearer $TOKEN" \
  | grep -A 5 'Property Name="<FieldName>"'
# Look for: Type="Microsoft.Dynamics.DataEntities.<EnumTypeName>"
```

PATCH request bodies are not affected — string enum names work directly in JSON:
```json
{ "Status": "Unprocessed" }
```

### `contains()` function is unreliable on some entities

The OData `contains()` function returns `"An error has occurred"` on certain entities (confirmed on `SecurityRoles`). Use `eq` for exact matches, or fetch all records with `$select` and filter client-side in Python:

```bash
curl -s -G "${BASE_URL}/data/SecurityRoles" \
  --data-urlencode "\$select=SecurityRoleIdentifier,SecurityRoleName" \
  --data-urlencode "\$top=500" \
  -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['value']:
    if 'KEYWORD' in r.get('SecurityRoleIdentifier','').upper(): print(r)
"
```

### Always use `-G --data-urlencode` for OData query parameters in bash

Embedding `$filter`, `$select`, etc. directly in double-quoted URLs causes silent failures — bash treats `$filter` as an empty variable, producing malformed URLs with no error. Use `-G` with `--data-urlencode` instead:

```bash
# Wrong — $filter treated as empty bash variable
curl -s "${BASE_URL}/data/Entity?$filter=UserId eq 'x'&$select=UserId"

# Correct
curl -s -G "${BASE_URL}/data/Entity" \
  --data-urlencode "\$filter=UserId eq 'x'" \
  --data-urlencode "\$select=UserId"
```

### `SecurityUserRoleAssociations` requires `SecurityRoleName` in POST body

When assigning roles via `SecurityUserRoleAssociations`, including only `SecurityRoleIdentifier` returns: `"Security role '' with identifier value '...' is not valid"`. Always include `SecurityRoleName` explicitly. The role name can be confirmed first via a `SecurityRoles` query.

### `user_impersonation` scope works for client credentials
The D365 Dynamics ERP permission (`user_impersonation`) is a delegated scope, but it works with the client credentials flow when the app is registered in D365's Entra ID applications list. D365 maps the app's token to the user account specified in the registration.

---

## LCS (Lifecycle Services) API

Base URL: `https://lcsapi.lcs.dynamics.com`

TMBC's LCS project ID: **1362199** (visible in the LCS portal URL: `lcs.dynamics.com/V2/ProjectOverview/1362199`).

### Authentication — password grant (not client credentials)

LCS uses a **delegated** permission (`user_impersonation`) and requires a real user account — client credentials flow will not work. Use `grant_type=password` against the v1 token endpoint (v2 does not support password grant):

```bash
source ~/GitHub/.tokens/d365-odata   # exports CLIENT_ID, CLIENT_SECRET

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/common/oauth2/token" \
  -d "grant_type=password" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "resource=https://lcsapi.lcs.dynamics.com" \
  -d "username=admin@themyersbriggs.onmicrosoft.com" \
  -d "password=${PASSWORD}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('error_description','')[:200])")
```

The password prompt script is at `~/GitHub/lcs-token.sh` — it prompts for the password without saving it to history.

**Token TTL:** ~1 hour. Generate a fresh token per session.

### List all environments in a project

```bash
curl -s "https://lcsapi.lcs.dynamics.com/environmentinfo/v1/detail/project/1362199/?page=1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json"
```

Response shape:
```json
{
  "ResultPageCurrent": 1,
  "ResultHasMorePages": true,
  "Data": [
    {
      "EnvironmentId": "...",
      "EnvironmentName": "TMBC-UAT",
      "EnvironmentType": "Sandbox",
      "EnvironmentEndpointBaseUrl": "https://tmbc-uat.sandbox.operations.dynamics.com/",
      "DeploymentState": "Finished",
      "CurrentApplicationReleaseName": "10.0.47"
    }
  ]
}
```

Increment `?page=N` until `ResultHasMorePages` is `false`. As of 2026-05-06 there are 10 environments across 2 pages.

### Gotchas

- **No project listing endpoint.** The LCS API has no endpoint to enumerate projects — the project ID must be known. Find it in the LCS portal URL when viewing the project overview.
- **v1 token endpoint only.** The LCS resource (`https://lcsapi.lcs.dynamics.com`) does not work with the MSAL v2 endpoint (`/oauth2/v2.0/token`). Use the v1 endpoint (`/oauth2/token`) with `resource=` parameter.
- **App must have LCS `user_impersonation`.** The `D365 F&O API Access` app registration needs the Dynamics Lifecycle Services API delegated permission (`user_impersonation`, scope ID `a8737248-d2c2-4a7c-9759-3dfaad5c2f19`) granted with admin consent, in addition to the Dynamics ERP permission for OData access. Add via: `az ad app permission add --id <client-id> --api 913c6de4-2a4a-4a61-a9ce-945d2b2ce2e0 --api-permissions a8737248-d2c2-4a7c-9759-3dfaad5c2f19=Scope` (run against D365 tenant, then grant admin consent).

---

## Official Docs

- [D365 F&O OData overview](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/data-entities/odata)
- [Authentication for D365 F&O integrations](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/data-entities/services-home-page)
- [D365 F&O email configuration (Exchange provider)](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/organization-administration/configure-email)
