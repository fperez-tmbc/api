# PDQ Deploy & Inventory — Lessons Learned

**Installed version: 20.1.8.0** (Deploy and Inventory, both Enterprise, ServiceMode `Local`).

## Connection

- **Server:** `SVPDQHQ01.cpp-db.com`
- **SSH user:** `claude`
- **Credentials:** `~/GitHub/.tokens/patching` — source this file; use `$PDQ_PASS`

```bash
source ~/GitHub/.tokens/patching
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" "<command>"
```

### `claude` account — capabilities & limits
- **Read-only SQLite + PDQ Deploy only.** The `claude` account can query the Inventory/Deploy DBs directly (sqlite3) and run the **entire PDQ Deploy CLI** — verified against 20.1.8.0, including the newer `GetDeploymentStatus`, `GetPackageNames`, `GetSchedules`, `SystemInfo`, and `Help`.
- **The ENTIRE PDQ Inventory CLI is BLOCKED — including read-only commands.** `ADSync`, `DeleteComputers`, `ScanComputers`, and also `GetAllCollections`, `GetCollectionComputers`, `GetAllComputers`, `GetOnlineComputers` all return:
  `Access denied to PDQ Inventory background service. Contact your system administrator to add SVPDQHQ01\claude to Console Users`
  Everything except `PDQInventory SystemInfo` (which reads local install metadata, not the service) hits this wall.
- **Consequence:** the 20.0.22.0 Inventory read commands do NOT give us a shortcut. **SQLite remains the only way to read Inventory as `claude`.** Do not rewrite collection lookups to use `GetCollectionComputers`.
- **Not granted on purpose:** a PDQ Inventory **Console User consumes a license** (Frank, 2026-07-21), so `claude` is intentionally left out. To add / sync / delete computers in Inventory, do it in the console GUI (or Frank runs the CLI). Don't propose adding `claude` to Console Users.

### AD sync / disabled computers
- `Computers.ADIsDisabled` is a **string** (`'Enabled'` / `'Disabled'`), NOT `1/0`. Filter with `WHERE ADIsDisabled='Disabled'`.
- **AD Sync does not delete *disabled* computers** — it only removes computers no longer present in the synced AD scope. In practice all inventory machines show `Enabled` (the sync scope excludes disabled accounts), so a decommissioned/disabled machine is dropped when the scheduled AD sync re-reads it, or delete it manually in the console. SVPRINTHQ01 was already gone this way; SVFSAU01 will drop on the next sync (or manual delete).

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

SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
    "$PDQ_SQLITE \"$PDQ_INV_DB\" \"<SQL query>\""
```

### Key tables — PDQ Inventory

| Table | Key columns |
|---|---|
| `Computers` | `ComputerId`, `Name`, `NeedsReboot`, `SuccessfulScanDate` |
| `Collections` | `CollectionId`, `Name` |
| `CollectionComputers` | `ComputerId`, `CollectionId` |

Use `SELECT DISTINCT` on collection membership queries — machines can belong to multiple sub-collections.

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
source ~/GitHub/.tokens/patching
for p in "PDQ Deploy\\.opencode\\skills\\pdq-deploy" "PDQ Inventory\\.opencode\\skills\\pdq-inventory"; do
  SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" "type \"C:\\Program Files (x86)\\Admin Arsenal\\$p\\SKILL.md\"" | tr -d '\r'
done
```

**Note the vendor docs assume an elevated local shell and the install dir on `PATH`** (`PDQDeploy <cmd>`).
Over SSH as `claude` that PATH assumption does not hold — always use the full quoted EXE path.

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
| `GetPackageNames` | Free | List all package names (419 on our box) |
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

**All of these are blocked for `claude` except `SystemInfo`** (see capabilities above). Listed for when
Frank runs them from an elevated console session.

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
| `SystemInfo` | Free | **The only Inventory command `claude` can run** |
| `WakeComputer` | Ent | Send Wake-on-LAN |

---

## `GetDeploymentStatus` — replaces SQLite polling

**This is the single biggest win from 20.x for our patching flow.** It works as `claude`, returns proper
exit codes, and emits JSON — so deployment polling no longer needs a SQLite query.

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
source ~/GitHub/.tokens/patching
PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" "$PDQ_DEPLOY GetDeploymentStatus -Id $deploy_id" > /tmp/pdq.out 2>&1
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

SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
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
individually via `-Targets`. The Inventory `GetCollectionComputers` command would do this, but it is blocked
for `claude` — see capabilities above.

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
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
    "powershell -NonInteractive -NoProfile -EncodedCommand ${encoded}"
```

Always include `$ProgressPreference = 'SilentlyContinue'` at the top of the script — PowerShell emits CLIXML/progress noise over non-interactive SSH sessions without it.

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
