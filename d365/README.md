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

> **Convention:** When "DEV" is referenced without further qualification, it means **TMBC-DEVTEST39** (`https://tmbc-devtest399b0871be35c27446aos.axcloud.dynamics.com/`).

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

### Disable (or re-enable) a role assignment

**Do not use DELETE** — `DELETE /data/SecurityUserRoleAssociations(...)` silently returns 204 without removing the record. The correct approach is PATCH with `AssignmentStatus`:

```bash
# Disable a role assignment
curl -s -X PATCH \
  "${BASE_URL}/data/SecurityUserRoleAssociations(UserId='jsmith',SecurityRoleIdentifier='DOCENTRICAXVIEWER')" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"AssignmentStatus": "Disabled"}'

# Re-enable a role assignment
curl -s -X PATCH \
  "${BASE_URL}/data/SecurityUserRoleAssociations(UserId='jsmith',SecurityRoleIdentifier='DOCENTRICAXVIEWER')" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"AssignmentStatus": "Enabled"}'
```

Both return 204 on success. Verify via `SecurityUserRoleAssociations` (not `SecurityUserRoles` — the read-only view may cache stale state).

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

### Direct key lookup for SystemUsers

`$filter=UserId eq '<id>'` is unreliable on the `SystemUsers` entity — it returns empty results even when the user exists. Use the direct key form instead:

```bash
curl -s "${BASE_URL}/data/SystemUsers('jsmith')" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json"
```

### Enable / disable a user account

The field is `Enabled` (boolean). PATCH the user directly:

```bash
# Disable
curl -s -X PATCH "${BASE_URL}/data/SystemUsers('jsmith')" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"Enabled": false}'

# Enable
curl -s -X PATCH "${BASE_URL}/data/SystemUsers('jsmith')" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"Enabled": true}'
```

A 204 response indicates success. Note: other Yes/No fields on `SystemUsers` use strings (`"Yes"`/`"No"`), but `Enabled` is a true boolean.

### Create a user via OData — exact field names required

Creating a `SystemUsers` record over OData works, but you must use the entity's **exact** field names. Guessing fails in a misleading way:

