Patch the PDQ collection specified in `$ARGUMENTS` using the correct flow (F5 or non-F5).

## On Invocation

1. Read `/Users/fperez2nd/GitHub/api/patching/collections.md` to determine if the collection requires F5 commands and which config key to use.
2. Source `~/GitHub/.tokens/patching` for `$PDQ_PASS` and `$F5_PASS`.
3. Run the patch job autonomously in the background — no waiting for user prompts between steps.

---

## Patch Flow

### Non-F5 collections

Run the autonomous patch loop below directly.

### F5 collections

1. **Disable F5 pool members** (REST API — see config in collections.md)
2. **Run autonomous patch loop**
3. **Enable F5 pool members** (REST API — see config in collections.md)

**F5 REST pattern:**
```bash
curl -sk -u "admin:${F5_PASS}" -X PATCH \
  "https://mkf5prod01.cpp-db.com/mgmt/tm/ltm/pool/~Common~<POOL>/members/~Common~<MEMBER>" \
  -H "Content-Type: application/json" \
  -d '{"session":"user-disabled"}'
# Enable: {"session":"user-enabled","state":"user-up"}
```

---

## Autonomous Patch Loop (zsh)

**Critical requirements — learned from prior bugs:**
- Use `("${(@f)$(...)}")` for zsh arrays from command output (NOT `mapfile` — bash-only)
- Pipe all SSH output through `| tr -d '\r'` — Windows CR characters break string comparisons
- Use `COUNT(DISTINCT c.ComputerId)` in scan freshness query — machines in multiple sub-collections cause double-counting without DISTINCT
- Use `||` for SQLite string concatenation in the CU check PowerShell query — NOT `+`. SQLite's `+` does numeric addition and coerces strings to 0, so all rows return `0` and no output files are ever found.
- Scan/reboot queries cannot JOIN across the Deploy and Inventory SQLite databases. Fetch the machine list from DEPLOY_DB (`SELECT Name FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID`) then build an IN clause for INV_DB queries.
- Always include `-o ConnectTimeout=15` on SSH calls to prevent silent hangs
- Use `if [[ "$VAR" == "value" ]]; then break; fi` — NOT `[[ ]] && break` (unreliable in zsh loops)
- Use epoch-based waits: `TARGET_EPOCH=$(( $(date '+%s') + MIN * 60 ))` + `until [[ $(date '+%s') -ge $TARGET_EPOCH ]]; do sleep 10; done`

**Scan freshness:** After deployment is `Finished`, immediately check `COUNT(DISTINCT c.ComputerId)` where `SuccessfulScanDate < Deployments.Started`. Use `Started` (not `Finished`) — scans happen per-machine during the deployment window. If already 0, proceed immediately. If not, poll every 30 s.

**Cycle targets:**
- Cycle 1: full collection (mandatory)
- Cycle 2: full collection (mandatory)
- Cycle 3+: only machines rebooted in the prior cycle

**Reboot order within a cycle:**
1. Query pending reboots
2. Send `"Reboot"` package to pending machines **first**
3. Then check output logs for CU detection (short-circuit — stop on first machine with a CU)
4. Wait 20 min if CU found, 5 min if not

