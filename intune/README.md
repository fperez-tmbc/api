# Intune Graph API — Lessons Learned

## Tooling

### `igraph` — use this for all Intune/Graph API tasks

The `igraph` CLI wrapper in this folder handles auth automatically using the `claude-m365`
certificate-based app registration. Use it instead of `az rest` or raw curl.

```bash
igraph /deviceManagement/deviceManagementScripts
igraph POST /deviceManagement/deviceManagementScripts '{"displayName":"..."}'
igraph /deviceManagement/managedDevices
```

**Note:** `igraph` targets `v1.0`. Intune device management scripts live on the `beta`
endpoint — pass the full URL override if needed, or edit the `GRAPH` constant temporarily.

**Do NOT pass `/beta/...` as the path to `igraph`.** The script strips the leading slash
then prepends `https://graph.microsoft.com/v1.0/`, producing a malformed URL like
`v1.0/beta/deviceManagement/...` which returns `BadRequest: Resource not found for the
segment 'beta'`. For beta endpoints, use an inline Python snippet that reuses `igraph`'s
`get_token()` auth but sets its own base URL:

```python
BETA = "https://graph.microsoft.com/beta"
# ... get_token() from igraph, then:
r = requests.get(f"{BETA}/deviceManagement/deviceManagementScripts", headers=headers)
```

### App registration: `claude-m365` (renamed from `claude-exo` 2026-07-20)

**Single consolidated app** for ALL Graph app-only + Exchange Online work — mail, Intune, Entra
(Conditional Access / MFA / groups), and App Proxy. The former `claude-intune` and `Claude Intune`
apps were folded in and hard-deleted on 2026-07-20 (registrations + SPs and their old
`.tokens/intune-graph` / `graph-intune` secret files removed). Do not create a separate Intune app — extend this one.

- **App ID:** `69de0375-242d-4b8a-94df-4e095ab81cea` (unchanged by the rename)
- **SP Object ID:** `176b0e4e-4237-4381-bc4e-cbad24852ab6`
- **Tenant:** `d5c15341-dfce-470a-bfdf-72c3dab91e7c` (themyersbriggs.com)
- **Auth:** Certificate — key/cert at `~/GitHub/.tokens/claude-m365/`
- **Current permissions (21 application roles, verified against the SP's `appRoleAssignments`
  2026-07-30):** `Mail.Read`, `Mail.ReadWrite`; `DeviceManagementApps.Read.All`,
  `DeviceManagementApps.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`,
  `DeviceManagementScripts.ReadWrite.All`, `DeviceManagementManagedDevices.Read.All`,
  `DeviceManagementServiceConfig.Read.All`, `DeviceLocalCredential.Read.All`;
  `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`,
  `Policy.ReadWrite.AuthenticationMethod`, `UserAuthenticationMethod.ReadWrite.All`, `User.Read.All`,
  `Group.ReadWrite.All`, `Application.Read.All`, `RoleManagement.ReadWrite.Directory`;
  `OnPremisesPublishingProfiles.ReadWrite.All`; `AuditLog.Read.All`;
  `SecurityIdentitiesSensors.ReadWrite.All` (added 2026-07-30). Plus Exchange: Recipient
  Management role group + Exchange Administrator role.

  **The app manifest (`requiredResourceAccess`) is NOT the source of truth** — it only declared
  10 of these. Always read the granted roles off the service principal:

  ```bash
  az rest --method GET --url \
    "https://graph.microsoft.com/v1.0/servicePrincipals/176b0e4e-4237-4381-bc4e-cbad24852ab6/appRoleAssignments"
  # then map appRoleId -> value via: az ad sp show --id 00000003-0000-0000-c000-000000000000 --query "appRoles"
  ```

If a task requires a permission not listed above, **add it to this app** rather than
creating a temporary app registration. See "Adding permissions" below.

---

## Gotchas

### Do NOT use `az` CLI for Intune operations

