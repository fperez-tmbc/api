# PDQ Deploy & Inventory — Lessons Learned

**Installed version: 20.1.8.0** (Deploy and Inventory, both Enterprise, ServiceMode `Local`).

## Connection

- **Server:** `SVPDQHQ01.cpp-db.com`
- **SSH user:** `ntsupport@cpp-db.com` — the **domain** DA. Must be domain-qualified (see below).
- **Auth:** SSH **key**, no password. `~/.ssh/id_ed25519_pdq` if present, else `~/.ssh/id_ed25519`.
- **Password fallback (rarely needed):** `~/GitHub/.tokens/kv-get.sh da-cpp-db-com`

```bash
SSH_KEY=~/.ssh/id_ed25519          # or ~/.ssh/id_ed25519_pdq
ssh -n -q -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" "<command>" | tr -d '\r'
```

The key is authorized via `C:\ProgramData\ssh\administrators_authorized_keys`, which Windows OpenSSH
applies to **any member of the local Administrators group**. `CPP-DB\Domain Admins` is a member, so the
same Mac key logs in as the domain DA. Confirm with `whoami` → must print `cpp-db\ntsupport`.

### Domain-qualify the username anyway

Since **2026-08-15 this host has no local accounts other than `Administrator`** (all disabled built-ins
aside), so a bare `ntsupport@SVPDQHQ01.cpp-db.com` now resolves straight to the domain account and works.
Keep using the qualified form regardless — it is explicit, and it is the only form that stays correct if a
same-named local account is ever recreated here or the pattern is copied to another host.

**Why this matters historically.** Until 2026-08-15 there was also a *local* `ntsupport` (RID 1001,
password last set 2016-09-20; the 2026-07 local-admin standardization standardized `Administrator` at
RID 500 and deliberately left this one alone). It was an enabled local admin, so the **same key** in
`administrators_authorized_keys` matched it, and a bare username silently produced a **local** token.
That failed *half-way*: Deploy's `BUILTIN\Administrators` entry let the **Deploy CLI succeed** (all 407
packages returned) while the **Inventory CLI was denied** — so a script missing the suffix would fire
deployments and only then fail on Inventory steps. Frank deleted the account, its profile, and the
orphaned `ProfileList` entries on 2026-08-15.

**The same collision still exists on five other hosts** carrying a local `ntsupport` from the same era:
`SVAZADSYNCDC01`, `SVSTAFFDEMODC01`, `SVSTAFFDEVDC01`, `SVSTAFFQADC01`, `SVSTAFFQADC02`. Domain-qualify
there too, or expect the same half-working failure.

Assert on `whoami` returning `cpp-db\ntsupport` before doing anything consequential.

### Capabilities — full access as `cpp-db\ntsupport`

Verified end-to-end 2026-08-15 against 20.1.8.0 with key auth:

| Capability | Status |
|---|---|
| PDQ Deploy CLI (all commands) | ✅ |
| PDQ Inventory CLI (all commands) | ✅ |
| SQLite reads on both DBs | ✅ |
| `powershell -EncodedCommand` (gzip log reads) | ✅ |

Cross-check that both read paths agree: SQLite and `GetCollectionComputers "PROD"` both return **46**.

**No licence cost.** `cpp-db\ntsupport` was already in Inventory's `LicensedUser` table; the count stayed
at 7 after the switch.

> **History:** this used to run as the local `SVPDQHQ01\claude` account, which could use the Deploy CLI but
> was denied the **entire** Inventory CLI (including read-only verbs), leaving SQLite as the only Inventory
> read path. That account was **deleted 2026-08-15** in favour of `cpp-db\ntsupport`. Deploy's CLI worked for
> it only because Deploy's `ConsoleUsers` includes `BUILTIN\Administrators`, which Inventory's does not.

### Console User access is by AD GROUP, not per-account

The `ConsoleUsers` table holds **groups**, not users:

| Name | Type | SID suffix |
|---|---|---|
| `CPP-DB\netops` | Group | `-2536` |
| `CPP-DB\Domain Admins` | Group | `-512` |

Any **local** account is therefore permanently excluded, which is why `SVPDQHQ01\claude` was denied. It was
never a per-account setting anyone forgot to flip.

