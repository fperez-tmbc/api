# PAN-OS XML API Field Notes

## Devices & Tokens

| Device | Role | Base URL | Token file |
|--------|------|----------|------------|
| AVSPAN01 | AVS firewall (active) | `https://avspan01.cpp-db.com/api/` | `~/.tokens/pan-avs` |
| AVSPAN02 | AVS firewall (passive) | `https://avspan02.cpp-db.com/api/` | `~/.tokens/pan-avs` (same — HA pair shares token) |
| WHPAN01 | WH firewall (active) | `https://whpan01.cpp-db.com/api/` | `~/.tokens/pan-wh` |
| WHPAN02 | WH firewall (passive) | `https://whpan02.cpp-db.com/api/` | `~/.tokens/pan-wh` (same — HA pair shares token) |
| AUPAN01 | AU firewall (active) | `https://aupan01.cpp-db.com/api/` | `~/.tokens/pan-au` |
| AUPAN02 | AU firewall (passive) | `https://aupan02.cpp-db.com/api/` | `~/.tokens/pan-au` (same — HA pair shares token) |
| FRPAN01 | FR firewall (active) | `https://frpan01.cpp-db.com/api/` | `~/.tokens/pan-fr` |
| FRPAN02 | FR firewall (passive) | `https://frpan02.cpp-db.com/api/` | `~/.tokens/pan-fr` (same — HA pair shares token) |
| DCPANORAMA01 | Panorama management | `https://dcpanorama01.cpp-db.com/api/` | `~/.tokens/pan-panorama` |

- Token format: `hash:base64url` (certificate-based, PAN-OS 11.x+) or standard base64 (PAN-OS 10.x)
- AU/FR pairs run PAN-OS 10.2.x — standard token format, no API key cert setup needed
- DCPANORAMA01 runs PAN-OS 11.2.x — cert-based token
- Same API token works on both peers of an HA pair
- **SSH key auth (svcclaude):**
  - AVSPAN, WHPAN, DCPANORAMA01 (PAN-OS 11.x): ed25519 — `~/.tokens/svcclaude-key`
  - AUPAN, FRPAN (PAN-OS 10.2.x): RSA 4096 — `~/.tokens/svcclaude-key-rsa`
  - PAN-OS 10.2.x rejects ed25519 via API; RSA uses same base64(full_key_line) format as 11.x

## General

- **Device entry name:** `localhost.localdomain`
- Always use `--data-urlencode` with curl for all parameters

### Common curl pattern

```bash
TOKEN=$(cat ~/GitHub/.tokens/pan-avs | tr -d '[:space:]')
curl -sk "https://avspan01.cpp-db.com/api/" \
  --data-urlencode "type=config" \
  --data-urlencode "action=get" \
  --data-urlencode "key=$TOKEN" \
  --data-urlencode "xpath=<XPATH>"
```

## Naming Conventions

- All object names **uppercase**
- Account-scoped where applicable (e.g. `AWS-TMBC` prefix)
- Crypto profiles named by cipher suite (reusable across accounts)

## Tunnel Numbering

| Account | Tunnels | Zone |
|---------|---------|------|
| TMBC (954945276385) | tunnel.209 / tunnel.210 | AWS-TMBC |
| VitaNavis (433597029398) | tunnel.211 / tunnel.212 | AWS-VITANAVIS |

## Xpaths — Network Objects

### Security Zone
```
/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='vsys1']/zone/entry[@name='<ZONE>']
```
Element: `<network><layer3/></network>`

### Tunnel Interface
```
/config/devices/entry[@name='localhost.localdomain']/network/interface/tunnel/units/entry[@name='tunnel.<N>']
```
Element: `<comment>...</comment>` — IP assigned separately via VR interface binding

### Tunnel Interface IPs

Use entry format: `<ip><entry name="169.254.255.254/30"/></ip>` (NOT `<member>`)

