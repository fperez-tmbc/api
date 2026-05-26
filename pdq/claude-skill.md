Load context for PDQ Deploy & Inventory tasks and carry out the request in `$ARGUMENTS`.

## Context

- **API reference & gotchas:** `/Users/fperez2nd/GitHub/api/pdq/README.md`
- **Server:** `SVPDQHQ01.cpp-db.com` — SSH as `claude`
- **Credentials:** `~/GitHub/.tokens/patching` — source for `$PDQ_PASS`
- **Patching automation:** `/Users/fperez2nd/GitHub/patching/`

## On Invocation

1. Read `/Users/fperez2nd/GitHub/api/pdq/README.md` to load current gotchas and path references.
2. Parse `$ARGUMENTS` for the operation requested.
3. If `$ARGUMENTS` is blank or `help`, display available operations and stop.
4. Execute using SSH + sqlite3 or PDQDeploy.exe as appropriate.

## SSH helper

```bash
source ~/GitHub/.tokens/patching
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" "<command>"
```

## Operations

### `collection <name>`
List all computers in a PDQ Inventory collection.

Query `Computers → CollectionComputers → Collections` via sqlite3 on the Inventory DB.
Use `SELECT DISTINCT` — machines can belong to multiple sub-collections.

### `pending-reboots <collection>`
List machines in a collection with `NeedsReboot = 1`.

### `compare-entra <pdq-collection> <entra-group-name>`
Compare a PDQ collection against an Entra ID group and show the diff.

1. Query PDQ collection members via SSH + sqlite3.
2. Query Entra group members via Graph API (reuse igraph auth pattern from `/Users/fperez2nd/GitHub/api/intune/igraph`).
3. Show: in Entra but not PDQ / in PDQ but not Entra.

### `deploy <package> <machine> [machine...]`
Deploy a PDQ Deploy package to one or more machines.

1. Run `PDQDeploy.exe Deploy -Package "..." -Targets ... -UseScanUserCredentials` over SSH.
2. Check output for error text (CLI returns exit 0 even on failure).
3. Parse deployment ID from output and poll `Deployments.Status` until `Finished`.

### `collections`
List all collection names in PDQ Inventory.

```sql
SELECT Name FROM Collections ORDER BY Name
```

### `patch <collection>` (no F5)
Orchestrate a full monthly patch run for a collection that does NOT require F5 downtime.

**Process — repeat until clean:**

1. **Get members** — query collection via SQLite (`SELECT DISTINCT`) to build the target list.
2. **Deploy WU** — `PDQDeploy.exe Deploy -Package "PSWindowsUpdate - Install All Applicable Updates from Microsoft" -Targets <machines> -UseScanUserCredentials`
3. **Poll until Finished** — query `Deployments.Status` every 60 s until `'Finished'`.
4. **Check scan freshness** — immediately query how many collection members have `SuccessfulScanDate < Deployments.Started`. If already 0, proceed. If not, poll every 30 s until 0. Use `Started` (not `Finished`) as the reference — scans happen per-machine during the deployment window.
5. **Query pending reboots** — `NeedsReboot = 1` for collection members.
6. **If reboots pending:**
   a. **Send reboots first** — `PDQDeploy.exe Deploy -Package "Reboot" -Targets <pending machines>`
   b. **Check output logs (short-circuit)** — read gzip output logs for deployment from step 2 one machine at a time; stop on the first machine where a line matches `Installed\s+KB\S+\s+\S+\s+.*Cumulative Update`. Do NOT read all machines.
   c. **Wait** — 20 min if CU found, 5 min if not.
   d. Poll reboot deployment until `Finished`, then loop back to step 2 targeting only the rebooted machines (except cycles 1 and 2 which always target the full collection).
7. **If no reboots pending and cycle ≥ 2** — exit cleanly.

**Cycle targets:**
- Cycle 1: full collection (mandatory)
- Cycle 2: full collection (mandatory)
- Cycle 3+: only machines rebooted in the prior cycle

**CU log check PowerShell (short-circuit):**
```powershell
$ProgressPreference = 'SilentlyContinue'
$sqliteExe = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
$deployDb  = 'C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db'
$outputDir = 'C:\ProgramData\Admin Arsenal\PDQ Deploy\Deployment Output'
$rows = & $sqliteExe $deployDb "SELECT dc.Name || '|' || COALESCE(dcs.OutputFile,'') FROM DeploymentComputerSteps dcs JOIN DeploymentComputers dc ON dcs.DeploymentComputerId = dc.DeploymentComputerId WHERE dc.DeploymentId = $deployId AND dcs.OutputFile != ''"
foreach ($row in $rows) {
    $parts = $row -split '\|', 2; $machine = $parts[0]; $file = $parts[1]
    $path = Join-Path $outputDir $file
    if (-not (Test-Path $path)) { continue }
    $in = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz)
    $content = $sr.ReadToEnd(); $sr.Close(); $gz.Close(); $in.Close()
    if ($content -match 'Installed\s+KB\S+\s+\S+\s+.*Cumulative Update') { Write-Output "CU_FOUND|$machine"; exit 0 }
}
Write-Output 'NO_CU'
```