**Deploy is asymmetric:** Deploy's own `ConsoleUsers` table adds a third entry, `BUILTIN\Administrators`.
That is the sole reason the local `claude` account could drive the Deploy CLI while being locked out of
Inventory. Inventory has no equivalent entry.

**Licence model:** `LicensedUser` tracks **named users** (7: `2fperez`, `2bcampbell`, `2lbejnar`,
`2rceglarz`, `jelgin`, `ntsupport`, `rceglarz`). Reusing an identity already in that table costs nothing;
only a **new** identity consumes another seat. Purchased seat count is not stored in the DB — check the PDQ
account portal. Note Deploy's `LicensedUser` never listed `claude` despite hundreds of deployments, so
CLI use by a local admin was not licence-counted there.

**`cpp-db\ntsupport` is RID 500** — the renamed built-in domain Administrator. Acceptable for the PDQ
automation because it is already the standing pattern for Windows/AD work here, but for any *new*
unattended service prefer a dedicated account in `CPP-DB\netops` (costs one seat) over the built-in DA.

CLI sessions are recorded in `ConsoleUserSessions` with the **`CLI`** column populated (Console sessions
populate `Console` instead), so CLI use is distinguishable from GUI use in the audit trail.

### AD sync / disabled computers
- `Computers.ADIsDisabled` is a **string** (`'Enabled'` / `'Disabled'`), NOT `1/0`. Filter with `WHERE ADIsDisabled='Disabled'`.
- **AD Sync does not delete *disabled* computers** — it only removes computers no longer present in the synced AD scope. In practice all inventory machines show `Enabled` (the sync scope excludes disabled accounts), so a decommissioned/disabled machine is dropped when the scheduled AD sync re-reads it. SVPRINTHQ01 was already gone this way; SVFSAU01 will drop on the next sync.
- Both halves of that are now scriptable rather than GUI-only: `PDQInventory ADSync -StartSync` forces the sync, and `PDQInventory DeleteComputers -Computers <name>` removes a machine directly.

---

## Windows paths on SVPDQHQ01

| Variable | Path |
|---|---|
| PDQ Deploy EXE | `C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe` |
| PDQ Deploy DB | `C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db` |
| PDQ Inventory DB | `C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db` |
| sqlite3.exe | `C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe` |

---

## Querying PDQ Inventory via SQLite

Run sqlite3 queries over SSH using cmd.exe:

```bash
PDQ_INV_DB='C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db'
PDQ_SQLITE='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe"'

ssh -n -q -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" \
    "$PDQ_SQLITE \"$PDQ_INV_DB\" \"<SQL query>\""
```

### Key tables — PDQ Inventory

| Table | Key columns |
|---|---|
| `Computers` | `ComputerId`, `Name`, `NeedsReboot`, `SuccessfulScanDate`, `ADDomain`, `ADIsDisabled` |
| `Collections` | `CollectionId`, `Name` |
| `CollectionComputers` | `ComputerId`, `CollectionId` |

Use `SELECT DISTINCT` on collection membership queries — machines can belong to multiple sub-collections.

**`ADDomain` is the clean machine → domain map.** Use it instead of DNS guessing when a task needs
per-domain credentials. The estate is genuinely mixed: DEV/QA/VDI alone is 34 `cpp-db.com`, 2 `opp.local`,
3 `oppnewapp.local`, and Web Staggered - Group 1 is 1 `cpp-db.com` + 2 `cpp-web.com`.

### List members of a collection

```sql
SELECT DISTINCT c.Name
FROM Computers c
JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId
JOIN Collections col ON cc.CollectionId = col.CollectionId
WHERE col.Name = 'Intune Management Extension'
ORDER BY c.Name
```

### Query pending reboots in a collection

```sql
SELECT DISTINCT c.Name
FROM Computers c
JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId
JOIN Collections col ON cc.CollectionId = col.CollectionId
WHERE col.Name = 'PROD' AND c.NeedsReboot = 1
```

### Key tables — PDQ Deploy

| Table | Key columns |
|---|---|
| `Deployments` | `DeploymentId`, `Status` (`Running`/`Finished`), `Started` |
| `DeploymentComputers` | `DeploymentId`, `Name`, `Status` (`Running`/`Successful`/`Failed`), `Error`, `DeploymentComputerId` |
| `DeploymentComputerSteps` | `DeploymentComputerId`, `Title`, `ReturnCode`, `OutputFile`, `Error`, `IsFailed` |

