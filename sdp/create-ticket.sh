#!/bin/zsh
# create-ticket.sh — POST a ticket to ServiceDesk Plus Cloud.
#
# Usage: ./create-ticket.sh <payload.json>
#
# Payload file must be SDP v3 JSON with a top-level "request" key. See README.

set -o pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <payload.json>" >&2
  exit 2
fi
PAYLOAD="$1"

if [ ! -f "$PAYLOAD" ]; then
  echo "ERROR: payload file not found: $PAYLOAD" >&2
  exit 1
fi

SCRIPT_DIR="${0:A:h}"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/sdp-api.sh"

load_creds || exit 1

echo "==> Fetching access token..."
refresh_token > /dev/null || exit 1

echo "==> POST /requests (payload: $PAYLOAD)"
resp=$(sdp_post_input_data "/requests" "$PAYLOAD")

# Extract the new request ID and display ID for convenience.
NEW_ID=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['request']['id'])" 2>/dev/null)
DISP_ID=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['request']['display_id'])" 2>/dev/null)
STATUS=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response_status',{}).get('status_code',''))" 2>/dev/null)

echo "----- Response -----"
echo "$resp"
echo "--------------------"

if [ "$STATUS" = "2000" ]; then
  echo "OK — created request #${DISP_ID} (id: $NEW_ID)"
  echo "URL: https://sdpondemand.manageengine.${SDP_DC}/app/${SDP_PORTAL}/ui/requests/${DISP_ID}/details"
else
  echo "WARN — POST did not report success. Inspect response above." >&2
  exit 1
fi
