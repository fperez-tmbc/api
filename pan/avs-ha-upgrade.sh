#!/usr/bin/env zsh
# avs-ha-upgrade.sh — upgrade an HA pair of PAN-OS VM firewalls with vCenter snapshot protection
#
# Usage:
#   avs-ha-upgrade.sh <passive-host> <active-host> <version> <pan-token-file> <pan-ssh-key> \
#                     <vcenter-vm-passive> <vcenter-vm-active>
#
# Example:
#   avs-ha-upgrade.sh avspan02.cpp-db.com avspan01.cpp-db.com 11.2.12 \
#     ~/GitHub/.tokens/pan-avs ~/GitHub/.tokens/svcclaude-key \
#     AVSPAN02 AVSPAN01
#
# Snapshots are taken before any upgrade work begins and deleted only after both peers
# are confirmed up, running the target version, and HA is fully synchronized.
# If any step fails the script exits immediately — snapshots are left in place.

set -euo pipefail

PASSIVE_HOST=$1
ACTIVE_HOST=$2
VERSION=$3
PAN_TOKEN_FILE=$4
PAN_SSH_KEY=$5
VC_VM_PASSIVE=$6
VC_VM_ACTIVE=$7

SCRIPT_DIR=${0:a:h}
VC_HOST="vc.ed044990b4444c86b72971.eastus2.avs.azure.com"
VC_CREDS=~/GitHub/.tokens/svcclaude
SNAP_NAME="pre-upgrade-${VERSION}"

PAN_TOKEN=$(cat "$PAN_TOKEN_FILE" | tr -d '[:space:]')
PASSIVE_URL="https://${PASSIVE_HOST}/api/"
ACTIVE_URL="https://${ACTIVE_HOST}/api/"

# --- helpers ---

pan_api() {
  local url=$1; shift
  curl -sk --max-time 30 "$url" "$@"
}

