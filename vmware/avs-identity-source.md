# AVS vCenter — External Identity Source (CPP-DB)

Record of the LDAPS identity source binding AVS vCenter to `cpp-db.com`.
Reconfigured 2026-08-05 to widen both base DNs to the domain root.

## Private cloud

| Field | Value |
|-------|-------|
| Private cloud | `avs-tmbc-us` |
| Resource group | `rg-avs-us` |
| Subscription | `f3a21a2c-2b41-4c96-b758-8d4ee4556046` |
| vCenter | `vc.ed044990b4444c86b72971.eastus2.avs.azure.com` |

Break-glass local account, independent of AD, always works. Retrieve live, never store:

```bash
az vmware private-cloud list-admin-credentials \
  --private-cloud avs-tmbc-us --resource-group rg-avs-us \
  --subscription f3a21a2c-2b41-4c96-b758-8d4ee4556046
# -> vcenterUsername: cloudadmin@vsphere.local  (also nsxtUsername: cloudadmin)
```

## Current config (as of 2026-08-05)

```
Type                   : ActiveDirectory
AuthenticationType     : PASSWORD
AuthenticationUsername : svcldaplookup@cpp-db.com
FriendlyName           : CPP-DB
Name                   : cpp-db.com
PrimaryUrl             : ldaps://svdcdc01.cpp-db.com:636
FailoverUrl            : ldaps://svdcmk01.cpp-db.com:636
UserBaseDN             : DC=cpp-db,DC=com
GroupBaseDN            : DC=cpp-db,DC=com
```

Certificates: two, issued by `CN=CPP-SUB-CA, DC=cpp-db, DC=com`, valid until **2027-04-21**.
Thumbprints `E1D5653002C3279B4BF4F3B65F96FF2B566C2F24` and
`9EE3BDAC1E030B77D6363C4AB456AC6791D972B7`.

CloudAdmins nesting (`Get-CloudAdminGroups`): `cloudadmins-avs`, plus two stale 2024 leftovers
`avs_cloudadmins` and `avs cloudadmins` that no longer correspond to live AD groups. Harmless
but worth cleaning up with `Remove-GroupFromCloudAdmins`.

## The search-base gotcha (fixed 2026-08-05, keep for diagnosis)

Until 2026-08-05 both base DNs were `OU=TheMBC,DC=cpp-db,DC=com`. Any account in the default
`CN=Users,DC=cpp-db,DC=com` container was **invisible to vCenter**, regardless of group
membership.

Evidence at the time, via `New-VIPermission -WhatIf` as `cloudadmin@vsphere.local`:

| Principal | AD location | Before | After |
|---|---|---|---|
| `CPP-DB\2fperez` | `OU=Admin Accounts,OU=Users,OU=TheMBC` | resolves | resolves |
| `CPP-DB\svcbackup` | `OU=Service Accounts,OU=Users,OU=TheMBC` | resolves | resolves |
| `CPP-DB\CloudAdmins-AVS` | `OU=Security,OU=Groups,OU=TheMBC` | resolves | resolves |
| `CPP-DB\ntsupport` | `CN=Users,DC=cpp-db,DC=com` | **not found** | resolves |
| `CPP-DB\Domain Admins` | `CN=Users,DC=cpp-db,DC=com` | **not found** | resolves |

Symptom: `POST /api/session` returns `401 UNAUTHENTICATED` with an empty `messages` array, and
PowerCLI fails with `Could not find VIAccount with name '<DOMAIN>\<user>'`. It reads like a bad
password. It is not.

**Group membership does not rescue this.** vCenter resolves the *user* first; if that lookup
fails it never evaluates group nesting, so `CloudAdmins-AVS` membership is irrelevant.

Two traps that cost real time here:

- **NSX-T is configured separately** with its own LDAP config and base DN. An account working
  in NSX proves nothing about vCenter. Do not reason from one to the other.
- **Entra Connect sync is irrelevant.** vCenter binds LDAPS straight to the DCs. Syncing to
  Entra changes nothing about what vCenter can see.

## Diagnostic instruments — what works, what lies

- `New-VIPermission -WhatIf -Principal "CPP-DB\<name>"` is the **reliable** resolution test.
  Returns a specific `Could not find VIAccount` on failure.
- `UserDirectory.RetrieveUserGroups()` via `Get-View` returns **empty for every principal**,
  including known-good ones, when called as `cloudadmin`. It produces false negatives. Do not
  draw conclusions from it.
- An LDAP bind straight to a DC settles whether a password is valid, independent of vCenter:
  ```bash
  ldapsearch -x -H ldap://10.70.16.14 -D "<user>@cpp-db.com" -w "$PASS" \
    -b "DC=cpp-db,DC=com" "(sAMAccountName=<user>)" dn memberOf
  ```
  DCs: `svdcdc01` = 10.70.16.14, `svdcmk01` = 10.30.16.11. Both bind on 389 and 636.
  For LDAPS from macOS, `export LDAPTLS_REQCERT=never`.