**Note:** `DeploymentComputers` does NOT have a `Finished` column.

**Post-deployment scan check** — after deployment is `Finished`, immediately query how many collection members have `SuccessfulScanDate < Deployments.Started`. Use `Started` (not `Finished`) as the reference because PDQ scans each machine as soon as its step completes, so scan timestamps fall inside the deployment window. If the count is already 0, proceed immediately. If machines are still pending, poll every 30 s until the count reaches 0 — do not assume scans are done or not done without checking first.

### Reading per-machine WU output logs

Each step's output is stored as a gzip file. The filename is in `DeploymentComputerSteps.OutputFile`; the full path is:

```
C:\ProgramData\Admin Arsenal\PDQ Deploy\Deployment Output\<OutputFile>
```

Decompress via PowerShell using `FileStream` (not `MemoryStream` — the byte array overload fails on large files):

```powershell
$ProgressPreference = 'SilentlyContinue'
$in  = New-Object System.IO.FileStream('C:\ProgramData\...\file.gz', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
$gz  = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
$sr  = New-Object System.IO.StreamReader($gz)
$sr.ReadToEnd()
$sr.Close(); $gz.Close(); $in.Close()
```

**Output format** — each installed update appears as:

```
3 MACHINENAME  Installed  KB5040442  500MB 2024-10 Cumulative Update for Windows 11 ...
```

### Detecting Cumulative Updates to set reboot wait time

After a WU deployment, read the output logs for all machines and check for `Installed` lines containing `"Cumulative Update"`. Use this to decide the post-reboot wait:

- **Any machine installed a CU → wait 20 minutes**
- **No CUs installed → wait 5 minutes**

Query to get all output file names for a deployment:
```sql
SELECT dc.Name, dcs.OutputFile
FROM DeploymentComputerSteps dcs
JOIN DeploymentComputers dc ON dcs.DeploymentComputerId = dc.DeploymentComputerId
WHERE dc.DeploymentId = <id>
```

---

## Collections

| Name | Description |
|---|---|
| `PROD` | Production servers — F5 downtime required before patching |
| `DEV/QA/VDI` | Dev, QA, and VDI machines |
| `Backup` | Backup infrastructure |
| `Intune Management Extension` | Windows endpoints where IME is installed and reporting |

---

## Vendor AI-agent skill files (shipped in 20.1.8.0)

PDQ 20.1.8.0 (7/27/2026) added *"an AI coding agent skill file documenting all CLI commands for use with
Claude Code, OpenCode, and other AI-assisted tools and agentic workflows."* These ship **inside the install
directories** so agents discover them automatically:

```
C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\.opencode\skills\pdq-deploy\SKILL.md
C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\.opencode\skills\pdq-inventory\SKILL.md
```

Both are mirrored in this repo under `vendor-skills/` so they can be read without SSH:

| File | Source |
|---|---|
| `vendor-skills/pdq-deploy-SKILL.md` | 914 lines — every `PDQDeploy.exe` command |
| `vendor-skills/pdq-inventory-SKILL.md` | 1137 lines — every `PDQInventory.exe` command |

Each command entry carries **Description, License (Free/Enterprise), Syntax, Parameters, Exit Codes,
Examples, Notes**. The vendor files are stamped `Last updated: 2026-06-01` — i.e. they predate the
20.1.8.0 release that shipped them, so treat `PDQDeploy Help <Command>` on the box as the tiebreaker.

**Re-pull after every PDQ upgrade** — they are overwritten by the installer:

```bash
for p in "PDQ Deploy\\.opencode\\skills\\pdq-deploy" "PDQ Inventory\\.opencode\\skills\\pdq-inventory"; do
  ssh -n -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" "type \"C:\\Program Files (x86)\\Admin Arsenal\\$p\\SKILL.md\"" | tr -d '\r'
done
```

**Note the vendor docs assume an elevated local shell and the install dir on `PATH`** (`PDQDeploy <cmd>`).
Over SSH that PATH assumption does not hold — always use the full quoted EXE path.

---

## PDQ Deploy CLI — full command list (20.1.8.0)

