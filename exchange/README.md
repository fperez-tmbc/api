# Exchange Online API Notes


> ## WARNING: `svcclaude`'s AD rights were dismantled 2026-07-27
>
> The account was **not deleted everywhere** — the picture is mixed, so read carefully:
>
> | Where | State |
> |---|---|
> | `cpp-db.com` | **Exists, but powerless** — zero group memberships, zero delegated ACEs, removed from local Administrators on ~26 machines. Retained *only* so vCenter and the PAN firewalls can authenticate it. |
> | `cpp-web.com`, `opp.local`, `oppashapp.local`, `oppnewapp.local` | **Deleted outright.** |
> | PAN-OS local account | ✅ **Still works** — firewalls have their own user database. Key auth verified 2026-08-02 (AVSPAN01, WHPAN01). |
> | vCenter login | Retained by design — but see the password note below. |
>
> **Its password was rotated 2026-07-27**, so `~/GitHub/.tokens/svcclaude` holds a stale value.
> That is why auth fails with `Permission denied` / `The user name or password is incorrect` —
> it reads like a simple bad password, but the rights are gone too. **Do not retry it or burn
> lockout budget on it.**
>
> **Use instead:**
> - **WinRM as `CPP-DB\2fperez`** — `Invoke-Command -ComputerName <fqdn> -ScriptBlock {...}`.
>   `2fperez` is a Domain Admin in cpp-db.com. The proven day-to-day path.
> - **Azure Key Vault `kv-tmbc-secrets`** — `~/GitHub/.tokens/kv-get.sh <secret>`. Account names
>   live in each secret's Azure **tags**. DA per domain: `ntsupport` (cpp-db.com, cpp-web.com),
>   `#domain` (opp.local, oppashapp.local, oppnewapp.local).
>
> The transport-level patterns below (sshpass on Windows, `-EncodedCommand`, NetBIOS-vs-UPN,
> loopback workarounds) remain correct — substitute a live account in the examples.
> Full detail: `api/ssh/README.md`.

## macOS gotcha: pin `ExchangeOnlineManagement` to 3.9.2

`ExchangeOnlineManagement` **3.10.0** throws on every REST cmdlet:
`Method invocation failed because [System.Net.Http.HttpResponseMessage] does not
contain a method named 'GetResponseHeader'`. Auth succeeds, then every cmdlet fails.

**3.9.2 works fully.** Verified 2026-08-03 on pwsh 7.6.0 with app-only cert auth:
`Connect-ExchangeOnline` followed by `Get-Mailbox` returned live data. So this is a
**module-version** bug, not the blanket macOS platform bug previously recorded here.
Both versions are installed and **3.10.0 loads by default**, so always pin:

```powershell
Import-Module ExchangeOnlineManagement -RequiredVersion 3.9.2 -Force
```

(The Windows VM `vmnofrankp71` connects but its network path returns `417
Expectation Failed`, intermittently breaking the module there too.)

**Alternative — hit the EXO admin REST API directly from Python.** Still useful when
you want clean JSON instead of the module's CLIXML, but no longer required to work
around the module. Get an app-only token with the `claude-m365` cert via MSAL, then
POST `InvokeCommand`:

```python
import json, msal, requests
cfg = json.load(open("~/GitHub/.tokens/claude-m365/config.json".replace("~", __import__("os").path.expanduser("~"))))
app = msal.ConfidentialClientApplication(
    cfg["appId"], authority=f"https://login.microsoftonline.com/{cfg['tenantId']}",
    client_credential={"private_key": open(cfg["certPem"].replace("cert.pem","key.pem")).read(),
                       "thumbprint": cfg["thumbprint"],
                       "public_certificate": open(cfg["certPem"]).read()})
tok = app.acquire_token_for_client(["https://outlook.office365.com/.default"])["access_token"]

def invoke(cmdlet, params):
    r = requests.post(f"https://outlook.office365.com/adminapi/beta/{cfg['tenantId']}/InvokeCommand",
                      headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
                      json={"CmdletInput": {"CmdletName": cmdlet, "Parameters": params}}, timeout=60)
    return r.status_code, r.json()
# e.g. invoke("Get-DistributionGroupMember", {"Identity": "grp@themyersbriggs.com"})
#      invoke("New-ApplicationAccessPolicy", {"AppId": "...", "PolicyScopeGroupId": "...", "AccessRight": "RestrictAccess"})
```

Response is clean JSON (`{"value": [...]}`), far easier than the module's CLIXML.
Note: **Application Access Policies take up to ~30 min (sometimes ~1 hr) to take
effect on actual mail sending**, even after `Test-ApplicationAccessPolicy` returns
`Granted`. A 403 `[RAOP] Blocked by tenant configured AppOnly AccessPolicy` right
after creating a policy is propagation lag, not misconfiguration.

## Exchange Online PowerShell — Unattended / App-Only Auth

Basic auth and user-delegated auth are not viable on macOS for non-interactive use. App-only auth via a registered Entra app + certificate is the correct approach.

### App Registration

| Field | Value |
|---|---|
| App name | `claude-m365` (renamed from `claude-exo` 2026-07-20; now the single consolidated Graph + EXO app for the tenant) |
| App ID | `69de0375-242d-4b8a-94df-4e095ab81cea` |
| SP Object ID | `176b0e4e-4237-4381-bc4e-cbad24852ab6` |
| Tenant | `d5c15341-dfce-470a-bfdf-72c3dab91e7c` (themyersbriggs.com) |
| API permission | `Office 365 Exchange Online → Exchange.ManageAsApp` (application) |
| Exchange role group | `Recipient Management` (on-prem registration via `New-ServicePrincipal`) |
| Entra role | `Exchange Administrator` |
| Cert expiry | **2028-05-13** (cert `notAfter`; `config.json` still says 2027-05-13 and is wrong) |
| Entra role (Purview) | `Compliance Administrator` (assigned 2026-08-03) |

Credentials: `~/.tokens/claude-m365/` — `cert.pfx`, `cert.pem`, `key.pem`, `config.json`

### Connection Snippet

```powershell
Import-Module ExchangeOnlineManagement -RequiredVersion 3.9.2 -Force
Connect-ExchangeOnline `
    -AppId '69de0375-242d-4b8a-94df-4e095ab81cea' `
    -CertificateFilePath '/Users/fperez2nd/GitHub/.tokens/claude-m365/cert.pfx' `
    -Organization 'themyersbriggs.com' `
    -ShowBanner:$false
```

