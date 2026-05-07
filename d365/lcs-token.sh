#!/bin/zsh
source ~/GitHub/.tokens/d365-odata
read -rs "PASSWORD?Password: "
echo

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/common/oauth2/token" \
  -d "grant_type=password" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "resource=https://lcsapi.lcs.dynamics.com" \
  -d "username=admin@themyersbriggs.onmicrosoft.com" \
  -d "password=${PASSWORD}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('error_description','')[:200])")

echo "$TOKEN"
