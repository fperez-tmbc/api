#!/usr/bin/env python3
"""
Get a Salesforce access token using JWT Bearer Token flow.
Usage:
  python3 scripts/get_token.py --env prod
  python3 scripts/get_token.py --env sandbox
"""

import argparse
import base64
import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path


def load_creds(creds_path):
    creds = {}
    with open(creds_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            creds[key.strip()] = value.strip()
    return creds


def build_jwt(consumer_key, username, audience, private_key_path):
    header = base64.urlsafe_b64encode(
        json.dumps({"alg": "RS256", "typ": "JWT"}).encode()
    ).rstrip(b"=").decode()

    payload = base64.urlsafe_b64encode(
        json.dumps({
            "iss": consumer_key,
            "sub": username,
            "aud": audience,
            "exp": int(time.time()) + 180,
        }).encode()
    ).rstrip(b"=").decode()

    signing_input = f"{header}.{payload}".encode()

    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    with open(private_key_path, "rb") as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)

    signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    sig_b64 = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()

    return f"{header}.{payload}.{sig_b64}"


def get_token(env):
    creds_path = Path.home() / "GitHub/.tokens/salesforce"
    creds = load_creds(creds_path)

    if env == "prod":
        consumer_key = creds["SF_CONSUMER_KEY_PROD"]
        username = creds["SF_USERNAME_PROD"]
        audience = "https://login.salesforce.com"
        token_url = "https://login.salesforce.com/services/oauth2/token"
    else:
        consumer_key = creds["SF_CONSUMER_KEY_SANDBOX"]
        username = creds["SF_USERNAME_SANDBOX"]
        audience = "https://test.salesforce.com"
        token_url = "https://test.salesforce.com/services/oauth2/token"

    private_key_path = creds["SF_PRIVATE_KEY_PATH"]
    assertion = build_jwt(consumer_key, username, audience, private_key_path)

    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()

    req = urllib.request.Request(token_url, data=data, method="POST")
    with urllib.request.urlopen(req) as resp:
        result = json.load(resp)

    print(json.dumps(result, indent=2))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", choices=["prod", "sandbox"], required=True)
    args = parser.parse_args()
    get_token(args.env)