poll_download() {
  local url=$1 jobid=$2 label=$3
  local deadline=$(( SECONDS + 7200 ))
  while (( SECONDS < deadline )); do
    local resp jstatus jresult jprogress
    resp=$(pan_api "$url" \
      --data-urlencode "type=op" \
      --data-urlencode "key=$PAN_TOKEN" \
      --data-urlencode "cmd=<show><jobs><id>${jobid}</id></jobs></show>")
    jstatus=$(echo "$resp" | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
    jresult=$(echo "$resp" | grep -o '<result>[^<]*</result>' | head -1 | sed 's/<[^>]*>//g')
    jprogress=$(echo "$resp" | grep -o '<progress>[^<]*</progress>' | head -1 | sed 's/<[^>]*>//g')
    if [[ $jstatus == FIN ]]; then
      echo "  ${label} FIN — result: ${jresult}"
      [[ $jresult == OK ]] || { echo "ERROR: ${label} failed (result: ${jresult})" >&2; return 1; }
      return 0
    fi
    echo "  ${label}: ${jstatus} ${jprogress}%"
    sleep 15
  done
  echo "ERROR: ${label} timed out" >&2
  return 1
}

# --- vCenter auth ---

echo "=== Authenticating to vCenter ==="
VC_USER=$(grep '^USERNAME' "$VC_CREDS" | cut -d= -f2)
VC_PASS=$(grep '^PASSWORD' "$VC_CREDS" | cut -d= -f2)
VC_TOKEN=$(curl -sk -X POST \
  "https://${VC_HOST}/api/session" \
  -u "${VC_USER}:${VC_PASS}" \
  -H "Content-Type: application/json" | tr -d '"')
[[ -n $VC_TOKEN ]] || { echo "ERROR: vCenter auth failed" >&2; exit 1; }

vc_delete_session() {
  curl -sk -X DELETE \
    -H "vmware-api-session-id: $VC_TOKEN" \
    "https://${VC_HOST}/api/session" > /dev/null
}

resolve_vm() {
  local name=$1
  curl -sk \
    -H "vmware-api-session-id: $VC_TOKEN" \
    "https://${VC_HOST}/api/vcenter/vm?names=${name}" \
    | python3 -c "
import sys, json
vms = json.load(sys.stdin)
print(vms[0]['vm'] if vms else '')
"
}

echo "Resolving VM IDs..."
VM_ID_PASSIVE=$(resolve_vm "$VC_VM_PASSIVE")
VM_ID_ACTIVE=$(resolve_vm "$VC_VM_ACTIVE")
[[ -n $VM_ID_PASSIVE ]] || { echo "ERROR: could not resolve $VC_VM_PASSIVE" >&2; vc_delete_session; exit 1; }
[[ -n $VM_ID_ACTIVE  ]] || { echo "ERROR: could not resolve $VC_VM_ACTIVE"  >&2; vc_delete_session; exit 1; }
echo "  $VC_VM_PASSIVE → $VM_ID_PASSIVE"
echo "  $VC_VM_ACTIVE  → $VM_ID_ACTIVE"

# --- snapshots ---

take_snapshot() {
  local vm_id=$1 vm_name=$2
  echo "Taking snapshot '$SNAP_NAME' on ${vm_name}..."
  local snap_id
  snap_id=$(curl -sk -X POST \
    -H "vmware-api-session-id: $VC_TOKEN" \
    -H "Content-Type: application/json" \
    "https://${VC_HOST}/api/vcenter/vm/${vm_id}/snapshots" \
    -d "{\"name\": \"${SNAP_NAME}\", \"description\": \"Pre-upgrade snapshot before PAN-OS ${VERSION}\", \"memory\": false, \"quiesce\": false}" \
    | tr -d '"')
  [[ -n $snap_id ]] || { echo "ERROR: snapshot failed for ${vm_name}" >&2; return 1; }
  echo "  ${vm_name} snapshot ID: ${snap_id}"
  echo "$snap_id"
}

echo "=== Taking snapshots ==="
SNAP_ID_PASSIVE=$(take_snapshot "$VM_ID_PASSIVE" "$VC_VM_PASSIVE")
SNAP_ID_ACTIVE=$(take_snapshot "$VM_ID_ACTIVE" "$VC_VM_ACTIVE")

# --- download on both peers in parallel ---

echo "=== Downloading ${VERSION} on both peers ==="

start_download() {
  local url=$1
  local resp
  resp=$(pan_api "$url" \
    --data-urlencode "type=op" \
    --data-urlencode "key=$PAN_TOKEN" \
    --data-urlencode "cmd=<request><system><software><download><version>${VERSION}</version></download></software></system></request>")
  echo "$resp" | grep -o '<job>[0-9]*</job>' | grep -o '[0-9]*'
}

DL_JOB_PASSIVE=$(start_download "$PASSIVE_URL")
DL_JOB_ACTIVE=$(start_download "$ACTIVE_URL")

if [[ -n $DL_JOB_PASSIVE ]]; then
  poll_download "$PASSIVE_URL" "$DL_JOB_PASSIVE" "Download ${PASSIVE_HOST}"
else
  echo "  ${PASSIVE_HOST}: no download job returned — version likely already present"
fi

if [[ -n $DL_JOB_ACTIVE ]]; then
  poll_download "$ACTIVE_URL" "$DL_JOB_ACTIVE" "Download ${ACTIVE_HOST}"
else
  echo "  ${ACTIVE_HOST}: no download job returned — version likely already present"
fi

# --- upgrade passive peer ---

echo "=== Upgrading passive peer (${PASSIVE_HOST}) ==="
zsh "${SCRIPT_DIR}/pan-upgrade.sh" "$PASSIVE_HOST" "$VERSION" "$PAN_TOKEN_FILE" "$PAN_SSH_KEY"

# After passive upgrade: version mismatch with active is expected — only check HA links
echo "Checking HA links on passive peer (config sync not expected with mismatched versions)..."
HA_RESP=$(pan_api "$PASSIVE_URL" \
  --data-urlencode "type=op" \
  --data-urlencode "key=$PAN_TOKEN" \
  --data-urlencode "cmd=<show><high-availability><state/></high-availability></show>")
HA1=$(echo "$HA_RESP" | grep -o '<conn-ha1>.*</conn-ha1>' | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
HA2=$(echo "$HA_RESP" | grep -o '<conn-ha2>.*</conn-ha2>' | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
echo "  ${PASSIVE_HOST} — HA1: ${HA1}  HA2: ${HA2}"
[[ $HA1 == "up" && $HA2 == "up" ]] || {
  echo "ERROR: HA links not up on passive peer after upgrade — not proceeding to active" >&2
  vc_delete_session
  exit 1
}

# --- upgrade active peer ---

echo "=== Upgrading active peer (${ACTIVE_HOST}) ==="
zsh "${SCRIPT_DIR}/pan-upgrade.sh" "$ACTIVE_HOST" "$VERSION" "$PAN_TOKEN_FILE" "$PAN_SSH_KEY"

# After both upgraded: check full HA sync
echo "Waiting 60 seconds for HA to resync..."
sleep 60

check_full_ha_sync() {
  local url=$1 label=$2
  local resp
  resp=$(pan_api "$url" \
    --data-urlencode "type=op" \
    --data-urlencode "key=$PAN_TOKEN" \
    --data-urlencode "cmd=<show><high-availability><state/></high-availability></show>")
  local ha1 ha2 sync
  ha1=$(echo "$resp"  | grep -o '<conn-ha1>.*</conn-ha1>' | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
  ha2=$(echo "$resp"  | grep -o '<conn-ha2>.*</conn-ha2>' | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
  sync=$(echo "$resp" | grep -o '<running-sync>[^<]*</running-sync>' | sed 's/<[^>]*>//g')
  echo "  ${label} — HA1: ${ha1}  HA2: ${ha2}  sync: ${sync}"
  [[ $ha1 == "up" && $ha2 == "up" && $sync == "synchronized" ]] || {
    echo "ERROR: HA not fully synced on ${label}" >&2
    return 1
  }
}

check_full_ha_sync "$PASSIVE_URL" "$PASSIVE_HOST"
check_full_ha_sync "$ACTIVE_URL"  "$ACTIVE_HOST"

# --- delete snapshots ---

echo "=== Deleting snapshots ==="

delete_snapshot() {
  local vm_id=$1 snap_id=$2 vm_name=$3
  echo "Deleting snapshot on ${vm_name} (${snap_id})..."
  curl -sk -X DELETE \
    -H "vmware-api-session-id: $VC_TOKEN" \
    "https://${VC_HOST}/api/vcenter/vm/${vm_id}/snapshots/${snap_id}" > /dev/null
  echo "  Done."
}

delete_snapshot "$VM_ID_PASSIVE" "$SNAP_ID_PASSIVE" "$VC_VM_PASSIVE"
delete_snapshot "$VM_ID_ACTIVE"  "$SNAP_ID_ACTIVE"  "$VC_VM_ACTIVE"

vc_delete_session
echo "=== Upgrade complete — both peers on ${VERSION}, HA synced, snapshots removed ==="