```zsh
source ~/GitHub/.tokens/patching

PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'
PDQ_DEPLOY_DB='C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db'
PDQ_INV_DB='C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db'
PDQ_SQLITE='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe"'
WU_PKG="PSWindowsUpdate - Install All Applicable Updates from Microsoft"
REBOOT_PKG="Reboot"
# COLLECTION must be set before running

pdq_ssh() {
    SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "claude@SVPDQHQ01.cpp-db.com" "$1" | tr -d '\r'
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ALL_MACHINES=("${(@f)$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT DISTINCT c.Name FROM Computers c JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId JOIN Collections col ON cc.CollectionId = col.CollectionId WHERE col.Name = '$COLLECTION' ORDER BY c.Name\"")}")
log "Collection '$COLLECTION': ${ALL_MACHINES[*]}"

TARGETS=("${ALL_MACHINES[@]}")
CYCLE=0
PREV_REBOOTS=""

while true; do
    CYCLE=$((CYCLE + 1))
    [[ $CYCLE -gt 10 ]] && log "ERROR: Exceeded max cycles. Aborting." && exit 1
    log "=== CYCLE $CYCLE — Targets: ${TARGETS[*]} ==="

    DEPLOY_OUT=$(pdq_ssh "$PDQ_DEPLOY Deploy -Package \"$WU_PKG\" -Targets ${TARGETS[*]} -UseScanUserCredentials")
    echo "$DEPLOY_OUT"
    DEPLOY_ID=$(echo "$DEPLOY_OUT" | awk '/^ID/{print $3}')
    [[ -z "$DEPLOY_ID" ]] && log "ERROR: Could not parse deployment ID." && exit 1
    log "Deployment ID: $DEPLOY_ID"

    STATUS=""; STARTED=""
    for i in $(seq 1 90); do
        ROW=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Status || '|' || Started FROM Deployments WHERE DeploymentId = $DEPLOY_ID\"")
        STATUS=$(echo "$ROW" | cut -d'|' -f1)
        STARTED=$(echo "$ROW" | cut -d'|' -f2)
        log "Deployment $DEPLOY_ID — $STATUS"
        if [[ "$STATUS" == "Finished" ]]; then break; fi
        sleep 60
    done
    [[ "$STATUS" != "Finished" ]] && log "ERROR: Deployment timed out." && exit 1

    pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Name, Status, COALESCE(Error,'') FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID ORDER BY Name\""

    # Get machine names for this deployment (DEPLOY_DB); use IN clause for INV_DB queries
    CYCLE_MACHINES=("${(@f)$(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Name FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID ORDER BY Name\"")}")
    CYCLE_IN=$(printf "'%s'," "${CYCLE_MACHINES[@]}"); CYCLE_IN="${CYCLE_IN%,}"

    for i in $(seq 1 30); do
        PENDING_SCANS=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT COUNT(DISTINCT ComputerId) FROM Computers WHERE Name IN ($CYCLE_IN) AND (SuccessfulScanDate IS NULL OR SuccessfulScanDate < '$STARTED')\"")
        log "Machines not yet rescanned: $PENDING_SCANS"
        if [[ "$PENDING_SCANS" == "0" ]]; then break; fi
        sleep 30
    done

    REBOOT_MACHINES=("${(@f)$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT DISTINCT Name FROM Computers WHERE Name IN ($CYCLE_IN) AND NeedsReboot = 1 ORDER BY Name\"")}")
    REBOOT_LIST="${REBOOT_MACHINES[*]}"
    log "Pending reboots: ${REBOOT_LIST:-none}"

    if [[ -z "$REBOOT_LIST" ]]; then
        if [[ $CYCLE -ge 2 ]]; then
            log "No pending reboots after cycle $CYCLE. Patch loop complete."
            exit 0
        fi
        log "No reboots after cycle 1 — proceeding to mandatory cycle 2."
        TARGETS=("${ALL_MACHINES[@]}")
        continue
    fi

    if [[ "$REBOOT_LIST" == "$PREV_REBOOTS" && $CYCLE -gt 2 ]]; then
        log "ERROR: Same reboot list two cycles in a row. Aborting."
        exit 1
    fi
    PREV_REBOOTS="$REBOOT_LIST"

    log "Sending reboots to: ${REBOOT_MACHINES[*]}"
    REBOOT_OUT=$(pdq_ssh "$PDQ_DEPLOY Deploy -Package \"$REBOOT_PKG\" -Targets ${REBOOT_MACHINES[*]} -UseScanUserCredentials")
    echo "$REBOOT_OUT"
    REBOOT_DEPLOY_ID=$(echo "$REBOOT_OUT" | awk '/^ID/{print $3}')
    log "Reboot deployment ID: $REBOOT_DEPLOY_ID"

    log "Checking output logs for Cumulative Updates..."
    PS_SCRIPT="\$ProgressPreference = 'SilentlyContinue'
\$sqliteExe = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
\$deployDb  = 'C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db'
\$outputDir = 'C:\ProgramData\Admin Arsenal\PDQ Deploy\Deployment Output'
\$deployId  = $DEPLOY_ID
\$rows = & \$sqliteExe \$deployDb \"SELECT dc.Name || '|' || COALESCE(dcs.OutputFile,'') FROM DeploymentComputerSteps dcs JOIN DeploymentComputers dc ON dcs.DeploymentComputerId = dc.DeploymentComputerId WHERE dc.DeploymentId = \$deployId AND dcs.OutputFile != ''\"
foreach (\$row in \$rows) {
    \$parts = \$row -split '\|', 2; \$machine = \$parts[0]; \$file = \$parts[1]
    \$path = Join-Path \$outputDir \$file
    if (-not (Test-Path \$path)) { continue }
    try {
        \$in = New-Object System.IO.FileStream(\$path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        \$gz = New-Object System.IO.Compression.GZipStream(\$in, [System.IO.Compression.CompressionMode]::Decompress)
        \$sr = New-Object System.IO.StreamReader(\$gz)
        \$content = \$sr.ReadToEnd(); \$sr.Close(); \$gz.Close(); \$in.Close()
        if (\$content -match 'Installed\s+KB\S+\s+\S+\s+.*Cumulative Update') { Write-Output \"CU_FOUND|\$machine\"; exit 0 }
    } catch { continue }
}
Write-Output 'NO_CU'"
    ENCODED=$(printf '%s' "$PS_SCRIPT" | iconv -t UTF-16LE | base64 | tr -d '\n')
    CU_RESULT=$(SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "claude@SVPDQHQ01.cpp-db.com" \
        "powershell -NonInteractive -NoProfile -EncodedCommand ${ENCODED}" | tr -d '\r')
    log "CU check: $CU_RESULT"

    [[ "$CU_RESULT" == CU_FOUND* ]] && WAIT_MIN=20 || WAIT_MIN=5
    log "Waiting $WAIT_MIN minutes for reboots to complete..."
    TARGET_EPOCH=$(( $(date '+%s') + WAIT_MIN * 60 ))
    until [[ $(date '+%s') -ge $TARGET_EPOCH ]]; do sleep 10; done
    log "${WAIT_MIN}-minute wait complete."

    for i in $(seq 1 30); do
        RB_STATUS=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Status FROM Deployments WHERE DeploymentId = $REBOOT_DEPLOY_ID\"")
        log "Reboot deployment $REBOOT_DEPLOY_ID — $RB_STATUS"
        if [[ "$RB_STATUS" == "Finished" ]]; then break; fi
        sleep 30
    done

    if [[ $CYCLE -ge 2 ]]; then
        TARGETS=("${REBOOT_MACHINES[@]}")
    else
        TARGETS=("${ALL_MACHINES[@]}")
    fi
done
```