No device code, no browser, no interactive prompt. **This is the default path — do not
reach for `-Device`.** See the device code flow note under Gotchas.

### Security & Compliance (`Connect-IPPSSession`) — full app-only coverage

Same cert, same pinned module. Verified working 2026-08-03:

```powershell
Import-Module ExchangeOnlineManagement -RequiredVersion 3.9.2 -Force
Connect-IPPSSession `
    -AppId '69de0375-242d-4b8a-94df-4e095ab81cea' `
    -CertificateFilePath '/Users/fperez2nd/GitHub/.tokens/claude-m365/cert.pfx' `
    -Organization 'themyersbriggs.com'
```

| Cmdlet | Result |
|---|---|
| `Get-QuarantineMessage` | ✅ works (so `/quarantine-review` runs app-only) |
| `Get-Label` | ✅ works (returned 0 — tenant has no sensitivity labels configured) |
| `Get-DlpCompliancePolicy` | ✅ works (3 policies) |
| `Get-ComplianceSearch` | ✅ works (50 searches) |
| `Get-RetentionCompliancePolicy` | ✅ loads |

**Before 2026-08-03 none of the compliance cmdlets loaded**, because the SP held only
`Exchange Administrator`. Granting the `Compliance Administrator` Entra role fixed it and
took effect immediately (no propagation wait). Assigned with `az rest` as `2fperez`, not
with the SP's own token, so the SP never self-escalates:

```bash
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" \
  --headers "Content-Type=application/json" \
  --body '{"roleDefinitionId":"17315797-102d-40b4-93e0-432062caca18","principalId":"176b0e4e-4237-4381-bc4e-cbad24852ab6","directoryScopeId":"/"}'
```

⚠️ `Compliance Administrator` is broad and cannot be scoped. It includes eDiscovery and
content search, so this SP can search and export the content of any mailbox in the tenant.
Chosen deliberately over a custom SCC role group for simplicity. Revoke by deleting the
role assignment if that tradeoff ever stops being acceptable.

### Setup Steps (one-time, already completed)

1. `az ad app create` — create app registration
2. `az ad sp create` — create service principal
3. `openssl` — generate self-signed cert + PFX
4. `az ad app credential reset --cert` — upload cert to app
5. `az ad app permission add` + `az ad app permission admin-consent` — grant `Exchange.ManageAsApp`
6. `az rest` — assign Exchange Administrator Entra role to SP
7. Exchange Online PowerShell (one-time device auth):
   ```powershell
   New-ServicePrincipal -AppId <appId> -ServiceId <spId> -DisplayName 'claude-exo'
   Add-RoleGroupMember -Identity 'Recipient Management' -Member 'claude-exo'
   ```

### Gotchas

- **Device code flow is BLOCKED tenant-wide as of 2026-08-03.** Conditional Access policy `Block device code flow` (All users, All apps) blocks it, with only **`2fperez` and `2mhumora`** excluded. `-Device` therefore fails for every other account and must not be the go-to. Use app-only cert auth above. Note the CA policy PATCH returns `204` before the change is readable — poll until the read-back converges rather than trusting the status code.
- `Connect-ExchangeOnline` without `-Device` fails on macOS with a `PlatformNotSupportedException` — browser auth is not supported. Combined with the device code block, **app-only cert auth is the only viable path on macOS.**
- `Get-MailboxRestoreRequest` in Exchange Online does not support `-Mailbox` parameter — filter with `Where-Object { $_.TargetAlias -in $aliases }` instead.
- `-AllowLegacyDNMMismatch` is an on-prem-only parameter; omit it for Exchange Online cmdlets.
- `-SourceIsArchive` is a switch parameter — do not pass `$true`, just use the flag.
- **Deny ACEs:** `Remove-MailboxPermission` without `-Deny` only removes Allow ACEs. If `Get-MailboxPermission | Format-List *` shows `Deny: True`, you must pass `-Deny` to the removal cmdlet. A Deny ACE coexisting with an Allow ACE means Deny wins — the user effectively has no access despite the Allow entry.
- **Mailbox delegation audit — DLs not captured by Get-Mailbox:** `Get-Mailbox -ResultSize Unlimited` does not return distribution groups. Send on Behalf (`GrantSendOnBehalfTo`) on DLs requires a separate `Get-DistributionGroup -ResultSize Unlimited` pass.
- **Send As display names vs email addresses:** `Get-RecipientPermission` returns the Identity as a display name, not email. Display names may reflect old names (e.g. "Test O365" = tm365@themyersbriggs.com renamed to "Test M365"; "DL Network Operations US" = netops@themyersbriggs.com renamed to "DL Network Operations"). Always verify identity before assuming two names are different objects.
- **EXO write scope restriction for synced DLs:** `Set-DistributionGroup -GrantSendOnBehalfTo` fails in EXO PowerShell for on-prem-synced DLs with "object is being synchronized from your on-premises organization." Manage via on-prem Exchange PSSession instead.
- **Cloud-only GrantSendOnBehalfTo entries on synced DLs:** Permissions added directly in EXO (before write-scope enforcement) can get stuck — EXO won't let you remove them, and on-prem doesn't know about them. Fix: (1) add the user to the DL on-prem, (2) trigger a **full** sync (`Start-ADSyncSyncCycle -PolicyType Initial`), (3) remove the user on-prem, (4) trigger another full sync. After this, the EXO admin console or on-prem EAC can remove the entry normally. Delta syncs do NOT propagate `publicDelegates` changes reliably — always use a full sync for GrantSendOnBehalfTo changes on DLs.

---

## On-Premises Exchange (Hybrid) — Remote PowerShell via SSH

For hybrid environments where mailboxes are `RemoteUserMailbox`, on-prem Exchange cmdlets must be run on the Exchange server. Direct WinRM from macOS is not available (no WSMan client in PowerShell Core on macOS).

**Server:** `SVEXCHDC01.cpp-db.com`  
**Host login:** `cpp-db\ntsupport` — `PASS=$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com)`  
**Exchange RBAC:** ⚠️ **verify, don't assume.** svcclaude *was* in Organization Management and was
**removed from it 2026-07-27**; being a Domain Admin does not confer Exchange RBAC. Check with
`Get-ManagementRoleAssignment -GetEffectiveUsers -Role "Organization Management"` before relying
on the account, and if it is absent, ask Frank to run the task as `CPP-DB\2fperez` (Exchange
Administrator) or to grant the role.

### Connection Pattern

SSH to SVEXCHDC01, then create a `New-PSSession` to the Exchange PowerShell HTTPS endpoint with explicit credentials and Basic auth. This avoids the Kerberos double-hop problem inherent to SSH logon sessions.

```powershell
$pass = ConvertTo-SecureString '<password>' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CPP-DB\ntsupport', $pass)
$opts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$s = New-PSSession `
    -ConfigurationName Microsoft.Exchange `
    -ConnectionUri 'https://SVEXCHDC01.cpp-db.com/PowerShell/' `
    -Credential $cred `
    -Authentication Basic `
    -SessionOption $opts
Import-PSSession $s -DisableNameChecking | Out-Null
# ... run Exchange cmdlets ...
Remove-PSSession $s
```

