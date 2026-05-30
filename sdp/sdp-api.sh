#!/bin/zsh
# sdp-api.sh — shared helpers for ServiceDesk Plus Cloud v3 API
# Sourced by the other scripts in this folder. Not meant to be executed directly.
# Compatible with bash and zsh.
#
# Provides:
#   load_creds            — load .sdp-creds into the environment
#   refresh_token         — fetch a fresh access token from Zoho
#   sdp_base_url          — print the SDP Cloud base URL derived from SDP_PORTAL/SDP_DC
#   sdp_call              — curl wrapper; sets SDP_LAST_HTTP_STATUS; returns 0 (2xx), 2 (429), 1 (other)
#   sdp_post_input_data   — POST with input_data form-encoded body
#   sdp_put_input_data    — PUT with input_data form-encoded body
#   sdp_pace              — sleep 7s between steps to stay under rate limit (~8.5 req/min/endpoint)
#   sdp_rate_limit_sleep  — exponential backoff after a 429: 60s → 120s → ... → 600s cap
#
# Rate limits (ManageEngine SDP Cloud):
#   10 req/min per user per endpoint. Exceeding triggers a 10-min block on that endpoint only.
#   Scope is per-endpoint: /requests/{id}/notes is independent of /requests/{id}.
#   The Zoho OAuth token endpoint has its own separate limit.
#
# Bulk reads: pass list_info.row_count=100 to GET list endpoints for up to 100 records/call.
#   To paginate beyond the first page, increment list_info.start_index by 100 each call (0-based).
#   e.g. sdp_call GET "/requests" --data-urlencode 'input_data={"list_info":{"row_count":100,"start_index":0}}'
#   Rate limit is enforced per IP address. There is no batch-write API; each PUT/POST is one call.
#
# Repo layout assumption: this script lives at
#   <tmbc-tasks>/notes/sdp-ticket-creation/sdp-api.sh
# and .sdp-creds lives at <tmbc-tasks>/.sdp-creds (two directories up).

set -o pipefail

# Creds live at ~/GitHub/.tokens/sdp (never inside a repo folder).
# Callers should set SDP_CREDS_FILE before sourcing this script. The fallback below
# is used when running scripts directly from api/sdp/.
_SDP_API_DIR="${0:A:h}"
[ -z "$_SDP_API_DIR" ] && _SDP_API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SDP_CREDS_FILE="${SDP_CREDS_FILE:-$HOME/GitHub/.tokens/sdp}"

load_creds() {
  if [ ! -f "$SDP_CREDS_FILE" ]; then
    echo "ERROR: credentials file not found at $SDP_CREDS_FILE" >&2
    echo "       populate ~/GitHub/.tokens/sdp with CLIENT_ID/CLIENT_SECRET/REFRESH_TOKEN" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  set -a
  . "$SDP_CREDS_FILE"
  set +a

  : "${SDP_PORTAL:=itdesk}"
  : "${SDP_DC:=com}"

  for var in CLIENT_ID CLIENT_SECRET REFRESH_TOKEN; do
    eval "val=\$$var"
    if [ -z "$val" ]; then
      echo "ERROR: $var is empty in $SDP_CREDS_FILE" >&2
      return 1
    fi
  done
}

sdp_base_url() {
  echo "https://sdpondemand.manageengine.${SDP_DC}/app/${SDP_PORTAL}/api/v3"
}

zoho_oauth_url() {
  echo "https://accounts.zoho.${SDP_DC}/oauth/v2/token"
}