All verified present via `PDQDeploy.exe Help` on SVPDQHQ01. **Ent** = Enterprise licence required.

| Command | Lic | Purpose |
|---|---|---|
| `ApproveAutoDownloads` | Free | List/approve pending auto-download package versions (`-All`, `-Package`, `-Force`) |
| `BackgroundService` | Free | Start/stop/restart the Deploy service |
| `BackupDatabase` | Free | On-demand DB backup (`-Path`, `-Force`) — **new in 20.1.8.0** |
| `CheckDatabase` | Free | SQLite integrity check |
| `CleanUnusedRepoFiles` | Free | Delete unreferenced repo files (`-WhatIf`, `-Force`) |
| `ConsoleUsers` | Ent | List/add/delete console users |
| `CreateCustomVariable` | Ent | Create a custom variable |
| `Database` | Free | Open the Deploy DB in bundled `sqlite3.exe` |
| `DatabaseCleanup` | Ent | Multi-step stale-data cleanup |
| `DeletePackages` | Free | Delete packages (`-Name`, comma-separated, wildcards) |
| `DeleteScheduleHistory` | Ent | Clear a computer's history from one/all schedules |
| `Deploy` | Ent | Deploy a package to targets — see below |
| `ExportPackages` / `ImportPackages` | Free | Package XML export/import |
| `ExportSettings` | Ent | Export all preferences to XML — **new in 20.1.8.0** |
| `ExportVariables` / `ImportVariables` | Ent | Custom-variable XML export/import — **new in 20.1.8.0** |
| `GetDeploymentStatus` | Ent | Query deployment status — see below |
| `GetPackageNames` | Free | List all package names (407 on our box) |
| `GetSchedules` | Ent | List schedules with numeric IDs |
| `Help` | Free | `Help` alone lists commands; `Help <Command>` gives full syntax |
| `OptimizeDatabase` | Free | `VACUUM` the DB (`-Wait`) |
| `ProfileBackgroundService` | Free | Perf profile for diagnostics |
| `RepairDatabase` / `RestoreDatabase` / `SendDatabase` | Free | Corruption recovery / restore / package for support |
| `SetServiceCredentials` | Free | Rotate the service account (PAM workflows) |
| `SetServiceMode` | Ent | Local / Client / Server mode |
| `Settings` | Free | Read/write internal settings |
| `StartSchedule` | Ent | Fire a schedule immediately by ID |
| `SystemInfo` | Free | Version, DB path, service mode, licence |
| `TestCredential` | Free | Test a deploy credential against a target |
| `UpdateCustomVariable` | Free | Update a custom variable's value |
| `UpdateDeployCredential` | Free | Rotate a stored deploy credential |

## PDQ Inventory CLI — full command list (20.1.8.0)

**All of these work** over SSH as `cpp-db\ntsupport`, verified 2026-08-15. They were entirely inaccessible
until the account switch, so anything written before then that says "use SQLite instead" is stale — prefer
the CLI where it is a better fit (see the notes under the table).

