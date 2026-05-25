# Intune Graph API — Lessons Learned

## Tooling

### `igraph` — use this for all Intune/Graph API tasks

The `igraph` CLI wrapper in this folder handles auth automatically using the `claude-exo`
certificate-based app registration. Use it instead of `az rest` or raw curl.

```bash
igraph /deviceManagement/deviceManagementScripts
igraph POST /deviceManagement/deviceManagementScripts '{"displayName":"..."}'
igraph /deviceManagement/managedDevices
```

**Note:** `igraph` targets `v1.0`. Intune device management scripts live on the `beta`
endpoint — pass the full URL override if needed, or edit the `GRAPH` constant temporarily.

### App registration: `claude-exo`

- **App ID:** `69de0375-242d-4b8a-94df-4e095ab81cea`
- **Tenant:** `d5c15341-dfce-470a-bfdf-72c3dab91e7c` (themyersbriggs.com)
- **Auth:** Certificate — key/cert at `~/GitHub/.tokens/exo-claude/`
- **Current permissions (application):**
  - `Mail.ReadWrite`
  - `DeviceManagementConfiguration.ReadWrite.All`
  - `AuditLog.Read.All`
  - `DeviceManagementScripts.ReadWrite.All`

If a task requires a permission not listed above, **add it to this app** rather than
creating a temporary app registration. See "Adding permissions" below.

---

## Gotchas

### Do NOT use `az` CLI for Intune operations

`az account get-access-token` and `az rest` use the Azure CLI first-party app
(`04b07795-8ddb-461a-bbee-02f9e1bf7b46`), which has a hard Microsoft restriction
(AADSTS65002) preventing it from obtaining `DeviceManagement*` scopes. This cannot
be worked around — use `igraph` or a dedicated app registration instead.

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

## Adding permissions to `claude-exo`

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