- Missing language fields → `400`: `Field 'UserInfo_language' must be filled in.; Field 'Helplanguage' must be filled in.`
- Wrong field names (`Language`/`HelpLanguage` instead of the real ones) → `400` with the generic `Exception has been thrown by the target of an invocation` (looks like an AAD/Graph failure, but it's just the wrong field name).

Working field set (confirmed 2026-06-05 across DEVTEST39/UAT/QA):

```bash
curl -s -X POST "${BASE_URL}/data/SystemUsers" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "UserID": "jsmith",
    "UserName": "Jane Smith",
    "Alias": "jsmith@themyersbriggs.com",
    "Email": "jsmith@themyersbriggs.com",
    "Company": "2100",
    "NetworkDomain": "https://sts.windows.net/themyersbriggs.com/",
    "UserInfo_language": "en-us",
    "Helplanguage": "en-us",
    "UserInfo_defaultPartition": true,
    "AccountType": "ClaimsUser",
    "Enabled": false
  }'
```

- `UserInfo_language` and `Helplanguage` are required (UI labels them Language / Help language; entity field names differ). `en-us` is safe.
- `NetworkDomain`: corporate `@themyersbriggs.com` users → `https://sts.windows.net/themyersbriggs.com/`; D365-tenant-native `@themyersbriggs.onmicrosoft.com` accounts → `https://sts.windows.net/` (no suffix).
- D365 **auto-assigns the default `SYSTEMUSER` role** on creation, so a new user starts with 1 role.
- You can create a user with `Enabled: false` and still assign roles to it — disabled accounts hold role assignments. This is the way to clone a user into a sandbox for role parity without consuming a license.
- `201` = created. The supported UI alternative is **System administration → Users → Import users** (resolves Entra automatically); the OData create above does not need the Entra Object ID/SID.

### Delete a user via OData — a real delete (unlike `SecurityUserRoleAssociations`)

`DELETE /data/SystemUsers('<userid>')` genuinely removes the user record in F&O — returns `204`, and a follow-up `GET` returns `404`. This is **not** the silent no-op that `DELETE` is on `SecurityUserRoleAssociations`. The user's role assignments go with the record.

```bash
curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  "${BASE_URL}/data/SystemUsers('lmenig')" \
  -H "Authorization: Bearer ${TOKEN}"
# 204 = deleted; re-GET returns 404 to confirm
```

F&O blocks deletion of users referenced by worker records or posted transactions (FK constraint error); orphaned / never-transacted accounts delete cleanly. Always confirm with a follow-up `GET` (expect `404`) rather than assuming the 204 took.

Confirmed 2026-06-06 removing an orphaned sandbox account (`lmenig` / Latoya Menig) from DEV and QA — present only in those two sandboxes, absent from PROD/UAT, and with no corporate Entra identity. Both deletes returned 204 and verified 404 on re-read.

### Determining genuinely-disabled users — PROD is the source of truth

**Do not use a lower environment's `Enabled` flag to decide who is an inactive/disabled user.** D365 routinely refreshes the lower environments (UAT, QA, sandboxes) from PROD, and the refresh process **disables accounts** as a side effect. So a disabled account in UAT/QA is very often an *active* employee whose sandbox account was disabled by the refresh — not someone who left.

Confirmed 2026-06-04 ratios: PROD 70/159 disabled, UAT 84/175, QA 123/170. The lower envs over-report disabled by a wide margin.

**Correct pattern for any "remove/clean up disabled users" task (role assignments, etc.):**
1. Build the authoritative disabled-user list from **PROD** (`SystemUsers` where `Enabled=false`).
2. Derive the exact (UserId, Role) removal list in PROD.
3. Apply that **same** list to the lower environments — match on (UserId, Role), ignore the lower env's own `Enabled` flag entirely.

Driving off each environment's own flag wrongly strips roles from active employees in the lower envs. (This exact mistake was made and corrected on tickets 101273/101274.)

### Legal entity company codes (UAT/PROD confirmed)

| Code | Notes |
|------|-------|
| `1000` | Appears on some roles; exact entity unclear |
| `2100` | Primary Americas entity |
| `2200` | SG/AU entity |

AU/SG users have roles assigned to specific company codes via `SecurityUserRoleOrganizations`. All other users receive global assignments via `SecurityUserRoleAssociations` (no company restriction).

---

## Licensing — D365 F&O licenses live in the D365 tenant, not corporate

The D365 F&O licenses (`DYN365_FINANCE`, `Dynamics_365_Finance_Premium`, `DYN365_SCM`, `DYN365_SCM_ATTACH`, etc.) are **not** assigned to the user's corporate `@themyersbriggs.com` account in the corporate tenant (`d5c15341`). That account holds only standard M365 SKUs (Business Premium, Teams, Phone, Power BI, …). Looking there for a "D365 license to remove" finds nothing.

The D365 license is assigned to the user's **guest** object in the **D365 tenant** (`43ca37ec`), where the UPN looks like `cfrost_themyersbriggs.com#EXT#@themyersbriggs.onmicrosoft.com` (`userType: Guest`). The Dynamics SKUs are owned by that tenant's subscriptions.

`az` (signed in as `2fperez@themyersbriggs.com`) can get a Graph token for the D365 tenant directly — no separate login:

```bash
TOK=$(az account get-access-token --tenant 43ca37ec-5cc6-4dc3-a1ee-ad4ccede8a02 \
  --resource "https://graph.microsoft.com" --query accessToken -o tsv)
```

To find a corporate user's D365 license: search the D365 tenant by `mail` (not UPN — the UPN is the `#EXT#` form), then read `licenseDetails`:

```bash
# resolve guest object id by corporate email
GET https://graph.microsoft.com/v1.0/users?$filter=mail eq 'cfrost@themyersbriggs.com'&$select=id,userPrincipalName,userType
# list its licenses
GET https://graph.microsoft.com/v1.0/users/{id}/licenseDetails
# check direct vs group-based:
GET https://graph.microsoft.com/v1.0/users/{id}?$select=licenseAssignmentStates   # assignedByGroup=null => direct
```

To remove (direct assignments), POST `assignLicense` with the skuIds:

```bash
POST https://graph.microsoft.com/v1.0/users/{id}/assignLicense
{ "addLicenses": [], "removeLicenses": ["<skuId1>","<skuId2>"] }   # HTTP 200 on success
```

Resolve skuId↔name via `GET /subscribedSkus?$select=skuId,skuPartNumber` **against the D365 tenant** (the SKU set differs from corporate). Confirmed 2026-06-25 on ticket 101375 — removed Finance + SCM_ATTACH from 7 sales users' guest accounts (all directly assigned). `DYN365_SCM_ATTACH` was a fully-consumed pool (45/45).

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

### User-id field casing differs by entity — `UserId` vs `UserID`

The "user id" field is spelled differently depending on the entity. Selecting, filtering, or key-referencing the wrong casing returns **400 Bad Request** — and D365 mislabels the reason phrase as `Internal Server Error`, so the HTTP status (400, not 500) is the real tell.

| Entity | Field name |
|--------|-----------|
| `SecurityUserRoles`, `SecurityUserRoleAssociations` | `UserId` (lowercase **d**) — confirmed |
| `SystemUsers` | `UserID` (capital **ID**) — confirmed |

A plain `GET` with no `$select` returns every field regardless of casing, so the mismatch only surfaces on `$select`, `$filter`, or key lookups. The trap: when cross-referencing role members against account `Enabled` state, you read `UserId` off the assignment entity and must switch to `UserID` to look the same user up on `SystemUsers`. Confirmed 2026-06-04 (UAT/PROD/QA) — a `SystemUsers?$select=UserId,...` returned 400; `$select=UserID,...` worked.

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

### Python `urllib` rejects unencoded OData query params (errors, unlike curl)

The bash trap above fails *silently*; the Python equivalent fails *loudly*. `urllib.request.urlopen` raises `http.client.InvalidURL: URL can't contain control characters` on the space in `UserId eq 'x'` and never sends the request — `urllib` does **not** auto-encode the query string. Encode it yourself:

```python
import urllib.parse
q = urllib.parse.urlencode(
    {"$filter": "UserId eq 'jsmith'", "$select": "UserId,AssignmentStatus"},
    quote_via=urllib.parse.quote,   # encode spaces as %20, not '+'
)
url = f"{BASE_URL}/data/SecurityUserRoleAssociations?{q}"
```

Use `quote_via=urllib.parse.quote` so spaces become `%20` (the default `+` can be misread by some OData parsers). Confirmed 2026-06-05.

### `DELETE` on `SecurityUserRoleAssociations` is a silent no-op

`DELETE /data/SecurityUserRoleAssociations(UserId='...',SecurityRoleIdentifier='...')` returns 204 but does not remove the record. To remove a role from a user, PATCH `AssignmentStatus` to `"Disabled"` instead. See the Security Role Management section for the correct pattern.

### `SecurityUserRoleAssociations` requires `SecurityRoleName` in POST body

When assigning roles via `SecurityUserRoleAssociations`, including only `SecurityRoleIdentifier` returns: `"Security role '' with identifier value '...' is not valid"`. Always include `SecurityRoleName` explicitly. The role name can be confirmed first via a `SecurityRoles` query.

### EntityType name ≠ EntitySet name — always use EntitySet names in URLs

The `$metadata` document contains both `EntityType` and `EntitySet` entries. The `EntityType Name` (e.g., `SecurityPrivilege`) is the schema type — **not** a valid URL segment. The `EntitySet Name` (e.g., `SecurityPrivileges`) is what goes in the URL. Using the EntityType name returns 404 with no useful error.

Always grep for `EntitySet Name` when looking up endpoint names:

```bash
curl -s "<base-url>/data/\$metadata" -H "Authorization: Bearer $TOKEN" \
  | grep 'EntitySet Name' \
  | grep -i "<keyword>" \
  | sed 's/.*Name="//;s/".*//'
```

### Security hierarchy entities — querying role privileges and duties

The following EntitySets expose the D365 security model hierarchy:

| EntitySet | Use |
|-----------|-----|
| `SecurityRoles` | Role catalog — AOT name + friendly name |
| `SecurityRoleDuties` | Duties assigned to a role |
| `SecurityDutiesV2` | Flattened role → duty → privilege view |
| `SecurityPrivileges` | Privileges assigned to a role (direct + via duties) |
| `SecuritySubRolesV2` | Sub-roles within a role |

All support `$filter=SecurityRoleIdentifier eq '<AOT name>'`. Each record includes both an identifier (AOT name) and a name (friendly label) field.

**Caveat:** `SecurityPrivileges` returns an exploded/inherited set that may differ slightly from what the D365 Security Configuration UI shows. Differences found via API should be verified in the GUI before drawing conclusions.

### `user_impersonation` scope works for client credentials
The D365 Dynamics ERP permission (`user_impersonation`) is a delegated scope, but it works with the client credentials flow when the app is registered in D365's Entra ID applications list. D365 maps the app's token to the user account specified in the registration.

### Bulk OData writes throttle sandboxes — keep concurrency low, never run side-queries during a bulk job

Mass PATCH operations (e.g. disabling hundreds of `SecurityUserRoleAssociations`) throttle the **sandbox** environments hard. PROD absorbed ~700 writes at concurrency 5 cleanly, but UAT (~660 writes) hit cascading `503`s and then went to a blanket `404` across all endpoints — the AOS **recycled** under the load and was unavailable for a while afterward. A genuinely down/recycling environment returns `404` (or `503`) on *everything* including `/data/Companies` and `/data/` root, even with a valid token.

Mitigations confirmed 2026-06-04:
- **Low concurrency** (≤3–5 workers) for bulk writes; PROD tolerates 5, sandboxes prefer 3.
- **Retry with backoff** on `400`, `429`, `503`. Transient `400`s also appear under concurrency on `SecurityUserRoleAssociations` writes and succeed on a calm retry — they are not validation errors.
- **Never run side read-queries against an environment while a bulk write job is hitting it** — concurrent reads compound the throttling and can tip the env into a recycle.
- Run the bulk job **foreground or as a tracked background task**; a `Ctrl`-interrupt of the agent turn can kill an untracked background job mid-run, leaving a partial state (verify with a state-diff afterward, not by assuming completion).

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

The password prompt script is at `~/GitHub/api/d365/lcs-token.sh` — it prompts for the password without saving it to history.

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