## Change record — 2026-08-05

Goal: let `ntsupport@cpp-db.com` authenticate to vCenter, replacing the dead `svcclaude`.

1. **`Update-IdentitySourceCredential`** — moved the bind account from
   `2fperez@themyersbriggs.com` (Frank's personal admin account) to `svcldaplookup@cpp-db.com`.
   Non-destructive, zero outage. Also served to prove the `Credential` parameter shape before
   risking the destructive step. Do this first whenever the credential syntax is unproven.
2. **`Remove-ExternalIdentitySources -DomainName cpp-db.com`**
3. **`New-LDAPSIdentitySource`** with both base DNs at `DC=cpp-db,DC=com` and
   `GroupName=CloudAdmins-AVS` folded in.
4. Verified `ntsupport` REST auth (**201**, 210 VMs, 19 folders) and that all pre-existing
   CPP-DB permission entries survived intact.

Outage window: 21:31:26 to 21:33:34 PDT, about two minutes.

Pre-flight that made this safe: confirmed `svcldaplookup` binds on 389 and 636 to **both** DCs,
sees `CN=ntsupport,CN=Users` from a root-scoped search, still sees `OU=TheMBC` accounts, and
reads `CloudAdmins-AVS` membership (477 users / 1000+ groups domain-wide, so full directory
read rather than a scoped delegation). Verify all of that *before* removing anything.

### The folded `GroupName` failure is misleading

Step 3 returned:

```
ERROR: (400) Unable to add group to CloudAdmins. Error: Group 'CloudAdmins-AVS@cpp-db.com'
was not added to the target group. The Server operation result doesn't indicate success
```

**The identity source was created successfully anyway.** Only the group-add portion failed.
The automatic retry then correctly reported
`Already have an external identity source with the same name: cpp-db.com`.

The group-add failed because `cloudadmins-avs` was **already** nested in
`vsphere.local\CloudAdmins` — that nesting survives `Remove-ExternalIdentitySources`. So a
folded `GroupName` on a *re-add* will generally fail, harmlessly.

Do not trust the exit code. **Always run `Get-ExternalIdentitySources` to see actual state
before retrying**, or you will conclude the source is missing when it is fine. This matches
the 2024-11-12 history, where the only folded attempt was also the only failed one.

## Run command history

`az vmware script-execution list`, identity-related entries only:

| Date | Cmdlet | Key params | Result |
|---|---|---|---|
| 2024-09-08 | `New-LDAPSIdentitySource` | Users `DC=cpp-db,DC=com`, Groups `OU=Security,OU=CPP Groups,...`, Group `AVS CloudAdmins` | Succeeded |
| 2024-09-08 | `Update-IdentitySourceCertificates` | `cpp-db.com` | Succeeded |
| 2024-11-12 | `Remove-GroupFromCloudAdmins` | `AVS CloudAdmins` | Failed |
| 2024-11-12 | `Remove-ExternalIdentitySources` | (all) | Succeeded |
| 2024-11-12 | `New-LDAPSIdentitySource` | Group `AVS_CloudAdmins` folded in | **Failed** |
| 2024-11-12 | `Remove-GroupFromCloudAdmins` | `AVS CloudAdmins` | Succeeded |
| 2024-11-12 | `Add-GroupToCloudAdmins` | `AVS CloudAdmins` | Succeeded |
| 2025-05-27 | `New-LDAPSIdentitySource` | base DNs **narrowed** to `OU=TheMBC,...`, failover → `svdcmk01` | Succeeded |
| 2025-05-27 | `Add-GroupToCloudAdmins` | `AVS_CloudAdmins` | Succeeded |
| 2025-06-03 | `Remove-ExternalIdentitySources` | `cpp-db.com` | Succeeded |
| 2025-06-03 | `New-LDAPSIdentitySource` | base DNs `OU=TheMBC,...`, bind `svcldaplookup` | Succeeded |
| 2025-06-03 | `Add-GroupToCloudAdmins` | `CloudAdmins-AVS` | Succeeded |
| 2026-08-05 | `Update-IdentitySourceCredential` | bind → `svcldaplookup@cpp-db.com` | Succeeded |
| 2026-08-05 | `Remove-ExternalIdentitySources` | `cpp-db.com` | Succeeded |
| 2026-08-05 | `New-LDAPSIdentitySource` | base DNs **→ `DC=cpp-db,DC=com`** | source created (group-add errored) |

> **The history is incomplete.** Executions expire per their `--retention` (default 60 days).
> Between 2025-06-03 and 2026-08-05 the bind account changed to `2fperez@themyersbriggs.com`
> and the certs were renewed (2026-04-21), but no such runs appear in the list. Treat
> `Get-ExternalIdentitySources` as the only authority on current state, never the history.

The base DN was root at first, narrowed to `OU=TheMBC` on 2025-05-27, and returned to root on
2026-08-05.

Package versions shift. The 2025 runs used `Microsoft.AVS.Management@7.0.175`; as of
2026-08-05 the identity cmdlets live in **`Microsoft.AVS.Identity@1.1.524`** and
`Microsoft.AVS.Management` is at `9.0.246`. Re-list before building a run:

```bash
az vmware script-package list --private-cloud avs-tmbc-us --resource-group rg-avs-us \
  --subscription f3a21a2c-2b41-4c96-b758-8d4ee4556046 -o table
```

## `New-LDAPSIdentitySource` parameters (Microsoft.AVS.Identity@1.1.524)

| Parameter | Type | Required |
|---|---|---|
| `Name` | String | yes |
| `DomainName` | String | yes |
| `DomainAlias` | String | yes |
| `PrimaryUrl` | String | yes |
| `SecondaryUrl` | String | no |
| `BaseDNUsers` | String | yes |
| `BaseDNGroups` | String | yes |
| `Credential` | Credential | yes |
| `SSLCertificatesSasUrl` | SecureString | **no** |
| `GroupName` | String | no |

`SSLCertificatesSasUrl` is optional: *"The certs will be installed from domain controllers if
not specified."* No blob storage staging or SAS minting required.

There is **no cmdlet to edit a base DN in place**. Changing it means
`Remove-ExternalIdentitySources` then `New-LDAPSIdentitySource`. Available identity cmdlets:
`Add-GroupToCloudAdmins`, `Debug-LDAPSIdentitySources`, `Get-ExternalIdentitySources`,
`New-LDAPIdentitySource`, `New-LDAPSIdentitySource`, `Remove-AVSIdentityProviderEntraId`,
`Remove-ExternalIdentitySources`, `Remove-GroupFromCloudAdmins`,
`Update-IdentitySourceCertificates`, `Update-IdentitySourceCredential`.

`Update-IdentitySourceCredential` rotates the bind account with no outage.

## Blast radius of a remove/re-add

`Remove-ExternalIdentitySources` drops AD auth for **every** CPP-DB principal. Accounts holding
vCenter permissions as of 2026-08-05:

| Principal | Entries | Note |
|---|---|---|
| `svcbackup` | 4 | CloudAdmin on SDDC-Datacenter — **Veeam** |
| `svaradaraj` | 5 | VDI power control |
| `svcrapid7` | 3 | |
| `svcdecommission` | 3 | |
| `hjafri` | 3 | |
| `svcclaude` | 3 | baseline ReadOnly only, dormant |

These are stored by principal and **survive** a remove/re-add with the same domain name, as
confirmed 2026-08-05 (counts identical before and after). `cloudadmin@vsphere.local` is
unaffected throughout and is the way back in.

Pick a window when Veeam is idle.

## Running a cmdlet from the CLI

`--script-cmdlet-id` must be a **fully qualified resource ID**. A bare cmdlet name fails with
`LinkedInvalidPropertyId`. There is no `--no-wait` on this command. Add `--yes` to skip the
confirmation prompt.

```bash
SUB=f3a21a2c-2b41-4c96-b758-8d4ee4556046
BASE="/subscriptions/$SUB/resourceGroups/rg-avs-us/providers/Microsoft.AVS/privateClouds/avs-tmbc-us/scriptPackages/Microsoft.AVS.Identity@1.1.524/scriptCmdlets"

az vmware script-execution create \
  --name "getids-$(date +%s)" \
  --private-cloud avs-tmbc-us --resource-group rg-avs-us --subscription "$SUB" \
  --script-cmdlet-id "$BASE/Get-ExternalIdentitySources" \
  --timeout PT10M --retention P1D --yes
```

Credential parameters go in as `--hidden-parameter`, not `--parameter`:

```bash
  --parameter name=DomainName type=Value value=cpp-db.com \
  --hidden-parameter name=Credential type=Credential \
      username=svcldaplookup@cpp-db.com password="$PW"
```

Values containing commas must have the whole token quoted:
`--parameter name=BaseDNUsers type=Value "value=DC=cpp-db,DC=com"`.

Read results with `az vmware script-execution show --name <name> ...` and inspect the `output`
array. **A run whose CLI call appeared to error may still have landed** — check
`script-execution list` before re-running.

## Accounts

| Account | Role | Password |
|---|---|---|
| `ntsupport@cpp-db.com` | vCenter automation, CloudAdmin via `CloudAdmins-AVS` | Key Vault `da-cpp-db-com` |
| `svcldaplookup@cpp-db.com` | LDAPS bind for the identity source | `~/GitHub/.tokens/svcldaplookup` |
| `cloudadmin@vsphere.local` | break-glass, local SSO | `az vmware private-cloud list-admin-credentials` |

`svcldaplookup` is `CN=svcldaplookup,OU=Service Accounts,OU=Users,OU=TheMBC`, enabled, password
never expires (`userAccountControl` 66048).
