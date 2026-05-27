#!/bin/zsh
# check-scope.sh — probe the current refresh token's scope.
#
# Exchanges the refresh token for an access token, prints the reported scope,
# then attempts a lightweight GET /requests?row_count=1 to confirm that the
# token can actually read requests. Non-destructive — no writes.
#
# Usage: ./check-scope.sh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/sdp-api.sh"

load_creds || exit 1

echo "==> Fetching access token..."
refresh_token > /dev/null || exit 1

echo "==> Access token retrieved."
echo "    Reported scope: ${ACCESS_TOKEN_SCOPE:-<not reported>}"
echo

echo "==> Probing GET /requests?row_count=1 (needs SDPOnDemand.requests.READ)..."
LIST_PAYLOAD='{"list_info":{"row_count":1}}'
resp=$(sdp_call GET "/requests" --data-urlencode "input_data=$LIST_PAYLOAD" -G)
if echo "$resp" | grep -q '"status_code":2000\|"response_status":"success"'; then
  echo "    OK — requests READ works."
  REQUESTS_READ=ok
else
  echo "    FAILED — response excerpt:"
  echo "$resp" | head -c 400
  echo
  REQUESTS_READ=fail
fi
echo

# Decide whether CREATE/UPDATE look likely based on reported scope string.
echo "==> Summary:"
if [ "$REQUESTS_READ" = "ok" ]; then
  echo "    - READ:   OK"
else
  echo "    - READ:   NOT AVAILABLE"
fi

case "$ACCESS_TOKEN_SCOPE" in
  *requests.ALL*|*SDPOnDemand.ALL*)
    echo "    - CREATE: likely OK (scope includes requests.ALL)"
    echo "    - UPDATE: likely OK (scope includes requests.ALL)"
    ;;
  *)
    CREATE_OK=no
    UPDATE_OK=no
    case "$ACCESS_TOKEN_SCOPE" in *requests.CREATE*) CREATE_OK=yes ;; esac
    case "$ACCESS_TOKEN_SCOPE" in *requests.UPDATE*) UPDATE_OK=yes ;; esac
    if [ "$CREATE_OK" = "yes" ]; then
      echo "    - CREATE: likely OK (scope includes requests.CREATE)"
    else
      echo "    - CREATE: MISSING — regenerate token with SDPOnDemand.requests.CREATE"
    fi
    if [ "$UPDATE_OK" = "yes" ]; then
      echo "    - UPDATE: likely OK (scope includes requests.UPDATE)"
    else
      echo "    - UPDATE: MISSING — regenerate token with SDPOnDemand.requests.UPDATE (needed to close tickets)"
    fi
    ;;
esac

if [ "$REQUESTS_READ" != "ok" ]; then
  echo
  echo "==> Cannot proceed without at least requests.READ + requests.CREATE."
  echo "    See README.md 'Rotating / Regenerating the refresh token'."
  exit 1
fi
