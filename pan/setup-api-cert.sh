#!/usr/bin/env bash
set -e

read -rp "PAN hostname (e.g. aupan01.cpp-db.com): " HOST
read -rp "Admin username: " ADMIN_USER
read -rsp "Admin password: " PW; echo
read -rp "Token label (saved to ~/GitHub/.tokens/pan-<label>): " LABEL

TOKENFILE=~/GitHub/.tokens/pan-$LABEL
CERTPASS=pan-api-cert-setup

echo
echo "  Host:  https://$HOST/api/"
echo "  Token: $TOKENFILE"
echo

# Initial token (password auth)
echo "Getting initial token..."
TOKEN=$(curl -sk "https://$HOST/api/" \
  --data-urlencode "type=keygen" \
  --data-urlencode "user=$ADMIN_USER" \
  --data-urlencode "password=$PW" | grep -o 'key>[^<]*' | cut -d'>' -f2)
[[ -z "$TOKEN" ]] && { echo "ERROR: Failed to get token. Check credentials/hostname."; exit 1; }
echo "OK"

# Generate cert
echo "Generating certificate..."
openssl req -x509 -newkey rsa:4096 -keyout /tmp/pan-api.key -out /tmp/pan-api.crt \
  -days 3650 -nodes -subj "/CN=$HOST/O=TMBC/OU=Network/C=US" 2>/dev/null
openssl pkcs12 -export -out /tmp/pan-api.p12 \
  -inkey /tmp/pan-api.key -in /tmp/pan-api.crt -passout pass:$CERTPASS

# Import cert
echo "Importing certificate..."
curl -sk "https://$HOST/api/" \
  -F "type=import" -F "category=keypair" \
  -F "certificate-name=API-KEY-CERT" -F "format=pkcs12" \
  -F "passphrase=$CERTPASS" -F "key=$TOKEN" -F "file=@/tmp/pan-api.p12"
echo

# Set as API key certificate
echo "Setting API key certificate..."
curl -sk "https://$HOST/api/" \
  --data-urlencode "type=config" \
  --data-urlencode "action=set" \
  --data-urlencode "key=$TOKEN" \
  --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/setting/management/api" \
  --data-urlencode "element=<key><certificate>API-KEY-CERT</certificate></key>"
echo

# Commit
echo "Committing..."
JOBID=$(curl -sk "https://$HOST/api/" \
  --data-urlencode "type=commit" \
  --data-urlencode "key=$TOKEN" \
  --data-urlencode "cmd=<commit/>" | grep -o 'job>[0-9]*' | cut -d'>' -f2)
echo "Job $JOBID — waiting 15s..."
sleep 15
curl -sk "https://$HOST/api/" \
  --data-urlencode "type=op" \
  --data-urlencode "key=$TOKEN" \
  --data-urlencode "cmd=<show><jobs><id>$JOBID</id></jobs></show>"
echo

# Regenerate token (now cert-based)
echo "Regenerating cert-based token..."
NEW_TOKEN=$(curl -sk "https://$HOST/api/" \
  --data-urlencode "type=keygen" \
  --data-urlencode "user=$ADMIN_USER" \
  --data-urlencode "password=$PW" | grep -o 'key>[^<]*' | cut -d'>' -f2)
[[ -z "$NEW_TOKEN" ]] && { echo "ERROR: Failed to regenerate token."; exit 1; }
echo -n "$NEW_TOKEN" > "$TOKENFILE"
echo "Token saved to $TOKENFILE"

rm -f /tmp/pan-api.key /tmp/pan-api.crt /tmp/pan-api.p12
echo "Done."
