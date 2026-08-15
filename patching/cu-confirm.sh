#!/usr/bin/env bash
# cu-confirm.sh — wait until every rebooted machine confirms its update actually
# finalised, using WindowsUpdateClient Event ID 19 ("Installation Successful").
#
# Usage:
#   cu-confirm.sh <deadline_epoch> "<since YYYY-MM-DD HH:MM:SS>" MACHINE [MACHINE...]
#
# Exit codes:
#   0  every machine confirmed before the deadline
#   2  deadline reached with machines unconfirmed (names on stdout as UNCONFIRMED: ...)
#   1  usage / infrastructure error
#
# WHY THIS EXISTS
# Reboot flags are not a reliable "CU finished" signal. On SVPDQHQ01 (2026-08-15)
# every cheap check — CBS RebootPending, WU RebootRequired, PendingFileRename, the
# updated UBR, and PDQ's own NeedsReboot — read "done" at 11:02, and TrustedInstaller
# then rebooted the box again at 11:05:46. The genuine completion signal was
# WindowsUpdateClient Event 19 at 11:07:29, after the second reboot. Trigger-to-done
# was 11.5 minutes, which is why the 20-minute ceiling exists.
#
# TRANSPORT
# Queries Win32_NTLogEvent over WMI/DCOM, not Get-WinEvent. Get-WinEvent uses the
# Remote Event Log RPC endpoint, which is unavailable on some hosts (NEDVVDMC01/02
# hang ~21s then fail) even though WMI works fine — WMI is the same channel PDQ
# already scans over, so it reaches everything PDQ manages.
#
# CREDENTIALS
# Per-domain DA from Azure Key Vault, mapped via PDQ Inventory's ADDomain column.
# Passwords are passed on stdin, never argv. Note the passwords differ per domain
# even where the account name repeats.

set -uo pipefail