### IKE Crypto Profile
```
/config/devices/entry[@name='localhost.localdomain']/network/ike/crypto-profiles/ike-crypto-profiles/entry[@name='<NAME>']
```
Example element (IKEv2, AES-256-CBC, SHA-256, DH14):
```xml
<hash><member>sha256</member></hash>
<dh-group><member>group14</member></dh-group>
<encryption><member>aes-256-cbc</member></encryption>
<lifetime><hours>8</hours></lifetime>
```

### IPsec Crypto Profile
```
/config/devices/entry[@name='localhost.localdomain']/network/ike/crypto-profiles/ipsec-crypto-profiles/entry[@name='<NAME>']
```
Example element (AES-256-CBC, SHA-256):
```xml
<esp><encryption><member>aes-256-cbc</member></encryption><authentication><member>sha256</member></authentication></esp>
<dh-group>group14</dh-group>
<lifetime><hours>1</hours></lifetime>
```

### IKE Gateway
```
/config/devices/entry[@name='localhost.localdomain']/network/ike/gateway/entry[@name='<NAME>']
```
Key fields: peer IP, `ethernet1/1` as local interface, IKE crypto profile, pre-shared key, IKEv2 only.

### IPsec Tunnel
```
/config/devices/entry[@name='localhost.localdomain']/network/tunnel/ipsec/entry[@name='<NAME>']
```
Key fields: tunnel interface, IKE gateway, IPsec crypto profile, DPD restart.

## BGP (VR: DEFAULT)

- **Base xpath:** `/config/devices/entry[@name='localhost.localdomain']/network/virtual-router/entry[@name='DEFAULT']/protocol/bgp`
- `install-route`: set under `bgp` node directly — `<install-route>yes</install-route>`
- Peer group and peers are Panorama-template-managed; configure via web UI
- **Router ID:** `10.200.255.253` (same as OSPF router-ID)
- **Local ASN:** `65000`

### BGP Aggregation

- xpath: `bgp/policy/aggregation/address/entry[@name='<LABEL>']`
- Entry `name` is a **label** (e.g. "US"), NOT the prefix — names with slashes fail silently with misleading "override template" error
- Element: `<prefix>10.70.0.0/16</prefix><enable>yes</enable><summary>yes</summary>`
- Note: element is `<summary>` not `<summary-only>`

### BGP Redistribution Rules

- xpath: `bgp/redist-rules/entry[@name='BGP-EXPORT-ALL']`
- Entry name matches the VR-level redist-profile name — that is the implicit link in PAN-OS 11.x
- Element: `<address-family-identifier>ipv4</address-family-identifier><enable>yes</enable><set-origin>igp</set-origin>`
- No `<redist-profile>` child element in PAN-OS 11.x

### BGP Export Policy

- xpath: `bgp/policy/export/rules/entry[@name='<NAME>']`
- Peer group association: `<used-by><member>AWS-TMBC</member></used-by>` — uses `<member>`, NOT `<entry>`
- Address prefix match: `<match><address-prefix><entry name="10.70.0.0/16"><exact>yes</exact></entry>...</address-prefix></match>`
- Action allow: `<action><allow/></action>`
- Action deny: `<action><deny/></action>`
- GUI flow to add peer group: Network → Virtual Routers → DEFAULT → BGP → Export Policy → [rule] → Add [peer group]

## GlobalProtect Split Tunnel

**Third-octet convention:** GP pool matches site subnet third octet (e.g. GP TMBC-WH `10.255.20.x` matches site `10.10.20.x`).

- xpath: `/config/devices/entry/vsys/entry/global-protect/global-protect-gateway/entry/remote-user-tunnel-configs/entry[@name='EMPLOYEES']/split-tunneling/access-route`
- Element to add a network: `<member>10.50.240.0/22</member>`

## Software Management

### Downloads and version listing (API)

```bash
# Check / refresh available versions
type=op  cmd=<request><system><software><check/></software></system></request>

# Download a version — returns job ID
type=op  cmd=<request><system><software><download><version>11.2.10-h8</version></download></software></system></request>
```

- Always run `check` before verifying downloaded state — the local list can be stale
- Verify with `check` then confirm `<downloaded>yes</downloaded>` for target version

### Install, delete, reboot (SSH only — not exposed via API)