To run this non-interactively from macOS, encode the script as base64 and pass via SSH:

```powershell
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
& sshpass -p $pass ssh -o StrictHostKeyChecking=no "cpp-db\\ntsupport@SVEXCHDC01.cpp-db.com" `
    "powershell.exe -EncodedCommand $encoded"
```

### Gotchas

- **Kerberos double-hop:** SSH creates a logon session with no Kerberos TGT. Any attempt to use Kerberos auth from within that session (including `RemoteExchange.ps1`, `Connect-ExchangeServer -auto`, or `New-PSSession -Authentication Kerberos`) will fail with `A specified logon session does not exist`. Fix: always pass explicit credentials with `-Authentication Basic` over HTTPS.
- **`Add-PSSnapin` fails non-interactively:** The snap-in loads but AD operations fail under the SSH logon context. Use the PSSession approach instead.
- **HTTP endpoint returns wrong content type:** The Exchange PowerShell VDir does not respond to WinRM over HTTP. Always use HTTPS (`https://`).
- **`Disable-Mailbox` vs `Disable-RemoteMailbox`:** Hybrid users with cloud-hosted mailboxes are `RemoteUserMailbox`. Use `Disable-RemoteMailbox -Archive`, not `Disable-Mailbox -Archive`.
- **`-SkipCACheck -SkipCNCheck -SkipRevocationCheck`** required in `New-PSSessionOption` when Exchange is using a self-signed or internal CA cert.
- **PSSession loopback from SVEXCHDC01 to itself fails:** Creating a `New-PSSession` to `https://SVEXCHDC01.cpp-db.com/PowerShell/` from within an SSH session on SVEXCHDC01 fails with `-2144108477`. WinRM loopback is blocked. The PSSession must be created from a *different* machine. Same applies to `localhost` as the URI.
- **Exchange snap-in (`Add-PSSnapin`) fails for AD writes under SSH:** The snap-in loads but Exchange cmdlets that write to AD fail with "The supplied credential is invalid" because the SSH logon session has no Kerberos TGT. Use the PSSession approach with explicit `-Authentication Basic` credentials instead — this works even from SVEXCHDC01 when initiated from a different source machine.
- **Working "different source machine" for the loopback restriction:** SSH to a cpp-db.com DC (`svdcdc01.cpp-db.com`), then `New-PSSession` to SVEXCHDC01's Exchange endpoint from there. Verified 2026-07-08. Note `svdcdc01` uses **password** SSH (`cpp-db\ntsupport`, KV secret `da-cpp-db-com`) — the ed25519 key is rejected on that host. A DC also lets you run `Get-ADUser` natively in the same session for lookups.
- **`Invoke-Command -Session $s -ScriptBlock {…}` against the Exchange endpoint fails** with `The syntax is not supported by this runspace … ScriptsNotAllowed`. The Exchange PowerShell endpoint is a constrained (NoLanguage) runspace, so it rejects script blocks containing language constructs (`Write-Output`, `Where-Object {…}`, variables). Use **`Import-PSSession`** instead — the generated proxy functions run language constructs locally and marshal only the cmdlet calls to the remote runspace.
- **`Add-ADPermission -Identity` does not resolve a primary SMTP address:** it's an AD-level cmdlet, not a recipient cmdlet, so `-Identity 'dev@themyersbriggs.com'` fails with "wasn't found." Recipient cmdlets (`Get/Set-DistributionGroup`) accept the SMTP address, but `Add-ADPermission`/`Get-ADPermission` need the **DistinguishedName** (or Name / `DOMAIN\sam`). Fetch it first: `$dn = (Get-DistributionGroup -Identity <smtp>).DistinguishedName`, then `Add-ADPermission -Identity $dn -User 'CPP-DB\fperez' -ExtendedRights 'Send As'`.
- **Granting delegates on a synced DL end-to-end:** set `GrantSendOnBehalfTo` (Send on Behalf) with `Set-DistributionGroup` and `Send As` with `Add-ADPermission` on-prem, then trigger a **full** AAD Connect sync (`Start-ADSyncSyncCycle -PolicyType Initial` on SVAZADSYNCDC01) — delta does not propagate `publicDelegates`. Do NOT try to set these in the EXO/M365 admin console for a synced DL; it renders the editor but the write fails with "Failed to update delegates at this moment."

---

## EXO admin REST (`InvokeCommand`) — permission auditing gotchas

Learned 2026-08-07 during a tenant-wide FullAccess / SendAs / SendOnBehalf audit
(265 mailboxes). All four of these cost real time; check them before trusting any
permission scan.

### 1. Boolean fields come back as STRINGS — `"False"` is truthy in Python

`Get-MailboxPermission` returns `Deny` as the **string** `"False"`, not a bool.
(`IsInherited` *is* a real bool — the shapes are inconsistent within the same object.)

```python
if p.get('Deny'): continue          # WRONG — "False" is truthy, drops every row
def truthy(x): return str(x).strip().lower() in ('true','1')
if truthy(p.get('Deny')): continue  # right
```

This produced a confident **"0 FullAccess grants tenant-wide"** result. The real
number was 330. Any filter over EXO REST output must coerce with `truthy()`.

### 2. Permission writes lag reads by 20 s to several minutes

`Remove-MailboxPermission`, `Add-RecipientPermission` and `Add-MailboxPermission`
all return `200` with an empty body **immediately**, but `Get-MailboxPermission` /
`Get-RecipientPermission` keep serving the old ACL for a while.

