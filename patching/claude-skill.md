Patch the PDQ collection specified in `$ARGUMENTS` using the correct flow (F5 or non-F5).

## On Invocation

1. Read `/Users/fperez2nd/GitHub/api/patching/collections.md` to determine if the collection requires F5 commands and which config key to use.
2. Source `~/GitHub/.tokens/patching` for `$F5_PASS`. SSH to SVPDQHQ01 is key auth as `ntsupport@cpp-db.com` — no password needed.
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

## CU completion confirmation (Event ID 19)

After a reboot that followed a **Cumulative Update**, the 20 minutes is a **ceiling, not a fixed wait**.
`api/patching/cu-confirm.sh` polls every rebooted machine until each logs
`Microsoft-Windows-WindowsUpdateClient` **Event ID 19** ("Installation Successful"); the loop proceeds as
soon as all confirm, and **stops the run and emails Frank** if the ceiling is reached.

**Why not the reboot flags.** They lie. On SVPDQHQ01 (2026-08-15) `CBS RebootPending`, `WU RebootRequired`,
`PendingFileRenameOperations`, the already-updated UBR **and PDQ's own `NeedsReboot`** all read "done" at
11:02 — and TrustedInstaller rebooted the machine again at 11:05:46. Event 19 landed at 11:07:29, after the
second reboot. Trigger-to-genuinely-done was **11.5 minutes**, which is what the 20-minute ceiling covers.

**Transport: WMI/DCOM (`Win32_NTLogEvent`), not `Get-WinEvent`.** `Get-WinEvent -ComputerName` uses the
Remote Event Log RPC endpoint, which some hosts do not answer — `NEDVVDMC01`/`NEDVVDMC02` hang ~21 s then
fail "RPC server is unavailable" *even with correct credentials*, while WMI answers in ~1 s. WMI is the
channel PDQ already scans over, so it reaches everything PDQ manages.

**Credentials are per-domain**, mapped from PDQ Inventory's `ADDomain` column (no DNS guessing) to the
matching Key Vault secret. DEV/QA/VDI alone spans three domains: 34 `cpp-db.com`, 2 `opp.local`,
3 `oppnewapp.local`. Passwords differ per domain even where the account name repeats, and they are passed
on **stdin, never argv**. OPP domains lock out at 5 attempts — one attempt per host.

Measured: 17 machines across 3 domains confirmed in **8.4 s** total.

**Non-CU reboots keep the flat 5-minute wait** — unchanged, and deliberately so.

The `patch-svsqlmismk01-resume.sh` 20-minute wait is **not** a CU wait; it covers SQL service-pack
post-reboot work, which may never emit Event 19. It is deliberately left as a flat wait.

---

## Autonomous Patch Loop (zsh)

**Critical requirements — learned from prior bugs:**
- Use `while IFS= read -r line; do [[ -n "$line" ]] && ARRAY+=("$line"); done < <(command)` for arrays from command output — works in **both** bash (Git Bash on Windows) and zsh (Mac). Do **not** use `mapfile` (bash-only) or `("${(@f)$(...)}")` (zsh-only); the scripts run on both.
- Pipe all SSH output through `| tr -d '\r'` — Windows CR characters break string comparisons
- Use `COUNT(DISTINCT c.ComputerId)` in scan freshness query — machines in multiple sub-collections cause double-counting without DISTINCT
- Use `||` for SQLite string concatenation in the CU check PowerShell query — NOT `+`. SQLite's `+` does numeric addition and coerces strings to 0, so all rows return `0` and no output files are ever found.
- Scan/reboot queries cannot JOIN across the Deploy and Inventory SQLite databases. Fetch the machine list from DEPLOY_DB (`SELECT Name FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID`) then build an IN clause for INV_DB queries.
- Always include `-o ConnectTimeout=15` on SSH calls to prevent silent hangs
- Use `if [[ "$VAR" == "value" ]]; then break; fi` — NOT `[[ ]] && break` (unreliable in zsh loops)
- Use epoch-based waits: `TARGET_EPOCH=$(( $(date '+%s') + MIN * 60 ))` + `until [[ $(date '+%s') -ge $TARGET_EPOCH ]]; do sleep 10; done`

**Scan freshness:** After deployment is `Finished`, immediately check `COUNT(DISTINCT c.ComputerId)` where `SuccessfulScanDate < Deployments.Started`. Use `Started` (not `Finished`) — scans happen per-machine during the deployment window. If already 0, proceed immediately. If not, poll every 30 s, up to 10 times (5 min).

**If the poll does not converge, force it — do not fall through.** `PDQInventory ScanComputers -Computers <stragglers> -Wait -Quiet -Timeout 900` blocks until the rescan finishes, then re-check. This closes a real gap: the loop used to time out silently after 15 min and `NeedsReboot` was then read from *pre-deployment* data, so a machine whose scan lagged could have its pending reboot missed and be declared clean. The Inventory CLI only became reachable to automation on 2026-08-15. Note `-Quiet` and `-Timeout` both **require** `-Wait`.