Use key-based SSH with stdin heredoc. Include `y` to answer confirmation prompts; if heredoc `y` gets stuck use `printf`:

```bash
# Key-based (preferred)
ssh -i ~/.tokens/svcclaude-key -o StrictHostKeyChecking=no -o PasswordAuthentication=no svcclaude@<host> << 'EOF'
request system software install version 11.2.10-h8
y
exit
EOF

# Reboot (use printf if heredoc y gets stuck)
printf 'request restart system\ny\nexit\n' | ssh -i ~/.tokens/svcclaude-key \
  -o StrictHostKeyChecking=no -o PasswordAuthentication=no svcclaude@<host>
```

- `delete software version <ver>` — removes a downloaded image (SSH only)
- `request system software install version <ver>` — prompts for `y`; enqueues install job
- `request system software info` — lists all versions and downloaded status
- `request restart system` — prompts for `y`; exit code 255 on success (session drops with device)
- Poll install job: `show jobs id <JOBID>` until `FIN / OK`

### Upgrade order for HA pairs

1. Download on both peers in parallel (API)
2. Verify downloaded state on both (API check)
3. Install + reboot passive peer first; wait for it to return to passive HA state before touching active
4. Install + reboot active peer; brief failover to other peer expected
5. Confirm both show `FIN / OK` version and HA state synchronized
6. Delete old version from both (SSH), verify via API check

## API Key Certificate Setup

PAN-OS will warn about deprecated keygen algorithm if no API key certificate is configured. Fix:

1. Generate a self-signed cert locally and import as PKCS12:
```bash
openssl req -x509 -newkey rsa:4096 -keyout /tmp/pan-api.key -out /tmp/pan-api.crt \
  -days 3650 -nodes -subj "/CN=<hostname>/O=TMBC/OU=Network/C=US"
openssl pkcs12 -export -out /tmp/pan-api.p12 \
  -inkey /tmp/pan-api.key -in /tmp/pan-api.crt -passout pass:<passphrase>
```
2. Import to firewall:
```bash
curl -sk "https://<host>/api/" -F "type=import" -F "category=keypair" \
  -F "certificate-name=API-KEY-CERT" -F "format=pkcs12" \
  -F "passphrase=<passphrase>" -F "key=$TOKEN" -F "file=@/tmp/pan-api.p12"
```
3. Set as API key certificate:
```
type=config  action=set
xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/setting/management/api
element=<key><certificate>API-KEY-CERT</certificate></key>
```
4. Commit, then have admin regenerate the API key via browser or `read -s` curl keygen call
5. Delete temp files from `/tmp`

## Admin Accounts

xpath: `/config/mgt-config/users`

- Add account: `action=set`, element `<entry name='USERNAME'><permissions><role-based><superuser>yes</superuser></role-based></permissions><authentication-profile>PROFILE</authentication-profile></entry>`
- Delete account: `action=delete`, xpath `.../entry[@name='USERNAME']`
- Add SSH public key: `action=set`, xpath `.../entry[@name='USERNAME']`, element `<public-key>BASE64_OF_FULL_PUBKEY_LINE</public-key>`

## HA State Check

```bash
show high-availability state
```

Key fields to verify after upgrade/reboot:
- `State: active` / `State: passive` — both peers present
- `Software Version: Match`
- `State Synchronization: Complete`
- `Running Configuration: synchronized`
- HA1/HA2 `Connection up`

Anti-Virus `Mismatch` after upgrade is normal (content version difference) and does not affect HA operation.

## Commit

- Always poll job status: `type=op`, `cmd=<show><jobs><id>JOBID</id></jobs></show>`
- Warnings (not errors) in Detail lines do not prevent OK result
- HA sync adds ~30s to commit time; Panorama connectivity check adds another ~15s

## Known Panorama Behaviors

- `get` on template-managed nodes returns empty (code 7) or merged config (code 19) — reads always work
- `set` fails with "may need to override template object" when name contains slashes or when truly template-locked
- Peer group modification requires web UI (template-managed); sub-nodes like redist-rules and aggregation are device-level
