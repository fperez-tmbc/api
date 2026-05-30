#!/usr/bin/env bash
# list-categories.sh — dump configured lookup values from SDP Cloud.
# Requires SDPOnDemand.setup.ALL (or .READ) scope.
# Useful when POST /requests fails with an "invalid value" error.
#
# Usage: ./list-categories.sh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/sdp-api.sh"

load_creds || exit 1

echo "==> Fetching access token..."
refresh_token > /dev/null || exit 1

LIST='{"list_info":{"row_count":100,"start_index":1}}'

_list() {
  local label="$1" endpoint="$2" field="$3"
  echo "==> $label"
  sdp_call GET "$endpoint" --data-urlencode "input_data=$LIST" -G \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('$field', [])
for item in items:
    name = item.get('name', '—')
    inactive = item.get('inactive', item.get('deleted', False))
    flag = ' [inactive]' if inactive else ''
    print(f'  {name}{flag}')
print(f'  ({len(items)} items)')
"
  echo
}

# --- Categories + Subcategories ---
echo "==> Categories + Subcategories"

# Write pipe-delimited id|name|deleted to a temp file (avoids subshell in loop)
sdp_call GET "/categories" --data-urlencode "input_data=$LIST" -G \
  | python3 -c "
import sys, json
cats = json.load(sys.stdin).get('categories', [])
print(f'  ({len(cats)} categories total)')
for c in cats:
    deleted = '1' if c.get('deleted') else '0'
    print(f\"  CATROW|{c['id']}|{c['name']}|{deleted}\")
" | tee /tmp/sdp_cat_rows.txt | grep -v '^  CATROW'

# Loop reads from file — same shell, ACCESS_TOKEN available
grep '^  CATROW' /tmp/sdp_cat_rows.txt | while IFS='|' read -r _prefix cat_id cat_name cat_deleted; do
  subs=$(sdp_call GET "/categories/${cat_id}/subcategories" \
    --data-urlencode "input_data=$LIST" -G \
    | python3 -c "
import sys, json
items = json.load(sys.stdin).get('subcategories', [])
names = [i['name'] + (' [inactive]' if i.get('deleted') else '') for i in items]
print(', '.join(names) if names else '—')
" 2>/dev/null)
  inactive_flag=""
  [ "$cat_deleted" = "1" ] && inactive_flag=" [inactive]"
  printf "  %-35s %s\n" "${cat_name}${inactive_flag}" "$subs"
done
echo

_list "Request Types"  /request_types  request_types
_list "Priorities"     /priorities     priorities
_list "Urgencies"      /urgencies      urgencies
_list "Impacts"        /impacts        impacts
_list "Groups"         /groups         groups
_list "Statuses"       /statuses       statuses