| Command | Lic | Purpose |
|---|---|---|
| `ADSync` | Ent | Trigger AD synchronization (`-StartSync`) |
| `AddComputers` | Free | Add computers + scan (`-Credential` assigns scan creds — **new in 20.1.8.0**) |
| `BackgroundService` | Free | Start/stop/restart the Inventory service |
| `BackupDatabase` | Ent | On-demand DB backup |
| `CheckDatabase` | Free | SQLite integrity check |
| `ConsoleUsers` | Ent | List/add/delete console users (**each one consumes a licence**) |
| `CreateCustomField` | Ent | Create a custom field |
| `CreateCustomVariable` / `UpdateCustomVariable` | Ent | Custom variables |
| `Database` | Free | Open the Inventory DB in bundled `sqlite3.exe` |
| `DatabaseCleanup` | Ent | Multi-step stale-data cleanup |
| `DeleteComputers` | Free | Delete computers (`-Force`, `-StopOnError`) — decommission workflows |
| `ExportCollections` / `ImportCollections` | Ent | Collection XML export/import |
| `ExportSettings` | Ent | Export all preferences to XML — **new in 20.1.8.0** |
| `ExportVariables` / `ImportVariables` | Ent | Custom-variable XML export/import |
| `GetAllCollections` / `GetCollection` / `GetCollectionComputers` | Ent | Collection reads |
| `GetAllComputers` / `GetComputer` / `GetOnlineComputers` | Ent | Computer reads |
| `GetAllScanProfiles` / `GetScanProfile` | Ent | Scan profile reads |
| `GetNetworkDiscoveryStatus` | Ent | Discovery status (`-Json`/`-Csv`/`-Brief`) |
| `Help` | Free | Command list / per-command syntax |
| `ImportCustomFields` | Ent | Bulk custom-field import from CSV (`-Preview`, `-WhatIf`) |
| `OptimizeDatabase` | Free | `VACUUM` (stops + restarts the service) |
| `ProfileBackgroundService` | Free | Perf profile for diagnostics |
| `RepairDatabase` / `RestoreDatabase` / `SendDatabase` | Free | Corruption recovery / restore / package for support |
| `RunAutoReport` | Ent | Fire an auto report now (`-Wait`, `-Timeout`) |
| `ScanCollections` / `ScanComputers` | Ent | Queue scans — **`-Wait` blocks until complete** |
| `SetServiceCredentials` / `UpdateScanCredential` / `TestCredential` | Free | Credential rotation (PAM workflows) |
| `SetServiceMode` | Ent | Local / Client / Server mode |
| `Settings` | Free | Read/write internal settings |
| `StartNetworkDiscovery` / `StopNetworkDiscovery` | Ent | Network discovery (one at a time) |
| `SystemInfo` | Free | Version, DB path, service mode, licence |
| `WakeComputer` | Ent | Send Wake-on-LAN |

### Inventory CLI vs SQLite — which to use

SQLite is still the better tool for **arbitrary queries and joins** (pending reboots, scan freshness,
cross-collection filtering) because the CLI has no query language. Use the CLI where it does something
SQLite cannot:

| Need | Use |
|---|---|
| Ad-hoc filtering / joins / counts | **SQLite** — no CLI equivalent |
| Collection membership | either; they agree (46 for PROD, cross-checked) |
| **Force a rescan and wait for it** | **`ScanComputers -Wait`** / `ScanCollections -Wait` — no SQLite equivalent |
| **Trigger an AD sync** | **`ADSync -StartSync`** — previously GUI-only |
| **Delete decommissioned computers** | **`DeleteComputers`** — previously GUI-only |
| Wake a machine before patching | **`WakeComputer`** |
| Fire an auto report | **`RunAutoReport -Wait`** |
| Back up collections before editing | **`ExportCollections`** |

`ScanComputers -Wait` matters most for the patch flow: step 4 currently polls `SuccessfulScanDate` in a
loop, and `-Wait` replaces that polling with a blocking call.

**Gotcha — `-Json`, `-Csv`, `-Quiet` and `-Timeout` all REQUIRE `-Wait`** on `ScanComputers` /
`ScanCollections`. Without it the command just queues the scan and returns, so there is nothing to format
or time out. Verified via `Help ScanComputers` on 20.1.8.0:

```
ScanComputers [[-ScanProfile] string] [-Brief] [-Computers string+] [-Csv] [-IgnoreNotFound]
              [-Json] [-Quiet] [-Timeout integer] [-Wait]
```

32 scan profiles are defined on our box; list them with `GetAllScanProfiles`. `Standard` and
`TheMBC - Standard (-Hotfixes)` / `(-Printers)` are the general-purpose ones.

**Writes are audited.** RBAC (20.0.5.0+) gates CLI actions and the audit log attributes them to the calling
user, now `cpp-db\ntsupport` rather than a local account — so Inventory changes are traceable to a real
identity for the first time.

---

## `GetDeploymentStatus` — replaces SQLite polling

**This is the single biggest win from 20.x for our patching flow.** It returns proper exit codes and emits
JSON, so deployment polling no longer needs a SQLite query.

```
GetDeploymentStatus { -Id <id[,id,...]> | -Name <pkg> | -PackageId <id> | -Running | -Status <s> | -Since <v> }
                    [-All] [-Limit <n>] [-IncludeTargets] [-Json | -Csv]
```

