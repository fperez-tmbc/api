#!/usr/bin/env zsh
# ============================================================================
# Authenticates as the target domain's Domain Admin, retrieved from Azure Key
# Vault at run time. Nothing is read from ~/GitHub/.tokens/ and no password
# touches disk.
#
#   Domain            KV_SECRET             SSH_USER
#   cpp-db.com        da-cpp-db-com         cpp-db\ntsupport      (default)
#   cpp-web.com       da-cpp-web-com        cpp-web\ntsupport
#   opp.local         da-opp-local          opp\#domain
#   oppashapp.local   da-oppashapp-local    oppashapp\#domain
#   oppnewapp.local   da-oppnewapp-local    oppnewapp\#domain
#
# Override per zone:  KV_SECRET=da-opp-local SSH_USER='opp\#domain' \
#                     DNS_SERVER=mkpdvdmc01.opp.local ./dns-update.sh ...
#
# These are Domain Admin accounts: this script makes ONE auth attempt and does
# not retry. Never loop it over candidate credentials.
#
# Do NOT switch this back to `svcclaude` — that AD identity was dismantled
# 2026-07-27 (deleted outright in cpp-web.com and the three OPP domains). It is
# retained for PAN-OS and vCenter only. See api/ssh/README.md.
# ============================================================================

# dns-update.sh — Update DNS records on a Windows DNS server via SSH + dnscmd
#
# Usage:
#   ./dns-update.sh <operation> <zone> <name> <target> [ttl_seconds]
#   DNS_SERVER=other-dc.cpp-db.com ./dns-update.sh ...
#
# Operations:
#   add-cname      Add a new CNAME record
#   update-cname   Update an existing CNAME record's target (delete + re-add)
#   add-a          Add a new A record
#   update-a       Update an existing A record's IP (delete + re-add)
#   delete         Delete a record (pass record type as 4th arg, e.g. CNAME or A)
#
# TTL: omit or pass 0 to inherit the zone's default TTL.
#
# Examples:
#   ./dns-update.sh update-cname themyersbriggs.com comm polite-cliff-00283991e.7.azurestaticapps.net
#   ./dns-update.sh add-a themyersbriggs.com host1 10.70.16.50 3600
#   ./dns-update.sh delete themyersbriggs.com oldhost CNAME

set -o pipefail

KV_GET="/Users/fperez2nd/GitHub/.tokens/kv-get.sh"
KV_SECRET="${KV_SECRET:-da-cpp-db-com}"
DEFAULT_SERVER="SVDCDC01.cpp-db.com"
SSH_USER="${SSH_USER:-cpp-db\\ntsupport}"

if [[ ! -x "$KV_GET" ]]; then
  echo "ERROR: Key Vault helper not found or not executable at $KV_GET" >&2
  exit 1
fi
PASSWORD=$("$KV_GET" "$KV_SECRET") || { echo "ERROR: could not retrieve KV secret '$KV_SECRET'" >&2; exit 1; }
if [[ -z "$PASSWORD" || "$PASSWORD" == "PENDING" ]]; then
  echo "ERROR: KV secret '$KV_SECRET' is empty or still PENDING — ask Frank to fill it" >&2
  exit 1
fi

OPERATION="${1:?Usage: $0 <operation> <zone> <name> <target> [ttl]}"
ZONE="${2:?Missing zone}"
NAME="${3:?Missing record name}"
TARGET="${4:?Missing target/IP/type}"
TTL="${5:-}"
SERVER="${DNS_SERVER:-$DEFAULT_SERVER}"

# TTL arg: include in dnscmd only if explicitly set
ttl_arg() { [[ -n "$TTL" && "$TTL" != "0" ]] && echo "$TTL " || echo "" }

# Ensure CNAME targets are fully-qualified (trailing dot)
fqdn_dot() { local t="$1"; [[ "$t" != *. ]] && t="${t}."; echo "$t" }

# Run a PowerShell/dnscmd command on the DNS server via SSH.
# Commands are base64-encoded to avoid shell quoting conflicts.
run_cmd() {
  local cmd="$1"
  local encoded
  encoded=$(printf '%s' "$cmd" | iconv -t UTF-16LE | base64 | tr -d '\n')
  sshpass -p "$PASSWORD" ssh -q -n \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o NumberOfPasswordPrompts=1 \
    "${SSH_USER}@${SERVER}" \
    "powershell -NonInteractive -EncodedCommand $encoded"
}

# Look up the current data for a DNS record (returns last whitespace-delimited field).
# Strips Windows CRLF so the value can be safely interpolated into subsequent commands.
get_record_data() {
  local zone="$1" name="$2" type="$3"
  run_cmd "dnscmd $SERVER /enumrecords $zone $name /type $type" 2>/dev/null | \
    grep -i "$type" | awk '{print $NF}' | tr -d '\r\n'
}

case "$OPERATION" in
  add-cname)
    TARGET=$(fqdn_dot "$TARGET")
    run_cmd "dnscmd $SERVER /recordadd $ZONE $NAME $(ttl_arg)CNAME $TARGET"
    ;;

  update-cname)
    TARGET=$(fqdn_dot "$TARGET")
    OLD=$(get_record_data "$ZONE" "$NAME" "CNAME")
    if [[ -z "$OLD" ]]; then
      echo "ERROR: no existing CNAME found for $NAME in $ZONE" >&2; exit 1
    fi
    echo "Current: $NAME.$ZONE -> $OLD"
    run_cmd "dnscmd $SERVER /recorddelete $ZONE $NAME CNAME $OLD /f"
    run_cmd "dnscmd $SERVER /recordadd $ZONE $NAME $(ttl_arg)CNAME $TARGET"
    ;;

  add-a)
    run_cmd "dnscmd $SERVER /recordadd $ZONE $NAME $(ttl_arg)A $TARGET"
    ;;

  update-a)
    OLD=$(get_record_data "$ZONE" "$NAME" "A")
    if [[ -z "$OLD" ]]; then
      echo "ERROR: no existing A record found for $NAME in $ZONE" >&2; exit 1
    fi
    echo "Current: $NAME.$ZONE -> $OLD"
    run_cmd "dnscmd $SERVER /recorddelete $ZONE $NAME A $OLD /f"
    run_cmd "dnscmd $SERVER /recordadd $ZONE $NAME $(ttl_arg)A $TARGET"
    ;;

  delete)
    # TARGET is the record type (CNAME, A, TXT, etc.)
    run_cmd "dnscmd $SERVER /recorddelete $ZONE $NAME $TARGET /f"
    ;;

  *)
    echo "ERROR: unknown operation '$OPERATION'" >&2
    echo "Valid: add-cname, update-cname, add-a, update-a, delete" >&2
    exit 2
    ;;
esac