`az account get-access-token` and `az rest` use the Azure CLI first-party app
(`04b07795-8ddb-461a-bbee-02f9e1bf7b46`), which has a hard Microsoft restriction
(AADSTS65002) preventing it from obtaining `DeviceManagement*` scopes. This cannot
be worked around — use `igraph` or a dedicated app registration instead.

### `v1.0/mobileApps` SILENTLY OMITS `winGetApp` ("Microsoft Store app (new)")

The `v1.0` `/deviceAppManagement/mobileApps` collection does **not** return
`microsoft.graph.winGetApp` entities, and it drops `@odata.type` on
`macOsVppApp` entries. This is a silent omission — no error, the missing apps
just aren't in the list. It caused a wrong "no Windows 1Password app exists"
conclusion (2026-06-04) when the app was a Store/winget deployment all along.

**Always query `beta` for `mobileApps` when Store/winget apps may be involved.**
`igraph` is hardcoded to `v1.0` (see `GRAPH` const) — use an inline `beta` call
reusing `igraph`'s `get_token()` (SourceFileLoader to import it):

```python
import importlib.machinery, importlib.util, requests
loader=importlib.machinery.SourceFileLoader('igraph','/Users/fperez2nd/GitHub/api/intune/igraph')
ig=importlib.util.module_from_spec(importlib.util.spec_from_loader('igraph',loader)); loader.exec_module(ig)
H={"Authorization":f"Bearer {ig.get_token()}"}
requests.get("https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$top=999",headers=H)
```

### winGetApp ("Microsoft Store app (new)") — install behavior is IMMUTABLE

`installExperience.runAsAccount` (System vs User) is set at creation and cannot be
changed: PATCH returns `BadRequest: The property 'InstallExperience' cannot be patched`,
and there's no in-place edit in the portal either. To change it you must DELETE and
RECREATE the app, then re-add assignments. Done 2026-06-04 for 1Password (System→User):
current app id `401addb8-8687-4c13-b01f-583bc563cc2f`, packageIdentifier `9NZWS5X28P0J`,
Required → All Licensed Users, excluding "Windows Servers". (Recreating is also how you
"reset the stats" — a new app object starts with zero deployment history.)

### winGetApp must reach `publishingState=published` before /assign

A freshly POSTed winGetApp pulls Store metadata asynchronously. Calling `/assign`
immediately returns `BadRequest: app's PublishingState is not 'Published'`. Poll
`?$select=publishingState` until `published` (usually <30s), then assign.

### Delegated vs Application permission GUIDs are different

The same permission has two different GUIDs in the Graph SP depending on type:

| Permission | Type | GUID |
|---|---|---|
| `DeviceManagementScripts.ReadWrite.All` | Application (Role) | `9255e99d-faf5-445e-bbf7-cb71482737c4` |
| `DeviceManagementScripts.ReadWrite.All` | Delegated (Scope) | `8b9d79d0-ad75-4566-8619-f7500ecfcebe` |

For app-only (client credentials) auth, always use the **Role** GUID. Look up with:
```bash
az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='DeviceManagementScripts.ReadWrite.All'].id" -o tsv
```

### New app credentials take ~20 seconds to propagate

After `az ad app credential reset`, the secret is not immediately usable. Wait at
least 20 seconds before attempting a token request, or you'll get AADSTS7000215.

### Client secrets with special characters — avoid shell interpolation

Passing a client secret via shell variable interpolation into `curl -d` or `az login -p`
silently mangles special characters. Always write the credential to a temp file and
read it from Python:

```python
with open("/tmp/sp_cred.json") as f:
    cred = json.load(f)
client_secret = cred["password"]  # safe — no shell involved
```

### Accumulating credentials causes auth failures

Calling `az ad app credential reset --append` multiple times leaves multiple active
secrets. This doesn't directly block auth, but creates confusion about which secret
is current. Clean up with `az ad app credential list` and `az ad app credential delete`.

---

## Adding permissions to `claude-m365`

