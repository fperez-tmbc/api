# vSphere REST API — AVS vCenter Field Notes

> ## Account: `ntsupport@cpp-db.com` (changed 2026-08-05)
>
> `svcclaude` is **dead for vCenter**, but **not in the way this note used to say.**
> Corrected 2026-08-10 by live test:
>
> - **It still authenticates.** `Connect-VIServer` with the password in
>   `~/GitHub/.tokens/svcclaude` **succeeds** and reports `CPP-DB\svcclaude`. The earlier
>   "password rotated, so it fails" framing is wrong for vCenter — the token file holds the
>   rotated value and vCenter accepts it.
> - **It holds no role.** `Get-VIPermission | Where Principal -match 'svcclaude'` returns
>   **nothing** — not "baseline ReadOnly", nothing. It can read a little inventory
>   (`Get-Datacenter` returns), but `HasPrivilegeOnEntity` throws
>   `Permission to perform this operation was denied`.
> - **So a successful login proves nothing.** Writes fail *after* a clean connect, which
>   makes scripts print their progress lines and reach "Done." having changed nothing.
>   That is what left `SVSQLMISMK01` half decommissioned.
>
> Do not use it for vCenter and do not treat a successful connect as a green light. It still
> works as a **PAN-OS local account** (firewalls have their own user database, key auth
> verified 2026-08-02 on AVSPAN01/WHPAN01) — that is unrelated.
>
> Password lives in Azure Key Vault, not on disk: `~/GitHub/.tokens/kv-get.sh da-cpp-db-com`.
>
> Rights come from AD group `CloudAdmins-AVS`, nested into `vsphere.local\CloudAdmins`
> (role `CloudAdmin`). There is **no per-user permission entry** for `ntsupport`, by design —
> so `Get-VIPermission` is useless as a rights test here: it returns nothing for the *good*
> account too. To test rights, ask vCenter for effective privilege:
> `$am.HasPrivilegeOnEntity($dc.ExtensionData.MoRef, $sm.CurrentSession.Key, @('VirtualMachine.Config.Rename'))`.
> Note it takes the **session key**, not a username. `Get-VIPrivilege` has no `-Entity`
> parameter, and `FetchUserPrivilegeOnEntities` fails to marshal a one-element array from
> PowerCLI (`Required parameter entities is missing`). Working implementation:
> `task-tracker/projects/decomm-vm-infra/avs-evacuation/scripts/vcenter.ps1`.
>
> Full identity-source detail, run-command history and blast radius: **`avs-identity-source.md`**.

## Connection

| Field | Value |
|-------|-------|
| vCenter host | `vc.ed044990b4444c86b72971.eastus2.avs.azure.com` |
| Account | `ntsupport@cpp-db.com` |
| Password | Key Vault secret `da-cpp-db-com` via `~/GitHub/.tokens/kv-get.sh` |
| Base URL | `https://vc.ed044990b4444c86b72971.eastus2.avs.azure.com/api` |
| Break-glass | `cloudadmin@vsphere.local`, see below |

## Authentication

Session tokens are the only supported method. Obtain once per session; no expiry header is documented but treat as short-lived (re-auth if you get a 401). A successful auth returns **201**.

```bash
VC=vc.ed044990b4444c86b72971.eastus2.avs.azure.com
USER=ntsupport@cpp-db.com
PASS=$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com)
TOKEN=$(curl -sk -X POST "https://$VC/api/session" \
  -u "${USER}:${PASS}" \
  -H "Content-Type: application/json" | tr -d '"')
```

### Break-glass — `cloudadmin@vsphere.local`

Local SSO account, independent of AD. Use it when the identity source is broken or mid-change.
Retrieve live, never store:

```bash
az vmware private-cloud list-admin-credentials \
  --private-cloud avs-tmbc-us --resource-group rg-avs-us \
  --subscription f3a21a2c-2b41-4c96-b758-8d4ee4556046
```

### A 401 usually means "not visible", not "wrong password"

`401 UNAUTHENTICATED` with an empty `messages` array — or PowerCLI
`Could not find VIAccount with name '<DOMAIN>\<user>'` — normally means the account sits
**outside the identity source's base DN**, so vCenter cannot see it at all. Group membership
does not help: the user lookup happens first, so `CloudAdmins-AVS` membership is never
evaluated.

Both base DNs are `DC=cpp-db,DC=com` as of 2026-08-05. Before that they were
`OU=TheMBC,DC=cpp-db,DC=com`, which hid every account in the default `CN=Users` container,
`ntsupport` among them. See `avs-identity-source.md` before touching any credential.