Verifying too early looks exactly like a silent failure. Two dead-end hypotheses
were chased (on-prem sync overwrite, `IsDirSynced` differences) before timing it:
the ACE cleared at **+20 s**. Always converge instead of single-shot verifying:

```python
for rnd in range(5):
    pending = scan_for_remaining()
    if not pending: break
    apply(pending)
    time.sleep(150)          # 120 s was still too short in places
```

Observed convergence: 25 → 9 → 2 → 0 over four rounds.

### 3. `GrantSendOnBehalfTo` returns DISPLAY NAMES, not addresses

`Get-Mailbox` returns `GrantSendOnBehalfTo` as `['Audrey Lafolie', 'thuy tran']`.
Comparing those against email local parts marks every existing grant as "missing" —
this inflated a real gap of 124 into a reported 249.

Resolve both sides through `Get-Recipient` (cache it) and compare on
`PrimarySmtpAddress` before computing any diff.

### 4. `Set-Mailbox -GrantSendOnBehalfTo` rejects duplicate identities

There is no add-semantics over REST, so you must write the **whole list**. If that
list contains both a display name and the SMTP address for the same person, the
cmdlet fails:

```
BadRequest — The parameter "GrantSendOnBehalfTo" contains the following
duplicated recipient identity: "Sathyan Varadaraj".
```

22 of 68 mailboxes failed this way. Fix: resolve every existing + new entry to
`PrimarySmtpAddress`, `set()`-dedupe, then write. Entries that fail to resolve
(orphaned/deleted trustees) must be dropped, not passed through.

### 5. Filter out self-grants and unresolved SIDs

Mailboxes routinely list their **own owner** in `FullAccess` (`alafolie <- alafolie`).
Exclude `canon(grantee) == canon(mailbox)` or you will "fix" meaningless grants.
Deleted trustees persist as raw SIDs (`S-1-5-21-…`) in `Get-RecipientPermission`
output — they resolve to nothing and should be reported, not written back.

### Working cmdlet shapes (REST `InvokeCommand`)

```python
invoke("Get-MailboxPermission",   {"Identity": mb})
invoke("Get-RecipientPermission", {"Identity": mb})          # SendAs lives here
invoke("Remove-MailboxPermission",{"Identity": mb, "User": u,
                                   "AccessRights": ["FullAccess"], "Confirm": False})
invoke("Add-RecipientPermission", {"Identity": mb, "Trustee": u,
                                   "AccessRights": ["SendAs"], "Confirm": False})
invoke("Set-Mailbox",             {"Identity": mb, "GrantSendOnBehalfTo": [smtp, ...]})
invoke("Get-Recipient",           {"ResultSize": "Unlimited"})   # build identity index
```

Note `Remove-MailboxPermission` needs `-Deny` to remove Deny ACEs (see memory
`feedback-exchange-deny-ace`); a scan that filters Deny out never surfaces them.

## Message tracing — `Get-MessageTrace` is dead, use `Get-MessageTraceV2`

`Get-MessageTrace` now returns **HTTP 400**, not a deprecation warning:

```
|Microsoft.Exchange.Management.Tasks.ValidationException|Get-MessageTrace will
start deprecating on September 1st, 2025. Please refer to: ... Get-MessageTraceV2
```

It fails with *and without* date parameters, so this reads like a bad-payload
error rather than a retired cmdlet. Substitute `Get-MessageTraceV2` and the same
parameters work unchanged:

```python
invoke("Get-MessageTraceV2", {"SenderAddress": "someone@example.com",
                              "StartDate": "2026-08-11 00:00",
                              "EndDate":   "2026-08-12 00:00"})
```

`"YYYY-MM-DD HH:MM"` is accepted. Returns `Received`, `Status`, `Size`,
`MessageId`, `MessageTraceId`, `RecipientAddress`, `Subject`.

**`Status` alone will not tell you *why* a message failed.** For that, pass
`MessageTraceId` **and** `RecipientAddress` (both required, plus the date range)
to `Get-MessageTraceDetailV2`:

```python
invoke("Get-MessageTraceDetailV2", {"MessageTraceId": row["MessageTraceId"],
                                    "RecipientAddress": row["RecipientAddress"],
                                    "StartDate": "...", "EndDate": "..."})
```

That returns the per-hop event chain (`Receive`, `Defer`, `Journal`, `Deliver`,
`Fail`) with the real SMTP reason in `Detail`, e.g.
`550 5.0.350 One or more of the attachments in your email is of a file type that
is NOT allowed by the recipient's organization.` The trace row just said `Failed`.

## Anti-malware policy — admin notifications and the common attachment filter

Worked out 2026-08-11 while tracing why netops kept receiving mail titled
*"Undeliverable message"* that read like a bounce for something they had sent.

### The "malware" wording is frequently a lie — check for a file-type block first

Admin notifications say *"not delivered to the intended recipients because malware
was detected"* even when nothing was scanned as malware. Microsoft's own docs are
explicit: *"Because the block is from an admin-defined policy, these messages don't
get a malware verdict."* The `Detections found:` line is the discriminator, and its
format is **`<filename>` TAB `<matched extension>`**:

```
Detections found: 
Fwd Order confirmation from elevate.themyersbriggs.com	com
attachment-filter-test.com	com
```

A second field that is a *file extension* rather than a malware family name means
the common attachment filter fired, not AV. Confirm with `Get-MessageTraceDetailV2`
(`550 5.0.350` = file type, not malware).

### Nested `message/rfc822` names come from the Subject — but the match is NOT deterministic

Forwarded emails attached by Outlook arrive as `Content-Type: message/rfc822` with
**no `filename` parameter at all**. EOP nonetheless reported a filename, and a full
MIME walk of the offending message proved the nested `Subject` is the only possible
source — no part anywhere in the tree had a name ending in `.com`:

```
nested Subject : Fwd: Order confirmation from elevate.themyersbriggs.com
EOP reported   : Fwd Order confirmation from elevate.themyersbriggs.com    com
                 (colon stripped, no .eml suffix -> Subject-derived, not filename-derived)
```

