#!/usr/bin/env python3
"""
One-time login to obtain Mimecast API 1.0 Access Key and Secret Key.
Usage: python3 login.py <password>
Reads APP_ID and APP_KEY from ~/GitHub/.tokens/mimecast.
Prints the Access Key and Secret Key to stdout for storage.
"""

import base64, hashlib, hmac, uuid, datetime, json, sys, os, urllib.request
from pathlib import Path

def load_env(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

def mimecast_request(base_url, uri, app_id, app_key, access_key, secret_key, payload):
    req_id = str(uuid.uuid4())
    date   = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S UTC")

    if access_key and secret_key:
        data_to_sign = f"{date}:{req_id}:{uri}:{app_key}"
        sig = base64.b64encode(
            hmac.new(base64.b64decode(secret_key), data_to_sign.encode(), hashlib.sha1).digest()
        ).decode()
        auth = f"MC {access_key}:{sig}"
    else:
        # Pre-login: sign with app_key directly
        data_to_sign = f"{date}:{req_id}:{uri}:{app_key}"
        sig = base64.b64encode(
            hmac.new(app_key.encode(), data_to_sign.encode(), hashlib.sha1).digest()
        ).decode()
        auth = f"MC {base64.b64encode(app_id.encode()).decode()}:{sig}"

    headers = {
        "Authorization": auth,
        "x-mc-app-id": app_id,
        "x-mc-date": date,
        "x-mc-req-id": req_id,
        "Content-Type": "application/json"
    }
    body = json.dumps(payload).encode()
    req  = urllib.request.Request(base_url + uri, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode())

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 login.py <password>")
        sys.exit(1)

    password  = sys.argv[1]
    creds_path = Path.home() / "GitHub/.tokens/mimecast"
    env        = load_env(creds_path)
    app_id     = env["MIMECAST_APP_ID"]
    app_key    = env["MIMECAST_APP_KEY"]
    username   = "2fperez@themyersbriggs.com"
    base_url   = "https://us-api.mimecast.com"

    result = mimecast_request(
        base_url, "/api/login/login", app_id, app_key, None, None,
        {"data": [{"userName": username, "password": password}]}
    )

    print(json.dumps(result, indent=2))