NSX-T has a separate LDAP config with a different base DN. An account working in NSX proves
nothing about vCenter.

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
- **Disk resize:** REST API `PATCH /hardware/disk/{id}` does not support `capacity` or any capacity field — the `update_spec` has no capacity field at all. Use PowerCLI `Set-HardDisk -CapacityGB` instead. Requires `VirtualMachine.Config.DiskExtend` privilege on the VM.
- **Cannot extend a disk while a snapshot exists** — vCenter blocks `Set-HardDisk -CapacityGB` if the VM has any snapshot. Check `Get-Snapshot -VM $vm` is empty first; never take a "safety" snapshot *before* an extend. Any rollback snapshot must come *after* the extend.
- **Growing C: is usually blocked by the WinRE recovery partition** sitting at the end of the disk, right after C: — new VMDK space lands behind it and C: can't extend (`Get-PartitionSupportedSize -DriveLetter C` shows `SizeMax` == current size even after the grow). Fix = grow the VMDK, then relocate the recovery partition. Full end-to-end procedure: `knowledge-base/procedures/vm-disk-expand-winre-relocation.md` (reference script `knowledge-base/scripts/Expand-RecoveryPartition.ps1`).
- **Guest process execution:** `POST /api/vcenter/vm/{vm}/guest/processes` returns 404 on AVS — guest operations API is not available. Use SSH (port 22 — OpenSSH enabled on domain-joined Windows Server VMs) or WinRM (port 5985) instead. SSH with UPN format: `sshpass -p "$PASS" ssh "ntsupport@cpp-db.com@<ip>"`.
- **Windows disk → vSphere disk mapping:** Windows Disk N corresponds to vSphere SCSI 0:N (disk ID 200N). Disk 0 = C: (OS), subsequent disks follow SCSI unit order. Verify via SSH: `Get-Partition | Where-Object {$_.DriveLetter} | Select-Object DiskNumber, DriveLetter`.
- **Windows partition extension after disk resize:** After growing the VMDK, SSH in and run `Resize-Partition -DiskNumber N -PartitionNumber N -Size (Get-PartitionSupportedSize ...).SizeMax` to extend the NTFS partition.
- **Reading guest files when RDP/WinRM/SSH are all closed:** a freshly-deployed Windows guest often has only SMB (445) open. Mount its `C$` admin share from macOS with local creds and read logs directly — no jumpbox needed: `mount_smbfs -N "//administrator:<urlenc-pass>@<ip>/C$" <mountpoint>` (URL-encode the password, e.g. `,`→`%2C`, `$`→`%24`). Unmount with `umount`.
- **Diagnosing failed guest OS customization:** `CustomizationSucceeded` in vCenter events only means the customization *engine* finished — it does NOT mean an in-spec domain join worked. Read specs with `GET /api/vcenter/guest/customization-specs/<name>` (needs `VirtualMachine.Provisioning.ReadCustSpecs`). In-guest evidence, via the `C$` mount above: `C:\WINDOWS\TEMP\vmware-imc\guestcust.log` (engine: NIC/DHCP/sysprep) and the authority for domain-join results, `C:\Windows\debug\NetSetup.LOG`. Join error `0x533` = `ERROR_ACCOUNT_DISABLED` — the spec's join account (`svcadjoin@cpp-db.com`) was disabled; see memory `reference-svcadjoin-domain-join`.

## Role & Permission Management

`ntsupport` holds the `CloudAdmin` role through `CloudAdmins-AVS`, so real privilege gaps are
rare. A denial is more often a stale session token or a resolution problem — work the 401
section above first.

### How access is actually granted

There is **no per-user permission entry** for `ntsupport`. Rights flow:

```
CPP-DB\ntsupport  ->  CPP-DB\CloudAdmins-AVS  ->  vsphere.local\CloudAdmins  ->  CloudAdmin role
```

Verify the AD half without touching vCenter:

```bash
PASS=$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com)
ldapsearch -x -H ldap://10.70.16.14 -D "ntsupport@cpp-db.com" -w "$PASS" \
  -b "DC=cpp-db,DC=com" "(cn=CloudAdmins-AVS)" member
```

Verify the vCenter half with an AVS run command (`Get-CloudAdminGroups`), see
`avs-identity-source.md`.

### `TMBC - Automation Access` is dormant

The role still exists with 35 privileges (power ops, `Config.DiskExtend`, `Config.Rename`,
snapshots, `Inventory.Move`, `Provisioning.ReadCustSpecs`; no clone/deploy) but as of
2026-08-05 it is assigned to **nobody** — `svcclaude`'s assignment was removed. Do not assume
it is in play when reasoning about effective rights.

```powershell
$role = Get-VIRole -Name "TMBC - Automation Access"
$role.PrivilegeList | Sort-Object
Get-VIPermission | Where-Object { $_.Role -like "TMBC*" }   # who actually holds TMBC roles
```

Adding a privilege to a shared role widens access for everything using it. Confirm with Frank
first. Role changes take effect immediately; no restart or re-login needed.

## PowerCLI Fallback

Use PowerCLI for operations the REST API does not expose (rename, move to folder/resource pool, disk resize):

```powershell
$pw = & "$HOME/GitHub/.tokens/kv-get.sh" da-cpp-db-com
Connect-VIServer -Server "vc.ed044990b4444c86b72971.eastus2.avs.azure.com" `
    -User "ntsupport@cpp-db.com" -Password $pw -Force | Out-Null

# Rename
Set-VM -VM (Get-VM -Name "<name>") -Name "<new name>" -Confirm:$false

# Move to folder
Move-VM -VM (Get-VM -Name "<name>") -InventoryLocation (Get-Folder "Unused") | Out-Null

# Move to resource pool
Move-VM -VM (Get-VM -Name "<name>") -Destination (Get-ResourcePool "Unused") | Out-Null

Disconnect-VIServer -Confirm:$false
```

PowerCLI must be installed: `Install-Module VMware.PowerCLI -Scope CurrentUser`