**Cycle targets:**
- Cycle 1: full collection (mandatory)
- Cycle 2: full collection (mandatory)
- Cycle 3+: only machines rebooted in the prior cycle

**Reboot order within a cycle:**
1. Query pending reboots
2. Send `"Reboot"` package to pending machines **first**
3. Then check output logs for CU detection (short-circuit — stop on first machine with a CU)
4. Wait 20 min if CU found, 5 min if not

```bash
source ~/GitHub/.tokens/patching 2>/dev/null

PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'
PDQ_INVENTORY='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe"'
PDQ_DEPLOY_DB='C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db'
PDQ_INV_DB='C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db'
PDQ_SQLITE='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe"'
WU_PKG="PSWindowsUpdate - Install All Applicable Updates from Microsoft"
REBOOT_PKG="Reboot"
# COLLECTION must be set before running, e.g. COLLECTION='PROD'

if [[ -f ~/.ssh/id_ed25519_pdq ]]; then SSH_KEY=~/.ssh/id_ed25519_pdq; else SSH_KEY=~/.ssh/id_ed25519; fi

pdq_ssh() {
    ssh -n -q -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" "$1" | tr -d '\r'
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Emails Frank and stops the run when CU completion cannot be confirmed.
send_pause_email() {
    local unconfirmed="$1" detail="$2" py
    py=$(command -v python3 || command -v python)
    [[ -z "$py" ]] && { log "WARNING: no python found - could not send pause email"; return 1; }
    "$py" - "$COLLECTION" "$unconfirmed" "$detail" <<'PY'
import sys, smtplib
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
coll, unconfirmed, detail = sys.argv[1], sys.argv[2], sys.argv[3]
body = f"""Patching PAUSED: {coll}

A Cumulative Update was installed and reboots were sent, but one or more
machines did not confirm the update finished within the 20-minute ceiling.

The run has STOPPED. Nothing further has been deployed. No later cycle ran.

Unconfirmed machines:
  {unconfirmed}

Confirmation signal: WindowsUpdateClient Event ID 19 ("Installation
Successful") in the System log, queried over WMI. This is used because the
cheap signals lie -- on SVPDQHQ01 the reboot flags, updated build number and
PDQ's own NeedsReboot all read "done" about five minutes before servicing
rebooted the machine a second time.

An unconfirmed machine means one of:
  - still applying the update and slower than 20 minutes
  - stuck mid-servicing, or failed to come back from its reboot
  - reachable by PDQ but not answering WMI

Checker output:
{detail}

Next step: check those machines directly, then resume with the collection's
resume script once they are healthy.
"""
m = EmailMessage()
m["From"] = "Claude Patching <claude-notify@themyersbriggs.com>"
m["To"] = "fperez@themyersbriggs.com"
m["Subject"] = f"[Action needed] Patching PAUSED: {coll} - CU completion not confirmed"
m["Date"] = formatdate(localtime=True); m["Message-ID"] = make_msgid(domain="themyersbriggs.com")
m.set_content(body)
s = smtplib.SMTP("owa.themyersbriggs.com", 25, timeout=30)
s.ehlo("svpdqhq01.cpp-db.com"); s.send_message(m); s.quit()
print("PAUSE EMAIL SENT")
PY
}


COLLECTION_ID=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT CollectionId FROM Collections WHERE Name = '$COLLECTION' AND Path LIKE 'CPP Patch Groups%' ORDER BY CollectionId\"")
ID_COUNT=$(printf '%s\n' "$COLLECTION_ID" | grep -c .)
if [[ "$ID_COUNT" -ne 1 ]]; then
    log "ERROR: Expected exactly one '$COLLECTION' collection under 'CPP Patch Groups', found $ID_COUNT (ids: $(printf '%s ' $COLLECTION_ID)). Aborting."
    exit 1
fi
log "Resolved '$COLLECTION' to CollectionId $COLLECTION_ID"

ALL_MACHINES=()
while IFS= read -r line; do [[ -n "$line" ]] && ALL_MACHINES+=("$line"); done < <(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT DISTINCT c.Name FROM Computers c JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId WHERE cc.CollectionId = $COLLECTION_ID ORDER BY c.Name\"")
[[ ${#ALL_MACHINES[@]} -eq 0 ]] && log "ERROR: Collection '$COLLECTION' (id $COLLECTION_ID) has no members. Aborting." && exit 1
log "Collection '$COLLECTION' (id $COLLECTION_ID, ${#ALL_MACHINES[@]} machines): ${ALL_MACHINES[*]}"

TARGETS=("${ALL_MACHINES[@]}")
CYCLE=0
PREV_WORK=""

while true; do
    CYCLE=$((CYCLE + 1))
    [[ $CYCLE -gt 10 ]] && log "ERROR: Exceeded max cycles. Aborting." && exit 1
    log "=== CYCLE $CYCLE — Targets: ${TARGETS[*]} ==="

    DEPLOY_OUT=$(pdq_ssh "$PDQ_DEPLOY Deploy -Package \"$WU_PKG\" -Targets ${TARGETS[*]} -UseScanUserCredentials")
    echo "$DEPLOY_OUT"
    DEPLOY_ID=$(echo "$DEPLOY_OUT" | awk '/^ID/{print $NF}')
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

    CYCLE_MACHINES=()
    while IFS= read -r line; do [[ -n "$line" ]] && CYCLE_MACHINES+=("$line"); done < <(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Name FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID ORDER BY Name\"")
    CYCLE_IN=$(printf "'%s'," "${CYCLE_MACHINES[@]}"); CYCLE_IN="${CYCLE_IN%,}"

    FAILED_MACHINES=()
    while IFS= read -r line; do [[ -n "$line" ]] && FAILED_MACHINES+=("$line"); done < <(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Name FROM DeploymentComputers WHERE DeploymentId = $DEPLOY_ID AND Status <> 'Successful' ORDER BY Name\"")
    FAILED_LIST="${FAILED_MACHINES[*]}"
    [[ -n "$FAILED_LIST" ]] && log "Failed this cycle (will retry): $FAILED_LIST"

    # Wait for the automatic post-deployment scans. PDQ scans each machine as its
    # own step completes, so this normally converges well inside the window.
    SCAN_STALE_SQL="SELECT COUNT(DISTINCT ComputerId) FROM Computers WHERE Name IN ($CYCLE_IN) AND (SuccessfulScanDate IS NULL OR SuccessfulScanDate < '$STARTED')"
    for i in $(seq 1 30); do
        PENDING_SCANS=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"$SCAN_STALE_SQL\"")
        log "Machines not yet rescanned: $PENDING_SCANS"
        if [[ "$PENDING_SCANS" == "0" ]]; then break; fi
        sleep 30
    done

    # Never read NeedsReboot off stale Inventory data. Previously this loop just
    # timed out and fell through, so a machine whose scan lagged could be read
    # from pre-deployment data and its pending reboot missed. The Inventory CLI
    # became reachable 2026-08-15, so force a scan on the stragglers and block.
    if [[ "$PENDING_SCANS" != "0" ]]; then
        STALE_MACHINES=()
        while IFS= read -r line; do [[ -n "$line" ]] && STALE_MACHINES+=("$line"); done < <(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT DISTINCT Name FROM Computers WHERE Name IN ($CYCLE_IN) AND (SuccessfulScanDate IS NULL OR SuccessfulScanDate < '$STARTED') ORDER BY Name\"")
        if [[ ${#STALE_MACHINES[@]} -eq 0 ]]; then
            log "WARNING: stale count was '$PENDING_SCANS' but no stale machines resolved (query returned nothing?) - skipping forced rescan."
        else
            log "Forcing rescan of ${#STALE_MACHINES[@]} machine(s): ${STALE_MACHINES[*]}"
            pdq_ssh "$PDQ_INVENTORY ScanComputers -Computers ${STALE_MACHINES[*]} -Wait -Quiet -Timeout 900" >/dev/null
            PENDING_SCANS=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"$SCAN_STALE_SQL\"")
            if [[ "$PENDING_SCANS" == "0" ]]; then
                log "Forced rescan complete - Inventory is current."
            else
                log "WARNING: $PENDING_SCANS machine(s) still stale after a forced rescan; reboot state for those may be wrong."
            fi
        fi
    fi

    REBOOT_MACHINES=()
    while IFS= read -r line; do [[ -n "$line" ]] && REBOOT_MACHINES+=("$line"); done < <(pdq_ssh "$PDQ_SQLITE \"$PDQ_INV_DB\" \"SELECT DISTINCT Name FROM Computers WHERE Name IN ($CYCLE_IN) AND NeedsReboot = 1 ORDER BY Name\"")
    REBOOT_LIST="${REBOOT_MACHINES[*]}"
    log "Pending reboots: ${REBOOT_LIST:-none}"

    if [[ -z "$REBOOT_LIST" && -z "$FAILED_LIST" ]]; then
        if [[ $CYCLE -ge 2 ]]; then
            log "No pending reboots and no failures after cycle $CYCLE. Patch loop complete."
            exit 0
        fi
        log "Clean after cycle 1 — proceeding to mandatory cycle 2."
        TARGETS=("${ALL_MACHINES[@]}")
        continue
    fi

    WORK="reboot=$REBOOT_LIST|failed=$FAILED_LIST"
    if [[ "$WORK" == "$PREV_WORK" && $CYCLE -gt 2 ]]; then
        log "ERROR: No progress two cycles in a row ($WORK). Genuine failure — aborting; report these machines in the completion email."
        exit 1
    fi
    PREV_WORK="$WORK"

    if [[ -z "$REBOOT_LIST" && -n "$FAILED_LIST" ]]; then
        log "Failures with no pending reboot — waiting 4 min to settle, then retrying: $FAILED_LIST"
        SETTLE_EPOCH=$(( $(date '+%s') + 4 * 60 ))
        until [[ $(date '+%s') -ge $SETTLE_EPOCH ]]; do sleep 10; done
        TARGETS=("${FAILED_MACHINES[@]}")
        continue
    fi

    # Capture the reference time from the PDQ server's clock BEFORE the reboot goes out,
    # so the Event 19 search window cannot miss an early completion. 2 min of margin.
    REBOOT_SINCE=$(pdq_ssh 'powershell -NonInteractive -NoProfile -Command "(Get-Date).AddMinutes(-2).ToString(\"yyyy-MM-dd HH:mm:ss\")"')
    log "Reboot reference time (PDQ server clock): $REBOOT_SINCE"
    log "Sending reboots to: ${REBOOT_MACHINES[*]}"
    REBOOT_OUT=$(pdq_ssh "$PDQ_DEPLOY Deploy -Package \"$REBOOT_PKG\" -Targets ${REBOOT_MACHINES[*]} -UseScanUserCredentials")
    echo "$REBOOT_OUT"
    REBOOT_DEPLOY_ID=$(echo "$REBOOT_OUT" | awk '/^ID/{print $NF}')
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
    CU_RESULT=$(ssh -n -q -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com" \
        "powershell -NonInteractive -NoProfile -EncodedCommand ${ENCODED}" | tr -d '\r')
    log "CU check: $CU_RESULT"

    if [[ "$CU_RESULT" == CU_FOUND* ]]; then
        # A CU was installed. 20 minutes is a CEILING, not a fixed wait: proceed as soon
        # as every rebooted machine logs WindowsUpdateClient Event 19, the only signal
        # that the update genuinely finalised. Reboot flags, the updated UBR and PDQ's
        # own NeedsReboot all read "done" ~5 min too early (SVPDQHQ01, 2026-08-15) and
        # servicing then rebooted the box again. If the ceiling is hit, something is
        # wrong: stop the run and email rather than proceed on an unverified fleet.
        WAIT_MIN=20
        log "CU detected - confirming completion via Event 19 (ceiling ${WAIT_MIN} min)..."
        CU_DEADLINE=$(( $(date '+%s') + WAIT_MIN * 60 ))
        if CU_OUT=$(bash ~/GitHub/api/patching/cu-confirm.sh "$CU_DEADLINE" "$REBOOT_SINCE" "${REBOOT_MACHINES[@]}" 2>&1); then
            echo "$CU_OUT"
            log "All rebooted machines confirmed update completion."
        else
            echo "$CU_OUT"
            UNCONFIRMED=$(printf '%s\n' "$CU_OUT" | sed -n 's/^UNCONFIRMED: //p')
            log "ERROR: ${WAIT_MIN}-minute ceiling reached without confirmation from: ${UNCONFIRMED:-unknown}"
            log "Pausing the run and emailing Frank. Nothing further will be deployed."
            send_pause_email "${UNCONFIRMED:-unknown}" "$CU_OUT"
            exit 1
        fi
    else
        WAIT_MIN=5
        log "No CU - fixed ${WAIT_MIN}-minute wait for reboots to complete..."
        TARGET_EPOCH=$(( $(date '+%s') + WAIT_MIN * 60 ))
        until [[ $(date '+%s') -ge $TARGET_EPOCH ]]; do sleep 10; done
        log "${WAIT_MIN}-minute wait complete."
    fi

    for i in $(seq 1 30); do
        RB_STATUS=$(pdq_ssh "$PDQ_SQLITE \"$PDQ_DEPLOY_DB\" \"SELECT Status FROM Deployments WHERE DeploymentId = $REBOOT_DEPLOY_ID\"")
        log "Reboot deployment $REBOOT_DEPLOY_ID — $RB_STATUS"
        if [[ "$RB_STATUS" == "Finished" ]]; then break; fi
        sleep 30
    done

    if [[ $CYCLE -ge 2 ]]; then
        NEXT=()
        while IFS= read -r line; do [[ -n "$line" ]] && NEXT+=("$line"); done < <(printf '%s\n' "${REBOOT_MACHINES[@]}" "${FAILED_MACHINES[@]}" | grep -v '^$' | sort -u)
        TARGETS=("${NEXT[@]}")
    else
        TARGETS=("${ALL_MACHINES[@]}")
    fi
done
```