```bash
# 1. Look up the appRole GUID
az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='DeviceManagementScripts.ReadWrite.All'].id" -o tsv

# 2. Add to the app (append to existing resourceAccess array)
az ad app update --id 69de0375-242d-4b8a-94df-4e095ab81cea \
  --required-resource-accesses "[{\"resourceAppId\": \"00000003-0000-0000-c000-000000000000\", \
    \"resourceAccess\": [
      {\"id\": \"<existing-guid>\", \"type\": \"Role\"},
      {\"id\": \"<new-guid>\",      \"type\": \"Role\"}
    ]}]"

# 3. Grant admin consent
GRAPH_SP_ID=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
CLAUDE_SP_ID=$(az ad sp show --id 69de0375-242d-4b8a-94df-4e095ab81cea --query id -o tsv)

az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$CLAUDE_SP_ID/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$CLAUDE_SP_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"<new-guid>\"}"
```

---

## Defender for Identity (MDI) sensors — `v1.0/security/identities/sensors`

MDI sensor inventory and deletion are fully scriptable through `igraph` on `v1.0` (no portal
needed). Requires `SecurityIdentitiesSensors.ReadWrite.All` (granted 2026-07-30).

```bash
igraph /security/identities/sensors                    # list all
igraph /security/identities/sensors/{sensorId}          # detail
igraph DELETE /security/identities/sensors/{sensorId}   # returns HTTP 204 No Content
```

Useful fields on a sensor: `displayName` (short hostname, NOT FQDN), `deploymentStatus`
(`upToDate` / `disconnected`), `serviceStatus` (`running` / `unknown`), `openHealthIssuesCount`,
`healthStatus`, and `settings.domainControllerDnsNames[]` (the FQDN — match on this).

### Decommissioned a DC? Delete its sensor, or MDI alerts forever

A demoted/powered-off DC leaves an **orphaned sensor registration**. MDI keeps expecting
check-ins and re-fires a Medium *"Sensor stopped communicating"* health issue to the
notification recipients (`netops@themyersbriggs.com`) on a rolling ~7-day window —
indefinitely. The alert body carries the sensor FQDN and the last-communication timestamp,
which equals the moment the DC was powered off.

Signature of an orphan: `deploymentStatus=disconnected` + `serviceStatus=unknown`. (The portal
labels this status **Unreachable** and says it's safe to delete.) Deleting the sensor also
clears its open health issue.

Hit 2026-07-30 for `svdcau01.cpp-db.com` — demoted 2026-07-23, sensor never removed, so a
Medium alert fired on 07/21 and again on 07/30. **Add "delete the MDI sensor" to every DC
decommission checklist.** Microsoft's own guidance is to remove the sensor *before* demoting.

### Health issue detail needs a separate permission

`GET /security/identities/healthIssues` requires `SecurityIdentitiesHealth.Read.All`, which
this app does NOT hold — it returns a bare `UnknownError` (not a 403), so don't read that as
a malformed request. `openHealthIssuesCount` on the sensor object is available without it.

---

## Key Intune endpoints (beta)

```
GET  /beta/deviceManagement/deviceManagementScripts
POST /beta/deviceManagement/deviceManagementScripts
POST /beta/deviceManagement/deviceManagementScripts/{id}/assign
GET  /beta/deviceManagement/managedDevices
GET  /beta/deviceManagement/deviceCompliancePolicies
```

### Deploy a PowerShell script

```python
import base64, json

with open("script.ps1", "rb") as f:
    b64 = base64.b64encode(f.read()).decode()

payload = {
    "displayName": "My Script",
    "description": "...",
    "scriptContent": b64,
    "runAsAccount": "system",        # or "user"
    "enforceSignatureCheck": False,
    "fileName": "script.ps1",
    "runAs32Bit": False
}
# POST to /beta/deviceManagement/deviceManagementScripts
```

### Assign to All Devices

```json
{
  "deviceManagementScriptAssignments": [{
    "target": {
      "@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"
    }
  }]
}
```
