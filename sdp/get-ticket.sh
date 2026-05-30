#!/usr/bin/env bash
# get-ticket.sh — GET a ticket back from ServiceDesk Plus Cloud.
#
# Usage: ./get-ticket.sh <request-id>

set -o pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <request-id>" >&2
  exit 2
fi
REQ_ID="$1"

SCRIPT_DIR="${0:A:h}"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/sdp-api.sh"

load_creds || exit 1

echo "==> Fetching access token..."
refresh_token > /dev/null || exit 1

echo "==> GET /requests/$REQ_ID"
sdp_call GET "/requests/$REQ_ID"
echo