DEADLINE_EPOCH="${1:?usage: cu-confirm.sh <deadline_epoch> <since> MACHINE...}"
SINCE="${2:?missing since}"
shift 2
MACHINES=("$@")
[[ ${#MACHINES[@]} -eq 0 ]] && { echo "cu-confirm: no machines given"; exit 1; }

if [[ -f ~/.ssh/id_ed25519_pdq ]]; then SSH_KEY=~/.ssh/id_ed25519_pdq; else SSH_KEY=~/.ssh/id_ed25519; fi
PDQ_HOST="ntsupport@cpp-db.com@SVPDQHQ01.cpp-db.com"
SQ='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe"'
INVDB='C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db'
PWSH='"C:\Program Files\PowerShell\7\pwsh.exe"'
POLL_SECONDS="${CU_CONFIRM_POLL:-60}"

cu_log() { echo "[$(date '+%H:%M:%S')] cu-confirm: $*"; }
pdq_ssh() { ssh -n -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 "$PDQ_HOST" "$1" | tr -d '\r'; }

# machine|domain straight from PDQ's ADDomain column — no DNS guessing
IN=$(printf "'%s'," "${MACHINES[@]}"); IN="${IN%,}"
PAIRS=$(pdq_ssh "$SQ \"$INVDB\" \"SELECT Name||'|'||COALESCE(ADDomain,'?') FROM Computers WHERE Name IN ($IN)\"")
[[ -z "$PAIRS" ]] && { cu_log "ERROR: could not resolve machine->domain from PDQ"; exit 1; }

PS_TEMPLATE=$(cat <<'PSEOF'
$ProgressPreference='SilentlyContinue'
$pwCpp = [Console]::In.ReadLine()
$pwOpp = [Console]::In.ReadLine()
$pwNew = [Console]::In.ReadLine()
$pwAsh = [Console]::In.ReadLine()
$pwWeb = [Console]::In.ReadLine()
$since    = [datetime]::ParseExact('__SINCE__','yyyy-MM-dd HH:mm:ss',$null)
$cimSince = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($since)
$creds = @{
  'cpp-db.com'      = @{U='CPP-DB\ntsupport';        P=$pwCpp}
  'cpp-web.com'     = @{U='cpp-web.com\ntsupport';   P=$pwWeb}
  'opp.local'       = @{U='opp.local\#domain';       P=$pwOpp}
  'oppnewapp.local' = @{U='oppnewapp.local\#domain'; P=$pwNew}
  'oppashapp.local' = @{U='oppashapp.local\#domain'; P=$pwAsh}
}
$pairs = @'
__PAIRS__
'@ -split "\r?\n" | Where-Object { $_.Trim() -ne '' }

$pairs | ForEach-Object -ThrottleLimit 12 -Parallel {
    $c = $using:creds; $cs = $using:cimSince
    $p = $_.Trim() -split '\|'; $m = $p[0]; $d = $p[1]
    $e = $c[$d]
    if (-not $e) { "NOCRED|$m|$d"; return }
    $sec  = ConvertTo-SecureString $e.P -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($e.U,$sec)
    $opt  = New-CimSessionOption -Protocol Dcom
    try {
        $s = New-CimSession -ComputerName $m -Credential $cred -SessionOption $opt -OperationTimeoutSec 25 -ErrorAction Stop
        $q = "SELECT TimeWritten FROM Win32_NTLogEvent WHERE Logfile='System' AND EventCode=19 AND SourceName='Microsoft-Windows-WindowsUpdateClient' AND TimeWritten>='$cs'"
        $ev = Get-CimInstance -CimSession $s -Query $q -ErrorAction Stop | Select-Object -First 1
        Remove-CimSession $s -ErrorAction SilentlyContinue
        if ($ev) { "OK|$m|$($ev.TimeWritten.ToString('HH:mm:ss'))" } else { "PENDING|$m|-" }
    } catch {
        $msg = ($_.Exception.Message -replace '[\|\r\n]',' ')
        "ERROR|$m|$($msg.Substring(0,[Math]::Min(60,$msg.Length)))"
    }
}
PSEOF
)

run_check() {
    local ps enc
    ps="${PS_TEMPLATE/__SINCE__/$SINCE}"
    ps="${ps/__PAIRS__/$PAIRS}"
    enc=$(printf '%s' "$ps" | iconv -t UTF-16LE | base64 | tr -d '\n')
    printf '%s\n%s\n%s\n%s\n%s\n' \
      "$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com)" \
      "$(~/GitHub/.tokens/kv-get.sh da-opp-local)" \
      "$(~/GitHub/.tokens/kv-get.sh da-oppnewapp-local)" \
      "$(~/GitHub/.tokens/kv-get.sh da-oppashapp-local)" \
      "$(~/GitHub/.tokens/kv-get.sh da-cpp-web-com)" \
    | ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
          "$PDQ_HOST" "$PWSH -NonInteractive -NoProfile -EncodedCommand $enc" 2>&1 | tr -d '\r'
}

cu_log "confirming ${#MACHINES[@]} machine(s) via Event 19 since '$SINCE' (deadline $(date -r "$DEADLINE_EPOCH" '+%H:%M:%S'))"

while :; do
    OUT=$(run_check)
    CONFIRMED=$(printf '%s\n' "$OUT" | grep -c '^OK|' || true)
    STRAGGLERS=$(printf '%s\n' "$OUT" | grep -vE '^OK\|' | grep -oE '^[A-Z]+\|[^|]+' | cut -d'|' -f2 | sort -u | tr '\n' ' ')
    cu_log "confirmed ${CONFIRMED}/${#MACHINES[@]}${STRAGGLERS:+ | waiting on: $STRAGGLERS}"

    if [[ "$CONFIRMED" -eq "${#MACHINES[@]}" ]]; then
        cu_log "all machines confirmed update completion."
        exit 0
    fi

    if [[ $(date '+%s') -ge $DEADLINE_EPOCH ]]; then
        cu_log "DEADLINE REACHED with ${#MACHINES[@]} expected, $CONFIRMED confirmed."
        printf '%s\n' "$OUT" | grep -vE '^OK\|' | sed 's/^/    /'
        echo "UNCONFIRMED: $STRAGGLERS"
        exit 2
    fi
    sleep "$POLL_SECONDS"
done
