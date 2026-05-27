#!/usr/bin/env zsh
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

CREDS_FILE="/Users/fperez2nd/GitHub/.tokens/svcclaude"
DEFAULT_SERVER="SVDCDC01.cpp-db.com"
SSH_USER="${SSH_USER:-cpp-db\\svcclaude}"

if [[ ! -f "$CREDS_FILE" ]]; then
  echo "ERROR: creds file not found at $CREDS_FILE" >&2
  exit 1
fi
source "$CREDS_FILE"

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
  sshpass -p "$PASSWORD" ssh -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
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