> #### ⚠ Do NOT assume this reproduces. It does not.
>
> Three counter-examples from the same session, all **delivered normally**:
>
> | Case | Result |
> |---|---|
> | The **identical** nested `.eml` (same SHA-256) resent 11 min later | Delivered |
> | Synthetic repro: one nested rfc822, Subject ending `.com` | Delivered |
> | Synthetic repro: four nested rfc822 + a PDF, ~187 KB, mirroring the original | Delivered |
>
> The only observable difference is that the blocked message is the **one that went
> through Safe Attachments detonation** (`Defer :: [ATP][Scan in progress] Message
> waiting for detonation result`); none of the three delivered cases were deferred.
> **Working theory, unproven:** container expansion during detonation is what surfaces
> the Subject-derived name to the extension matcher, so messages that skip detonation
> never get evaluated that way.
>
> Practical consequence: you cannot predict which forwarded mail this hits, and you
> cannot reproduce it on demand to test a fix. Do not burn time trying, and do not
> promise anyone a deterministic rule.

This also contradicts documented precedence. Microsoft states true-type matching wins
and extension matching is used only *"if true type matching fails or isn't supported."*
`eml` **is** true-type supported and `com` is **not**, so extension matching should
never have run here. Worth a false-positive submission rather than a config workaround.

### Mitigation: `FileTypeAction = Quarantine`, not `Reject`

Because the trigger is unpredictable, the durable fix is to change the *consequence*
rather than chase the cause. `Reject` (the default) bounces the message and the content
is gone; the recipient never learns it existed. `Quarantine` makes the same block
recoverable. Verified end to end 2026-08-11:

```python
invoke("Set-MalwareFilterPolicy", {"Identity":"Default","FileTypeAction":"Quarantine"})
```

- message lands in quarantine as `QuarantineTypes: FileTypeBlock`
- the **admin notification still fires** (it is not tied to the Reject action)
- `Release-QuarantineMessage {"Identity": id, "User": [addr]}` delivers it intact

Note `Get-QuarantineMessage` indexes the message **before** `Get-MessageTraceV2` shows
it. If the trace has no row yet, check quarantine before concluding anything.

### Submissions to Microsoft — app-only is blocked by a SECOND RBAC layer

`New-ReportSubmission` / `Get-ReportSubmission` are **Security & Compliance** cmdlets,
not Exchange Online ones. That distinction is what makes this confusing:

| Endpoint | Cmdlet | Result |
|---|---|---|
| `outlook.office365.com` | `Get-ReportSubmissionPolicy` | ✅ 200 |
| `outlook.office365.com` | `Get-ReportSubmission` / `New-ReportSubmission` | ❌ 403, **body is 470 null bytes** |
| `ps.compliance.protection.outlook.com` | all three | ❌ 403, *"User is not allowed to call …"* |

> #### 🔑 The two endpoints fail differently, and that is the diagnostic
>
> The EXO endpoint returns **403 with a null-byte body** for cmdlets it does not host.
> A naive client raises `json.JSONDecodeError` / `ContentDecodingError` and you chase a
> transport bug. The **compliance endpoint returns a real JSON RBAC error** naming the
> cmdlet. **Always re-test a suspicious 403 against
> `ps.compliance.protection.outlook.com` before concluding anything** — that is what
> separates "wrong endpoint" from "insufficient rights".
>
> Compliance-endpoint token scope: `https://ps.compliance.protection.outlook.com/.default`

**Entra directory roles do NOT confer Security & Compliance RBAC on a service
principal.** Verified 2026-08-11: with **Exchange Administrator + Compliance
Administrator + Security Administrator** all assigned and confirmed on the SP, every
SCC cmdlet still returned `Forbidden`. Purview/Defender keeps its own role groups, and
membership there is a separate grant. Assigning more Entra roles will not fix it —
do not keep stacking privilege hoping it propagates.

### Use the Graph submissions API instead — and note it is BETA only

```
GET/POST https://graph.microsoft.com/beta/security/threatSubmission/emailThreats   # 200
GET      https://graph.microsoft.com/v1.0/security/threatSubmission/...            # 400
         "Resource not found for the segment 'threatSubmission'"
```

Granted to `claude-m365` as Graph app role `ThreatSubmission.ReadWrite.All`
(`d72bdbf4-a59b-405c-8b04-5995895819ac`) on 2026-08-11. This is the supported app-only
route; the `New-ReportSubmission` cmdlet is not.

### ⚠ Neither escalation path is open any more — grant permissions with `az`

Resolved 2026-08-11. Previously the app held `RoleManagement.ReadWrite.Directory` and
could **assign itself any Entra directory role unattended**, with no approval step. That
was removed at Frank's instruction and replaced with `RoleManagement.Read.Directory`, so
role **auditing still works** while self-assignment does not:

```
GET  /roleManagement/directory/roleDefinitions    -> 200  (145 rows)
GET  /roleManagement/directory/roleAssignments    -> 200
POST /roleManagement/directory/roleAssignments    -> 403 Authorization_RequestDenied
POST /servicePrincipals/<sp>/appRoleAssignments   -> 403 Authorization_RequestDenied
```

**Consequence: the app can no longer grant itself anything.** New app roles and directory
roles must be assigned with **`az rest` as `2fperez@`**, which is verified working:

```zsh
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/<sp>/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body '{"principalId":"<sp>","resourceId":"<graph-sp>","appRoleId":"<role>"}'
```

Graph SP object id in this tenant: `98ba181e-bb52-46c6-abbf-da27c8d1af20`.

⚠ **A newly granted app role needs a NEW token**, and it does not appear immediately —
the first token issued after the grant still lacked it, the next one (about 25 s later)
carried it. Decode the JWT `roles` claim to confirm before concluding a permission
"didn't work".

### `CustomNotifications $true` REQUIRES `CustomFromAddress`

Setting the flag without an address fails, so you cannot customise only the name:

```
CustomFromAddress: The CustomFromAddress value is not set.
Custom notifications cannot be enabled without a valid CustomFromAddress.
```

### ⚠ `CustomFromAddress` is NOT VALIDATED — a typo fails silently

`Set-MalwareFilterPolicy` accepted `m365-alerts@notarealdomain.example` with a
`200`. There is no check that the address exists, or that the domain is even ours.
**"The setting saved" is not evidence notifications will send.** Always follow a
change here with a real test detection before trusting it.

### `CustomFromName` is overridden whenever the address resolves to a mailbox

Outlook renders the *directory object's* DisplayName, not `CustomFromName`. With
`CustomFromAddress = postmaster@…`, which was a proxy address on the Marketing
shared mailbox, every security alert arrived as **"Marketing"** no matter what
`CustomFromName` said:

```
header   : From: "M365 Defender Admin Alert" <postmaster@themyersbriggs.com>
rendered : Marketing <marketing.us@themyersbriggs.com>
```

**To control the rendered name, control the object** — point `CustomFromAddress` at
a dedicated mail-enabled object and set *its* DisplayName. `CustomFromName` only
renders if the address resolves to nothing, which is untested and risks the silent
failure above. Check what an address resolves to before choosing it:

```
users?$filter=proxyAddresses/any(p:p eq 'smtp:<addr>')&$select=displayName
groups?$filter=proxyAddresses/any(p:p eq 'smtp:<addr>')&$select=displayName
```

### A custom body does NOT suppress the detail block

Verified by test send: EOP still appends its `--- Additional Information ---`
section (Subject / Sender / Time received / Message ID / Detections found) beneath
`CustomExternalBody` / `CustomInternalBody`. Customising the text costs nothing.

### Check preset policies before assuming the Default policy applies

Preset security policies are evaluated **before** the Default policy and have admin
notifications hard-off, so recipients in scope of a preset generate no notification
at all. Both of these returning empty means no preset is assigned to anyone and the
Default policy really does cover the tenant:

```python
invoke("Get-EOPProtectionPolicyRule")   # empty -> Standard/Strict assigned to nobody
invoke("Get-ATPProtectionPolicyRule")
```

### Recipient and policy objects also lag reads (see §2 above)

The same write/read lag documented for mailbox permissions applies to
`Set-MalwareFilterPolicy` and to newly created recipients. Hit three times in one
session: a policy read straight after a successful `200` returned every field at its
**old** value, and `New-DistributionGroup` reported `Members: []` and
`HiddenFromAddressListsEnabled: False` when both had in fact been set. Poll until
the value you wrote comes back; never judge a write by the read that follows it.

---

## EWS access control (`EwsAllowedAppIDs`) — retirement prep and its traps

Exchange Online EWS is being retired: **phased disablement starts October 2026**, and
EWS is **fully and permanently off on April 1, 2027**, no exceptions. Any client that
talks EWS is on borrowed time. See
[Deprecation of EWS in Exchange Online](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online).

`EwsEnabled` has three states, and the default is not "stay as you are":

| Value | Behaviour |
|---|---|
| `$true` | EWS enabled. From October 2026, **only** app IDs on the allowlist may call EWS. |
| `$false` | EWS blocked tenant-wide; per-mailbox overrides are ignored. |
| `$null` | Today's default. Microsoft **auto-flips this to `$false` on 2026-10-01** for any tenant that has not explicitly set `$true`. |

TMBC is explicitly opted in (`EwsEnabled = True`) with a curated allowlist, so the
October auto-switch does not apply. Microsoft pre-populates an allowlist from usage
telemetry for tenants that never built one before September 2026 — that does **not**
apply to us, we own ours.

### Trap 1: the allowlist is invisible to a plain `Get-OrganizationConfig`

`Get-OrganizationConfig | Select-Object Ews*` returns `EwsAllowList`, `EwsBlockList`,
`EwsApplicationAccessPolicy` and friends — and **all of them are empty even when an
app-ID allowlist is actively enforcing**. `EwsAllowedAppIDs` is a separate mechanism
from the user-agent-based `EwsAllowList`/`EwsApplicationAccessPolicy` pair, and it only
materialises with an explicit switch:

```powershell
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsAllowedAppIDs
```

Without `-RetrieveEwsOperationAccessPolicy` you will wrongly conclude no allowlist is
configured and go hunting for a Conditional Access or licensing cause that isn't there.

### Trap 2: it is ONE comma-joined string, not an array — naive writes wipe the list

Three configured app IDs read back as a **single** array element containing commas, so
`.Count` returns `1`, not `3`. `Set-OrganizationConfig -EwsAllowedAppIDs` also
**overwrites wholesale** — there is no `@{Add=...}` syntax as there is for
`EwsAllowList`. Passing just the ID you want to add silently removes every other app's
EWS access. In this tenant that would break Veeam M365 backups and Mimecast.

Always read-modify-write, flattening then splitting:

```powershell
$apple = 'f8d98a96-0999-43f5-8af3-69971c7bb423'
$before = ((Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs -join ',')
$before   # save this verbatim — it is the only rollback path

$ids = ($before -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($ids -notcontains $apple) {
    Set-OrganizationConfig -EwsAllowedAppIDs (( @($ids) + $apple ) -join ',')
}

# verify — do not trust the write
((Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs -join ',')
```

### Trap 3: a successful sign-in neither proves nor disproves an EWS block

Any EWS authorization decision happens **after** authentication, so Entra can record a
clean success (`errorCode 0`, resource `Office 365 Exchange Online`) while the client still
fails. Users report "my password and MFA work but the app won't connect", and sign-in logs
appear to exonerate the tenant.

Read it in one direction only: a clean sign-in does **not** rule an EWS block out. It is
equally **not** evidence that a block is present — plenty of post-auth failures have
nothing to do with EWS authorization (see the ticket 101534 case study below, where the
real cause was a broken Autodiscover endpoint). Use it to locate the *stage* of failure,
never to name the cause.

Find which app a user's client is actually presenting as:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=userId eq '<objectId>'&\$top=200"
# then group by appId / appDisplayName and compare against EwsAllowedAppIDs
```

### Protocol per device: macOS Apple Mail is EWS, iOS Mail is ActiveSync

**macOS Apple Mail's "Microsoft Exchange" account type is EWS. iOS Mail is
ActiveSync.** Useful to know, because an EWS-side change can take out Macs while iPhones
and iPads carry on syncing normally.

Confirm the protocol per device — `ClientType` is the field that matters:

```powershell
Get-MobileDevice -Mailbox user@themyersbriggs.com |
  Select-Object DeviceModel,DeviceOS,DeviceType,ClientType,FirstSyncTime