# Fetches a fresh access token. Echoes the token to stdout on success.
# Also exports ACCESS_TOKEN and ACCESS_TOKEN_SCOPE for downstream callers.
# If ACCESS_TOKEN is already set (e.g. inherited from a parent shell that already
# refreshed), skip the Zoho call to avoid hitting the token-endpoint rate limit.
refresh_token() {
  if [ -n "$ACCESS_TOKEN" ]; then
    echo "$ACCESS_TOKEN"
    return 0
  fi

  local response http_status tmpfile
  tmpfile=$(mktemp /tmp/sdp_token_XXXXXX.json)

  http_status=$(curl -sS -w "%{http_code}" -o "$tmpfile" \
    -X POST "$(zoho_oauth_url)" \
    -d "grant_type=refresh_token" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "refresh_token=$REFRESH_TOKEN")

  response=$(cat "$tmpfile")
  rm -f "$tmpfile"

  case "$http_status" in
    429)
      echo "ERROR: Zoho token endpoint rate-limited (HTTP 429). Wait before retrying." >&2
      return 1 ;;
    2*) ;;
    *)
      echo "ERROR: Zoho token endpoint returned HTTP $http_status." >&2
      echo "Response:" >&2
      echo "$response" >&2
      return 1 ;;
  esac

  # Extract access_token + scope from the JSON response using plain sed/grep
  # to avoid a jq dependency.
  ACCESS_TOKEN=$(echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  ACCESS_TOKEN_SCOPE=$(echo "$response" | grep -o '"scope":"[^"]*' | cut -d'"' -f4)

  if [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: failed to retrieve access token." >&2
    echo "Response from Zoho:" >&2
    echo "$response" >&2
    return 1
  fi

  export ACCESS_TOKEN ACCESS_TOKEN_SCOPE
  echo "$ACCESS_TOKEN"
}

# sdp_call <METHOD> <ENDPOINT> [curl args...]
# e.g. sdp_call GET /requests/123
#      sdp_call POST /requests --data-urlencode "input_data=$(cat payload.json)"
#
# Writes response body to stdout. Sets SDP_LAST_HTTP_STATUS to the HTTP status code.
# Returns: 0 for 2xx, 2 for 429 (rate-limited), 1 for all other errors.
# A 2xx return is always success — never retry a non-idempotent call on body parse failure.
#
# NOTE: avoid using a local var named `path` in zsh — it's a tied array
# synced with PATH and `local path=...` wipes PATH inside the function,
# causing "command not found: curl". Use `endpoint` instead.
sdp_call() {
  local method="$1"
  local endpoint="$2"
  shift 2
  local url tmpfile http_status
  url="$(sdp_base_url)${endpoint}"
  tmpfile=$(mktemp /tmp/sdp_resp_XXXXXX.json)

  http_status=$(curl -sS -w "%{http_code}" -o "$tmpfile" \
    -X "$method" "$url" \
    -H "Accept: application/vnd.manageengine.sdp.v3+json" \
    -H "Authorization: Zoho-oauthtoken $ACCESS_TOKEN" \
    "$@")

  SDP_LAST_HTTP_STATUS="$http_status"
  cat "$tmpfile"
  rm -f "$tmpfile"

  case "$http_status" in
    2*) return 0 ;;
    429) return 2 ;;
    *) return 1 ;;
  esac
}

# sdp_post_input_data <ENDPOINT> <payload_file>
# Convenience wrapper for POSTs that take input_data as form-encoded body.
sdp_post_input_data() {
  local endpoint="$1"
  local payload_file="$2"
  if [ ! -f "$payload_file" ]; then
    echo "ERROR: payload file not found: $payload_file" >&2
    return 1
  fi
  sdp_call POST "$endpoint" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "input_data=$(cat "$payload_file")"
}

# sdp_put_input_data <ENDPOINT> <payload_file>
sdp_put_input_data() {
  local endpoint="$1"
  local payload_file="$2"
  if [ ! -f "$payload_file" ]; then
    echo "ERROR: payload file not found: $payload_file" >&2
    return 1
  fi
  sdp_call PUT "$endpoint" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "input_data=$(cat "$payload_file")"
}

# sdp_pace — insert between steps in multi-call sequences to stay under the
# 10 req/min per-endpoint limit (~8.5 req/min at 7s spacing).
sdp_pace() { sleep 7; }

# sdp_rate_limit_sleep <attempt>
# Call after sdp_call returns 2 (HTTP 429). attempt starts at 1.
# Delay = 60 * 2^(attempt-1), capped at 600s (the 10-min endpoint block window).
sdp_rate_limit_sleep() {
  local attempt="${1:-1}"
  local delay=$(( 60 * (1 << (attempt - 1)) ))
  [ "$delay" -gt 600 ] && delay=600
  echo "Rate limit hit (attempt $attempt); sleeping ${delay}s before retry..." >&2
  sleep "$delay"
}
