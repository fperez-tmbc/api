#!/bin/zsh
# close-ticket.sh — close an existing ticket in ServiceDesk Plus Cloud.
#
# Usage: ./close-ticket.sh <request-id> <closure-payload.json>
#
# Calls PUT /requests/<id>/close with the payload as input_data. Payload
# should contain a "request" object with "closure_info" (closure_code +
# closure_comments) and optionally resolution text / status.

set -o pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <request-id> <closure-payload.json>" >&2
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

echo "==> PUT /requests/$REQ_ID/close (payload: $PAYLOAD)"
resp=$(sdp_put_input_data "/requests/$REQ_ID/close" "$PAYLOAD")

echo "----- Response -----"
echo "$resp"
echo "--------------------"

STATUS=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response_status',{}).get('status_code',''))" 2>/dev/null)
if [ "$STATUS" = "2000" ]; then
  echo "OK — closed request $REQ_ID"
else
  echo "WARN — close did not report success. Inspect response above." >&2
  exit 1
fi