```

`ClientType = EAS` for iPhone/iPad; a `DeviceType = Outlook` row with
`DeviceModel = Mac` is Outlook for Mac, not Apple Mail.

⚠️ **Do NOT read that asymmetry as proof the EWS allowlist is the cause.** It is
suggestive at best. See the case study below, where exactly that inference was wrong.

### Known app IDs

| App ID | Client |
|---|---|
| `f8d98a96-0999-43f5-8af3-69971c7bb423` | Apple Internet Accounts (macOS Mail, iOS Mail) |
| `d3590ed6-52b3-4102-aeff-aad2292ab01c` | Microsoft Office / Outlook desktop (also the Skype desktop client ID) |
| `49a117f9-f6d0-4056-891d-51f74a8c3b2d` | Veeam Backup for Microsoft 365 |
| `b910823e-25d7-4238-aeea-9475a6aac850` | Mimecast |
| `69de0375-242d-4b8a-94df-4e095ab81cea` | `claude-m365` (added 2026-08-12 for EWS diagnostics) |

Do not copy an app ID from notes and assume it is right for a given tenant — read it out
of the sign-in logs for the client that is actually failing.

---

## Case study — `com.apple.accounts error 3`, and how NOT to diagnose it (ticket 101534)

**2026-08-12.** Three users could not add a Microsoft Exchange account in macOS Apple Mail.
Every one failed with `The operation couldn't be completed. (com.apple.accounts error 3.)`.
It looked exactly like the EWS app-ID allowlist introduced three days earlier. **It was not.**

> ### ✅ CONCLUSION: the Exchange Online side is PROVEN GOOD. The fault is client-side.
>
> Settled by acquiring a **delegated** EWS token using **Apple's own app ID** and making the
> same call Apple Mail makes (recipe below). It returned **HTTP 200 with a FolderId**.
>
> ```
> appid=f8d98a96-0999-43f5-8af3-69971c7bb423   scp=EAS.AccessAsUser.All EWS.AccessAsUser.All
> EWS GetFolder -> HTTP 200   X-CalculatedBETarget: LV8PR22MB4454.namprd22.prod.outlook.com
> ```
>
> So EWS accepts Apple Internet Accounts, with Apple's exact scopes, in delegated context,
> against this tenant. That rules out the allowlist, EWS availability, the app ID being
> blocked, consent, and tenant policy **as a class**. Affected users also authenticate
> cleanly (`errorCode 0`, CA success, MFA satisfied) and fail only afterwards.
>
> ⛔ **The "so the fault is client-side macOS Apple Mail" conclusion that used to sit here was
> WRONG — see the correction below.** Exchange being exonerated does not mean the client is at
> fault; DNS sits between them.
>
> Scope caveat on the probe: it ran as a different mailbox (`2fperez`) than the affected users.
> Their `Get-CASMailbox` settings were separately verified identical and clean, and the
> tenant-wide consent grant covers all users, so it is representative of tenant policy — but it
> is not literally their mailbox.

> ### ⛔ CORRECTION — the cause was OUR DNS, not the client
>
> Four causes were asserted during this investigation and the first three were wrong: the EWS
> allowlist, the PAN firewall, and "client-side macOS Apple Mail." The actual leading candidate:
>
> **An `_autodiscover._tcp` SRV record on our own domains, pointing at port 443 on
> `autodiscover.outlook.com` — a port that deliberately does not listen.** That host exists to
> serve a **port-80 302 redirect** to `autodiscover-s.outlook.com`, where the `*.outlook.com`
> certificate matches the name the client connects to. Our SRV handed clients a dead endpoint.
> Microsoft documents **only the CNAME** for M365 Autodiscover; the SRV was on-prem/hybrid-era
> legacy and existed in **both** public and internal DNS. Deleting it from every zone and every
> DNS server resolved it for the first user tested.
>
> **Attribution is not proven** — several DNS changes were bundled in the same window. This is
> the leading candidate on mechanism, not a confirmed cause.
>
> **The transferable error:** the app-only *and* delegated probes both proved Exchange was
> healthy, and I read "Exchange is fine" as "therefore the client is broken." Ruling out the
> server does not implicate the client. Discovery, DNS and the network all sit in between, and in
> this case the fault was in a DNS record we owned.
>
> Full write-up, including the reusable diagnostics and every dead end with evidence:
> `knowledge-base/troubleshoot/apple-mail-exchange-autodiscover-srv-2026-08-12.md`

### Real but UNPROVEN as the cause: `autodiscover.outlook.com` refusing TLS, globally

⚠️ **This anomaly is real and reproducible, but it is NOT demonstrated to be the cause.**
Every affected user authenticated successfully, which means their client got *past*
discovery. Recorded because it is genuinely odd and independently verified, not because it
explains the symptom.

Every Microsoft 365 tenant's `autodiscover.<domain>` CNAMEs to `autodiscover.outlook.com`.
On 2026-08-12 it **accepted connections on port 80 but refused every connection on 443**, on
every IP in the pool:

```
autodiscover.outlook.com      HTTP 000   all pool IPs: 443 DEAD, 80 OPEN
autodiscover-s.outlook.com    HTTP 401   reachable
outlook.office365.com         HTTP 401   reachable
```

Reproduced identically from a workstation on a residential ISP **and** from an AWS EC2 host
in us-west-2. Two unrelated networks, so not tenant, ISP, or firewall. Microsoft-side.

Autodiscover **V2** was unaffected and is the thing to test as a control:

```bash
curl "https://outlook.office365.com/autodiscover/autodiscover.json?Email=user@domain&Protocol=EWS&RedirectCount=3"
# → {"Protocol":"EWS","Url":"https://outlook.office365.com/EWS/Exchange.asmx"}
```

### False lead #1: the EWS allowlist

The allowlist went in on 08-09; Apple Mail broke on 08-11. Apple was absent from the list,
iPhones (EAS) were unaffected, and sign-in logs showed authentication succeeding then the
client failing — all consistent with an EWS authorization block. **Correlation only.**

Two experiments killed it, and either would have killed it on day one:

1. **Adding** `f8d98a96` to the allowlist changed nothing, after 25+ minutes.
2. **Removing `EwsAllowedAppIDs` entirely** (`$null`) changed nothing either.

**A cause you can add and remove with no change in symptom is not the cause.** Run the
removal experiment early; it is one command and it is decisive.

Supporting evidence that the retirement docs corroborate: *Prepare for EWS retirement*
states app-ID enforcement begins **October 2026**, so a populated list may not be enforced
at all before then.

### False lead #2: "that user never reached Entra" — SIGN-IN LOG LATENCY

⚠️ **This one is the most transferable trap in the whole incident, and it is easy to repeat.**

Sign-in logs were queried ~5 minutes after a user's failed attempt, came back empty, and
that emptiness was reported as fact: *"no sign-in record, so it failed before
authentication."* An entire second theory (Autodiscover/DNS/network for that user) was built
on it. **The records existed.** They simply had not been indexed yet, and appeared later
with `errorCode 0`, `interactiveUser`, exactly like everyone else's. The user had in fact
typed their password and completed an MFA prompt, which they said plainly — and their
account of their own actions should have outweighed an empty query.

