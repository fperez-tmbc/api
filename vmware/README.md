# vSphere REST API — AVS vCenter Field Notes

## Connection

| Field | Value |
|-------|-------|
| vCenter host | `vc.ed044990b4444c86b72971.eastus2.avs.azure.com` |
| Credentials | `~/GitHub/.tokens/svcclaude` (key=value: `USERNAME` / `PASSWORD`) |
| Base URL | `https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api` |

## Authentication

Session tokens are the only supported method. Obtain once per session; no expiry header is documented but treat as short-lived (re-auth if you get a 401).

```bash
USER=$(grep '^USERNAME' ~/GitHub/.tokens/svcclaude | cut -d= -f2)
PASS=$(grep '^PASSWORD' ~/GitHub/.tokens/svcclaude | cut -d= -f2)
TOKEN=$(curl -sk -X POST \
  "https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api/session" \
  -u "${USER}:${PASS}" \
  -H "Content-Type: application/json" | tr -d '"')
```

Use the token on every subsequent request:

```bash
curl -sk -H "vmware-api-session-id: $TOKEN" \
  "https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api/..."
```

Delete the session when done:

```bash
curl -sk -X DELETE \
  -H "vmware-api-session-id: $TOKEN" \
  "https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api/session"
```

## Name → ID Resolution

The REST API identifies VMs by internal ID (e.g. `vm-123`), not by display name. Always list first and filter:

```bash
VM_ID=$(curl -sk -H "vmware-api-session-id: $TOKEN" \
  "https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api/vcenter/vm" \
  | python3 -c "import sys,json; vms=json.load(sys.stdin); \
    match=[v['vm'] for v in vms if v['name']=='<VM_NAME>']; \
    print(match[0] if match else 'not found')")
```

Folder and resource pool lookups follow the same pattern — list, then match by `name`.

## Key Endpoints

### VMs

| Operation | Method + Path |
|-----------|--------------|
| List all VMs | `GET /api/vcenter/vm` |
| VM summary | `GET /api/vcenter/vm/{vm}` |
| Filter by name | `GET /api/vcenter/vm?names=<NAME>` |
| Filter by folder | `GET /api/vcenter/vm?folders=<folder_id>` |
| Filter by resource pool | `GET /api/vcenter/vm?resource_pools=<rp_id>` |

### Power

| Operation | Method + Path |
|-----------|--------------|
| Get power state | `GET /api/vcenter/vm/{vm}/power` |
| Power on | `POST /api/vcenter/vm/{vm}/power?action=start` |
| Power off (hard) | `POST /api/vcenter/vm/{vm}/power?action=stop` |
| Reset | `POST /api/vcenter/vm/{vm}/power?action=reset` |
| Guest shutdown (graceful) | `POST /api/vcenter/vm/{vm}/guest/power?action=shutdown` |
| Guest reboot (graceful) | `POST /api/vcenter/vm/{vm}/guest/power?action=reboot` |

Guest power operations require VMware Tools to be running in the VM.

### Inventory

| Operation | Method + Path |
|-----------|--------------|
| List folders | `GET /api/vcenter/folder` |
| List resource pools | `GET /api/vcenter/resource-pool` |
| List hosts | `GET /api/vcenter/host` |
| List datastores | `GET /api/vcenter/datastore` |
| List networks | `GET /api/vcenter/network` |

### VM Config (read-only queries)

| Operation | Method + Path |
|-----------|--------------|
| CPU / memory | `GET /api/vcenter/vm/{vm}/hardware` |
| Guest info (OS, IP, hostname) | `GET /api/vcenter/vm/{vm}/guest/identity` |
| Network interfaces | `GET /api/vcenter/vm/{vm}/guest/networking/interfaces` |
| Disk info | `GET /api/vcenter/vm/{vm}/hardware/disk` |

## Notes

- **Filter params beat post-processing:** use `?names=`, `?folders=`, `?power_states=POWERED_ON` etc. to narrow list results server-side rather than piping through jq/python.
- **Rename / move to folder:** not exposed in the Automation API — use PowerCLI (`Set-VM`, `Move-VM`) for these operations.
- **Resource pool assignment:** similarly not available via REST; use PowerCLI.
- **Guest power requires VMware Tools:** if Tools is not running, fall back to hard `stop`/`start`.

## PowerCLI Fallback

Use PowerCLI for operations the REST API does not expose (rename, move to folder/resource pool):

```powershell
$creds = Get-Content (Join-Path $HOME "GitHub/.tokens/svcclaude") | ConvertFrom-StringData
Connect-VIServer -Server "vc.ed044990b4444c86b72971.eastus2.avs.azure.com" `
    -User $creds.USERNAME -Password $creds.PASSWORD -Force | Out-Null

# Rename
Set-VM -VM (Get-VM -Name "<name>") -Name "<new name>" -Confirm:$false

# Move to folder
Move-VM -VM (Get-VM -Name "<name>") -InventoryLocation (Get-Folder "Unused") | Out-Null

# Move to resource pool
Move-VM -VM (Get-VM -Name "<name>") -Destination (Get-ResourcePool "Unused") | Out-Null

Disconnect-VIServer -Confirm:$false
```

PowerCLI must be installed: `Install-Module VMware.PowerCLI -Scope CurrentUser`
