#!/usr/bin/env bash
# regenerate-refresh-token.sh — exchange a grant code for a new refresh token.
#
# Usage: ./regenerate-refresh-token.sh <grant-code>
#
# Grant code is generated from the Zoho Developer Console:
#   https://accounts.zoho.com/developerconsole
#   → open the existing Self Client
#   → Generate Code tab
#   → Scope:       SDPOnDemand.requests.ALL,SDPOnDemand.users.ALL,SDPOnDemand.setup.ALL
#   → Duration:    10 minutes
#   → Description: (anything; "SDP ticket creation + user mgmt + setup metadata" works)
#   → copy the generated code, paste it as this script's argument
#
# The script prints the new refresh_token and reminds you to update ~/GitHub/.tokens/sdp.

set -o pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <grant-code>" >&2
  echo "  Grant code is generated in the Zoho Developer Console (see header)." >&2
  exit 2
fi
GRANT_CODE="$1"

SCRIPT_DIR="${0:A:h}"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/sdp-api.sh"

# We only need CLIENT_ID/CLIENT_SECRET from ~/GitHub/.tokens/sdp; REFRESH_TOKEN may be stale.
# Load the file but tolerate an empty REFRESH_TOKEN.
if [ ! -f "$SDP_CREDS_FILE" ]; then
  echo "ERROR: $SDP_CREDS_FILE not found." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$SDP_CREDS_FILE"
set +a
: "${SDP_DC:=com}"

for var in CLIENT_ID CLIENT_SECRET; do
  eval "val=\$$var"
  if [ -z "$val" ]; then
    echo "ERROR: $var is empty in $SDP_CREDS_FILE" >&2
    exit 1
  fi
done

echo "==> Exchanging grant code for a new refresh token..."
response=$(curl -sS -X POST "https://accounts.zoho.${SDP_DC}/oauth/v2/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "code=$GRANT_CODE" \
  -d "redirect_uri=https://sdpondemand.manageengine.com")

echo "----- Response -----"
echo "$response"
echo "--------------------"

NEW_REFRESH=$(echo "$response" | grep -o '"refresh_token":"[^"]*' | cut -d'"' -f4)
if [ -z "$NEW_REFRESH" ]; then
  echo "ERROR: no refresh_token in response. Grant code may be expired or scope invalid." >&2
  echo "       Generate a new grant code and retry (grant codes are single-use, 10 min TTL)." >&2
  exit 1
fi

echo
echo "==> NEW REFRESH TOKEN (copy this):"
echo "$NEW_REFRESH"
echo
echo "==> Update $SDP_CREDS_FILE:"
echo "    REFRESH_TOKEN=$NEW_REFRESH"
echo
echo "==> Then re-run ./check-scope.sh to confirm the new scope takes effect."
