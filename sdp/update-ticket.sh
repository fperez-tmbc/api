#!/bin/zsh
# update-ticket.sh — PUT an update to an existing ticket in SDP Cloud.
#
# Usage: ./update-ticket.sh <request-id> <payload.json>
#
# Payload must be SDP v3 JSON with a top-level "request" key containing
# only the fields to update (partial update — omitted fields are unchanged).

set -o pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <request-id> <payload.json>" >&2
  exit 2
fi
REQ_ID="$1"
PAYLOAD="$2"

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

echo "==> PUT /requests/$REQ_ID (payload: $PAYLOAD)"
resp=$(sdp_put_input_data "/requests/$REQ_ID" "$PAYLOAD")

STATUS=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response_status',{}).get('status_code',''))" 2>/dev/null)

echo "----- Response -----"
echo "$resp"
echo "--------------------"

if [ "$STATUS" = "2000" ]; then
  DISP=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['request']['display_id'])" 2>/dev/null)
  echo "OK — updated request #${DISP} (id: $REQ_ID)"
else
  echo "WARN — PUT did not report success. Inspect response above." >&2
  exit 1
fi
