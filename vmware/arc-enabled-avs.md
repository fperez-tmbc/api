# Arc-enabled AVS — credential rotation and management

Arc-enabled Azure VMware Solution for the `avs-tmbc-us` private cloud. Written 2026-08-05 after
rotating the AVS `cloudadmin` credential.

## Resources

| Resource | Name | Type |
|---|---|---|
| Private cloud | `avs-tmbc-us` | `Microsoft.AVS/privateClouds` |
| Resource bridge | `avs-tmbc-us-resource-bridge` | `Microsoft.ResourceConnector/appliances` |
| Custom location | `avs-tmbc-us-custom-location` | `Microsoft.ExtendedLocation/customLocations` |
| Connected vCenter | `avs-tmbc-us-vcenter` | `Microsoft.ConnectedVMwarevSphere/VCenters` |
| Management VM | `avsmgmt01` | Windows Server 2022, **deallocated since 2025-08-10** |

Resource group `rg-avs-us`, subscription `f3a21a2c-2b41-4c96-b758-8d4ee4556046`, region `eastus2`.

| Endpoint | Value |
|---|---|
| vCenter (Arc `fqdn`) | `10.200.4.2:443` |
| Bridge cluster config | `https://10.200.7.66:6443` |
| Arc account | `cloudadmin@vsphere.local` |

Both endpoints are reachable from a Mac over GlobalProtect (`utun6`). Verified 2026-08-05.

## Rotating the cloudadmin credential

After `az vmware private-cloud rotate-vcenter-password`, **two separate credential stores** must
be updated. They are not a retry of each other.

| Store | Command | Breaks without it |
|---|---|---|
| Arc resource bridge | `az arcappliance update-infracredentials vmware` | bridge → vCenter, upgrades, log collection |
| VMware cluster extension | `az connectedvmware vcenter connect` | VM inventory discovery, guest ops |

### You do NOT need the management VM

The AVS doc says to sign in to "the Management VM from where the onboard process was performed."
That is not a real requirement. The Arc vSphere admin doc is accurate: run it "from a workstation
that can access the cluster configuration IP address of the Arc resource bridge locally."

What actually matters:

1. Network path to the bridge cluster config IP (`10.200.7.66:6443`)
2. A kubeconfig — regenerate anywhere, see below
3. `az` extensions `arcappliance` and `connectedvmware`

The `.temp\.env` virtualenv the doc references is just how the AVS onboarding script installed
Azure CLI on `avsmgmt01`. Nothing lives there that can't be recreated. `avsmgmt01` has been
deallocated since 2025-08-10 and was **not** started for the 2026-08-05 rotation.

### Getting the kubeconfig

Stored at `~/GitHub/.tokens/arc-rb-kubeconfig/` (dir 700, files 600). Regenerate any time:

```bash
az arcappliance get-credentials -n avs-tmbc-us-resource-bridge -g rg-avs-us \
  --credentials-dir ~/GitHub/.tokens/arc-rb-kubeconfig
```

This also writes `managementlogkey` and `managementlogkey-cert.pub`. Keep all of it — the docs
require kubeconfig and SSH keys for upgrades, log collection and future credential rotations.
Before 2026-08-05 the only copy lived on a VM that had been off for a year.

### The procedure

```bash
SUB=f3a21a2c-2b41-4c96-b758-8d4ee4556046
KC=~/GitHub/.tokens/arc-rb-kubeconfig/kubeconfig

# retrieve into a variable, never echo, never write to disk
PW=$(az vmware private-cloud list-admin-credentials --private-cloud avs-tmbc-us \
      --resource-group rg-avs-us --subscription "$SUB" --query vcenterPassword -o tsv)

# 1) resource bridge  (az arcappliance has NO --subscription flag, see gotchas)
az account set -s "$SUB"
az arcappliance update-infracredentials vmware \
  --kubeconfig "$KC" --address 10.200.4.2 \
  --username cloudadmin@vsphere.local --password "$PW" --skipWait

# 2) cluster extension
az connectedvmware vcenter connect \
  --resource-group rg-avs-us --name avs-tmbc-us-vcenter --location eastus2 \
  --custom-location avs-tmbc-us-custom-location \
  --fqdn 10.200.4.2 --port 443 \
  --username cloudadmin@vsphere.local --password "$PW" --subscription "$SUB"

unset PW
```

Verify:

```bash
az resource show -g rg-avs-us -n avs-tmbc-us-vcenter --subscription "$SUB" \
  --resource-type Microsoft.ConnectedVMwarevSphere/VCenters \
  --query "properties.{conn:connectionStatus, prov:provisioningState}"
# expect: Connected / Succeeded, with statuses Connected+Ready+Idle
```

## Gotchas

**Drop `--debug` from the Microsoft doc's step 4.** The AVS page shows
`az connectedvmware vcenter connect --debug ...`. That flag dumps the full request body,
password included, into stdout. Omit it unless actually debugging, and never when the output is
being captured or transcribed.

**`az arcappliance` has no `--subscription` flag.** It uses the CLI default. If your default is
another subscription you get a misleading error that looks like a tenant misconfiguration:

```
ERROR: Microsoft.ResourceConnector provider is not registered.
Run `az provider register -n Microsoft.ResourceConnector --wait`.
```

The provider is registered — you are simply pointed at the wrong subscription. Run
`az account set -s <avs-sub>` first, and restore the previous default afterward. Do **not**
register the provider in the wrong subscription chasing this.

**Use `--skipWait` when rotating reactively.** Once the vCenter password changes, the bridge
keeps retrying with the stale one and can lock out `cloudadmin`. `--skipWait` applies the update
without waiting for a validation window. Per the Arc troubleshooting guide this is the
recommended path when you are already past the rotation.

**"Connected" is not proof the credential is current.** Immediately after a rotation the Arc
vCenter resource still reported `connectionStatus: Connected` on a cached session, while the
bridge was already failing to re-auth underneath. Do not treat it as an all-clear.

**`debug_infra.yaml`** is written into the credentials dir by `update-infracredentials`. Its
`password:` field contains the literal string `REDACTED`, not the real secret. Harmless, but it
lands at mode 644 — tighten it.

## Related

- Identity source, vCenter accounts, break-glass: `avs-identity-source.md`
- REST API and PowerCLI usage: `README.md`
