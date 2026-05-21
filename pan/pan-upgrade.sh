#!/usr/bin/env zsh
# pan-upgrade.sh — install a PAN-OS software version on one device and reboot
#
# Usage: pan-upgrade.sh <host> <version> <token-file> <ssh-key>
# Example: pan-upgrade.sh frpan01.cpp-db.com 10.2.18-h6 ~/.tokens/pan-fr ~/.tokens/svcclaude-key-rsa
#
# The version must already be downloaded on the device.
# Polls the install job until FIN — never reboots on a partial install.
# Exits non-zero if the install fails or times out.

set -euo pipefail

HOST=$1
VERSION=$2
TOKEN_FILE=$3
SSH_KEY=$4

TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
BASE_URL="https://${HOST}/api/"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o PasswordAuthentication=no
          -o IdentitiesOnly=yes -o IdentityAgent=none
          -o PubkeyAcceptedAlgorithms=rsa-sha2-256
          -o ConnectTimeout=30)

api() {
  curl -sk --max-time 30 "$BASE_URL" "$@"
}

poll_job() {
  local jobid=$1
  local label=${2:-Job}
  # Poll until FIN — no fixed iteration cap; timeout after 120 minutes
  local deadline=$(( SECONDS + 7200 ))
  while (( SECONDS < deadline )); do
    local resp
    resp=$(api --data-urlencode "type=op" \
               --data-urlencode "key=$TOKEN" \
               --data-urlencode "cmd=<show><jobs><id>${jobid}</id></jobs></show>")
    local status result progress
    status=$(echo "$resp" | grep -o '<status>[^<]*</status>' | head -1 | sed 's/<[^>]*>//g')
    result=$(echo "$resp" | grep -o '<result>[^<]*</result>' | head -1 | sed 's/<[^>]*>//g')
    progress=$(echo "$resp" | grep -o '<progress>[^<]*</progress>' | head -1 | sed 's/<[^>]*>//g')
    if [[ $status == FIN ]]; then
      echo "  ${label} FIN — result: ${result}"
      if [[ $result != OK ]]; then
        echo "ERROR: ${label} did not complete successfully (result: ${result})" >&2
        return 1
      fi
      return 0
    fi
    echo "  ${label}: ${status} ${progress}%"
    sleep 15
  done
  echo "ERROR: ${label} timed out after 120 minutes" >&2
  return 1
}

echo "=== Installing ${VERSION} on ${HOST} ==="

# Run install via SSH heredoc; capture job ID from output
install_out=$(ssh "${SSH_OPTS[@]}" "svcclaude@${HOST}" << EOF 2>/dev/null
request system software install version ${VERSION}
y
exit
EOF
)

echo "$install_out"

jobid=$(echo "$install_out" | grep -o 'jobid [0-9]*' | awk '{print $2}')
if [[ -z $jobid ]]; then
  echo "ERROR: could not parse job ID from install output" >&2
  exit 1
fi

echo "Install job ID: ${jobid}"

# Poll until FIN OK — only then reboot
poll_job "$jobid" "Install" || exit 1

echo "=== Install complete — rebooting ${HOST} ==="
printf 'request restart system\ny\nexit\n' | \
  ssh "${SSH_OPTS[@]}" "svcclaude@${HOST}" 2>/dev/null || true

echo "Reboot sent. Waiting 5 minutes before polling..."
sleep 300

echo "=== Polling for ${HOST} to come back ==="
local_deadline=$(( SECONDS + 1800 ))
attempt=0
while (( SECONDS < local_deadline )); do
  attempt=$(( attempt + 1 ))
  sw=$(api --data-urlencode "type=op" \
           --data-urlencode "key=$TOKEN" \
           --data-urlencode "cmd=<show><system><info/></system></show>" 2>/dev/null \
       | grep -o '<sw-version>[^<]*</sw-version>' | sed 's/<[^>]*>//g')
  if [[ -n $sw ]]; then
    echo "${HOST} up — sw-version: ${sw}"
    if [[ $sw != "$VERSION" ]]; then
      echo "WARNING: expected ${VERSION} but got ${sw}" >&2
    fi
    exit 0
  fi
  echo "  Not yet responding... (${attempt})"
  sleep 30
done

echo "ERROR: ${HOST} did not come back within 30 minutes" >&2
exit 1