**Rules:**

- **Entra sign-in indexing lag routinely exceeds 5 minutes.** Never conclude "no record"
  from a single query shortly after the event. Re-query several minutes later, and prefer
  the user's own account of what they did.
- **`/v1.0/auditLogs/signIns` returns INTERACTIVE sign-ins only.** Non-interactive legs are
  silently excluded, so a client whose failing leg is non-interactive looks absent. Use
  `beta` and filter explicitly:

  ```bash
  # include BOTH event types, and bound the window - $top alone will truncate a busy tenant
  F="userId eq '<objectId>' and createdDateTime ge 2026-08-12T15:35:00Z and createdDateTime le 2026-08-12T16:05:00Z and (signInEventTypes/any(t: t eq 'interactiveUser') or signInEventTypes/any(t: t eq 'nonInteractiveUser'))"
  az rest --method GET --url "https://graph.microsoft.com/beta/auditLogs/signIns?\$filter=<urlencoded F>&\$top=200"
  ```

- **Bound the time window; don't rely on `$top`.** A tenant-wide query with `$top=400`
  covered only ~13 minutes here and truncated away the very records being looked for.

### Stage before cause: pre-auth vs post-auth

Still the right first question — just answer it with data you trust:

| Signal | Meaning |
|---|---|
| Record with `errorCode 0` | Authenticated fine, failed **after** → EWS / authorization / client |
| Genuinely no record, confirmed after latency | Failed **before** authentication → Autodiscover / DNS / network |

In this incident all three users turned out to be in the **first** row: authentication clean,
failure after. The apparent split between them was an artefact of the latency trap above.

### Check the routing table before blaming the firewall

An intermediate theory blamed the PAN. The routing table disproved it in one command — the
GP tunnel carried only RFC1918 plus five specific public IPs, so Microsoft traffic egressed
via the local ISP and never touched the PAN:

```bash
route -n get <ip>                        # iface + gateway for a specific destination
netstat -rn -f inet | awk '$4 ~ /utun/'  # what the VPN actually carries
```

**Never resolve a hostname to IPs and then test those IPs later.** Microsoft's anycast
pools rotate per query, so the addresses go stale within seconds and adjacency proves
nothing. Test by hostname, resolving at connect time, and repeat several times.

### Also ruled out (all clean — don't re-investigate blind)

Internal DNS (both DCs, no override or stub zone), external DNS (matches internal),
Conditional Access (`conditionalAccessStatus: success`, MFA satisfied), consent (tenant-wide
`AllPrincipals` grant of `EAS.AccessAsUser.All EWS.AccessAsUser.All` covers every user),
Application Access Policies (`Test-ApplicationAccessPolicy` → `Granted`), per-mailbox CAS
settings, Client Access Rules (none), authentication policies (none default), Baseline
Security Mode (would present as `EwsEnabled $false`).

**Licensing is not a factor.** It hit Business Basic and Business Premium/E3 identically.
Licence level only determines the *remedy* (Business Basic → Outlook on the web; desktop
SKUs → Outlook for Mac), never whether the failure occurs.

### Proving EWS itself is healthy (app-only probe)

`claude-m365` holds `full_access_as_app` on Office 365 Exchange Online
(`dc890d15-9560-4a4c-9b7f-a736ec74ec40`), granted 2026-08-12 by **direct
`appRoleAssignment`** — never via admin-consent, which wipes that app's other permissions.
⚠️ This is read/write to **every mailbox in the tenant** over EWS.

Omit the impersonation header deliberately: the resulting fault proves EWS is alive and
routing to a real backend, which is exactly what you want to establish.

```
ErrorInvalidExchangeImpersonationHeaderData
"ExchangeImpersonation SOAP header must be present for this type of OAuth token."
x-ms-appId: <appId>   X-CalculatedBETarget: <server>.namprd22.prod.outlook.com
```

**Unresolved:** *with* a valid `ExchangeImpersonation` header the same call returns `403`
with an empty body and `Restrict-Access-Confirm: 1`, despite the role being present,
`Test-ApplicationAccessPolicy` returning `Granted`, and the app being on the EWS allowlist.
Not RAOP and not allowlist propagation (still failing after 13 min). Unexplained — do not
assume this indicates a tenant misconfiguration.

Note the probe's limit: app-only exercises a **different code path** from Apple Mail's
**delegated** flow. It can prove EWS is up. It cannot prove a delegated client will work.

### ⭐ The delegated probe — impersonate a real mail client's OAuth identity

**This is the single best diagnostic for "client X can't connect but the tenant looks fine".**
Third-party mail clients are registered as **public clients**, so you can run a **device code
flow using the client's own app ID** and get a token with the client's own scopes. You are
then making the exact call the failing client makes, and any failure is unambiguous.

Verified working with Apple's app ID (macOS/iOS Mail):

```python
import msal, requests
app = msal.PublicClientApplication(
    "f8d98a96-0999-43f5-8af3-69971c7bb423",              # the CLIENT's app ID, not your own
    authority="https://login.microsoftonline.com/<tenantId>")
flow = app.initiate_device_flow(scopes=["https://outlook.office365.com/EWS.AccessAsUser.All"])
print(flow["verification_uri"], flow["user_code"])       # user completes this in a browser
tok = app.acquire_token_by_device_flow(flow)["access_token"]

# delegated token IS the user - no ExchangeImpersonation header
requests.post("https://outlook.office365.com/EWS/Exchange.asmx",
    headers={"Authorization": f"Bearer {tok}", "Content-Type": "text/xml; charset=utf-8",
             "X-AnchorMailbox": "<upn>"}, data=GETFOLDER_SOAP)
```

`200` + a `<t:FolderId>` means Exchange is fine for that client and the fault is client-side.
Decode the token and check `scp` to confirm which scopes were actually granted.

**Gotcha:** device code flow is **blocked tenant-wide** by the CA policy `Block device code
flow`, with only `2fperez` and `2mhumora` excluded — so run it as one of those. `2mhumora`
has **no mailbox**, so `2fperez` is the only usable identity for a mailbox probe. Confirm the
probe account has `EwsEnabled=True` first, or a policy failure is indistinguishable from a
missing mailbox.