- `-Status` — `Succeeded` | `Failed` | `Running`
- `-Since` — a date (`2026-01-01`) or ISO 8601 duration (`P1D`, `P7D`, `PT2H`)
- `-Limit` — default 500
- `-All` — full history instead of most recent; **only valid with `-Name` or `-PackageId`**

### Exit codes — verified to propagate correctly over SSH

| Code | Meaning |
|---|---|
| 0 | Succeeded (all targets successful), or list shown |
| 1 | Deployment failed (≥1 target failed) **— OR a usage/parameter error** |
| 2 | Still running or queued (querying a single deployment by `-Id`) |
| 3 | Deployment not found |

**Poll a deployment to completion** by looping while the exit code is `2`:

```bash
PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'
ssh -n -q -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" "$PDQ_DEPLOY GetDeploymentStatus -Id $deploy_id" > /tmp/pdq.out 2>&1
deploy_rc=$?   # NOT `status` — reserved in zsh, see CLAUDE.md
```

Do **not** read the exit code through a pipe (`... | tr -d '\r'`) — in zsh `$?` then reports `tr`, always 0.
Redirect to a file, capture `$?`, then post-process.

### Gotchas

**Exit 1 is ambiguous.** It means *either* "one or more targets failed" *or* "you passed bad parameters"
(e.g. `-All -Limit 3` with no selector returns 1 with usage text). Always check the output text before
concluding a deployment failed.

**`-Json` output is NOT clean JSON.** The summary banner is written to stdout **after** the closing `]`:

```
[
  { "Id": 246800, ... }
]
Showing the 1 most recent of 344 matching deployments. Use -Since to narrow the range or -Limit to change the cap.
```

Piping straight into `jq` fails. Strip the trailing banner first, e.g. `sed -n '/^\[/,/^\]/p'`.

**JSON timestamp fields are inconsistent** — `Created` carries a UTC offset (`-07:00`), while `Started`
and `Finished` do not. Don't compare them directly.

**JSON field names differ from the SQLite column names.** `PackageName`, `TotalTargets`, `SuccessRate`,
and per-target `Ended` (not `Finished`).

`-IncludeTargets` adds a `Targets[]` array with per-machine `Name`, `Status` (`Successful`/`Failed`),
`Started`, `Ended`, `Elapsed`, `Error` — that replaces the `DeploymentComputers` join for pass/fail
reporting. It does **not** give per-step output; gzip log reading (below) is still required for CU detection.

---

## Deploying a package via PDQ Deploy CLI

```bash
PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'

ssh -n -q -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" \
    "$PDQ_DEPLOY Deploy -Package \"Package Name\" -Targets MACHINE01 MACHINE02 -UseScanUserCredentials"
```

Full syntax (20.1.8.0):

```
Deploy [-Package] <string> -Targets <string+> [-UserName <credentials>] [-NotificationName <notification>]
       [-OverrideTargetFilters] [-UseScanUserCredentials] [-PrioritizeDeployment]
```

| Parameter | Notes |
|---|---|
| `<package>` | Package **name or numeric ID** |
| `-Targets` | Space-separated computer names. Required. |
| `-UserName` | Credentials profile name; default credentials if omitted |
| `-NotificationName` | Email notification on completion (needs a configured mail server) |
| `-OverrideTargetFilters` | Ignore package target filters. **Was broken until 20.1.8.0** — the fix shipped in that release, so it only actually bypasses the exclusion list on 20.1.8.0+. |
| `-UseScanUserCredentials` | Use Inventory scan-user credentials |
| `-PrioritizeDeployment` | **New in 20.1.8.0.** Jump the queue ahead of non-prioritized deployments. Use for urgent/emergency patching, not routine monthly runs. |

### Gotchas

**PDQ Deploy CLI has no `-Collection` flag.** Resolve collection members via SQLite and pass machine names
individually via `-Targets`. Resolve them with either `PDQInventory GetCollectionComputers "<name>"` or the
SQLite join below — both work and agree (46 for PROD, cross-checked 2026-08-15).

**`Deploy` documents only exit code 0.** Per `Help Deploy`, success is the sole documented code, so it
returns exit 0 even on package-not-found. Always check output text for `not found`, `error`, or `failed`.
(`GetDeploymentStatus` is the opposite — it has real exit codes. Use it for the polling half.)

