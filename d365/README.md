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

### D365 F&O API Access (OData)

| Field | Value |
|-------|-------|
| Display name | `D365 F&O API Access` |
| Client ID | `c5b7d1c7-1d84-4ee1-b8c8-54fefc3c1355` |
| Tenant | The Myers-Briggs Company - D365 (`43ca37ec`) |
| Permission | Dynamics ERP — `user_impersonation` (delegated, admin consented) |
| Secret expires | 2028-04-25 |
| Credentials | `~/GitHub/.tokens/d365-odata` |

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

| Environment | OData Base URL |
|-------------|----------------|
| DEV | `https://tmbc-devtest399b0871be35c27446aos.axcloud.dynamics.com/data/` |
| UAT | `https://tmbc-uat.sandbox.operations.dynamics.com/data/` |
| PROD | `https://tmbc.operations.dynamics.com/data/` |

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

### `user_impersonation` scope works for client credentials
The D365 Dynamics ERP permission (`user_impersonation`) is a delegated scope, but it works with the client credentials flow when the app is registered in D365's Entra ID applications list. D365 maps the app's token to the user account specified in the registration.

---

## Official Docs

- [D365 F&O OData overview](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/data-entities/odata)
- [Authentication for D365 F&O integrations](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/data-entities/services-home-page)
- [D365 F&O email configuration (Exchange provider)](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/organization-administration/configure-email)