**PDQ Deploy CLI is asynchronous.** The command returns immediately after queuing the job. Poll with
`GetDeploymentStatus -Id <id>` until the exit code stops being `2` (preferred), or query
`Deployments.Status` in the Deploy DB until `Finished`.

---

## Running PowerShell on SVPDQHQ01 via SSH

Pass scripts base64-encoded (`-EncodedCommand`) to avoid shell quoting issues:

```bash
encoded=$(printf '%s' "$ps_script" | iconv -t UTF-16LE | base64 | tr -d '\n')
ssh -n -q -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" \
    "powershell -NonInteractive -NoProfile -EncodedCommand ${encoded}"
```

Always include `$ProgressPreference = 'SilentlyContinue'` at the top of the script — PowerShell emits CLIXML/progress noise over non-interactive SSH sessions without it.

---

## Diagnostic traps that cost time (2026-08-15)

**sqlite3 against a wrong path returns empty and exit 0 — silently.** No "file not found", just no rows.
Querying `sqlite_master` and getting nothing means *check the path first*, not "the table is missing". The
DBs live under `C:\ProgramData\Admin Arsenal\...`, the `sqlite3.exe` under `C:\Program Files (x86)\...` —
mixing them up produces a convincing empty result.

**PDQ Deploy and PDQ Inventory services are Automatic (Delayed Start).** After a reboot they read `Stopped`
for roughly 2.5 minutes and then come up on their own — SVPDQHQ01 booted 09:36:51 and the services started
09:39:15 and 09:39:18. Do not diagnose a fault in that window.

**Reboot completion is a changed `LastBootUpTime`, not SSH connectivity.** sshd keeps answering well into
the shutdown sequence, so "SSH responded" is a false 'it came back'. This produced two wrong calls in one
session. Capture the boot time first, then poll until it *differs*:

```bash
getboot(){ ssh ... "$HOST" 'powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString(\"MM/dd/yyyy HH:mm:ss\")"' | tr -d '\r\n'; }
```

**A large CU reboots twice.** The second restart is initiated by `TrustedInstaller.exe` ("Operating System:
Upgrade (Planned)") to finish component servicing, several minutes after the first boot. Between the two,
every cheap signal reads "done" — see the Event 19 note in `api/patching/`.

**`ScanComputers` without `-Quiet` floods an SSH stream.** It emits a per-second progress spinner that will
run a tool call to its timeout. `-Quiet` requires `-Wait`.

---

## Version history worth knowing

CLI surface expanded sharply across 20.x. If a command is missing, check the version first.

| Version | Date | CLI-relevant additions |
|---|---|---|
| 20.1.8.0 | 2026-07-27 | **AI coding agent skill files**; `ExportSettings`; `BackupDatabase`; variable export/import; Deploy `ApproveAutoDownloads`; `-PrioritizeDeployment`; `-OverrideTargetFilters` **fixed**; Inventory ARM64 scanning + `AddComputers` scan-credential assignment |
| 20.0.22.0 | 2026-06-29 | Credential rotation (`SetServiceCredentials`, `UpdateDeployCredential`, `UpdateScanCredential`, `TestCredential`); `GetDeploymentStatus`; package export/import/delete; `CleanUnusedRepoFiles`; collection export/import; `DeleteComputers`; **`-Wait` on `ScanComputers`/`ScanCollections`**; `RunAutoReport`; network discovery commands |
| 20.0.5.0 | 2026-04-27 | RBAC + audit logging. **RBAC gates CLI actions too** — a blocked CLI call may be an RBAC denial, not a bug. CLI writes are attributed to the calling user in the audit log. |

## Related

- Vendor skill files: `vendor-skills/` (mirrored from the PDQ install dirs)
- Release notes: https://www.pdq.com/releases/
- Help Center CLI article: https://help.pdq.com/hc/en-us/articles/360050686511 — **thin and stale** (last
  updated 2025-09-24, command lists are screenshots). The `vendor-skills/` files supersede it.
  That page 403s to curl/WebFetch (Zendesk bot block); read it via the help-center API —
  see `api/web-fetch/README.md`.
- Patching skill: `/Users/fperez2nd/.claude/commands/patching.md`
- Collections config: `/Users/fperez2nd/GitHub/api/patching/collections.md`
