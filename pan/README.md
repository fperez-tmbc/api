# PAN-OS XML API Field Notes

## Devices & Tokens

| Device | Role | Model | PAN-OS Version | Base URL | Token file |
|--------|------|-------|----------------|----------|------------|
| AVSPAN01 | AVS firewall (active) | PA-VM (VM-300) | 11.2.10-h8 | `https://avspan01.cpp-db.com/api/` | `~/.tokens/pan-avs` |
| AVSPAN02 | AVS firewall (passive) | PA-VM (VM-300) | 11.2.10-h8 | `https://avspan02.cpp-db.com/api/` | `~/.tokens/pan-avs` (same — HA pair shares token) |
| WHPAN01 | WH firewall (active) | PA-460 | 11.2.10-h8 | `https://whpan01.cpp-db.com/api/` | `~/.tokens/pan-wh` |
| WHPAN02 | WH firewall (passive) | PA-460 | 11.2.10-h8 | `https://whpan02.cpp-db.com/api/` | `~/.tokens/pan-wh` (same — HA pair shares token) |
| AUPAN01 | AU firewall (active) | PA-220 | 10.2.18-h6 | `https://aupan01.cpp-db.com/api/` | `~/.tokens/pan-au` |
| AUPAN02 | AU firewall (passive) | PA-220 | 10.2.18-h6 | `https://aupan02.cpp-db.com/api/` | `~/.tokens/pan-au` (same — HA pair shares token) |
| FRPAN01 | FR firewall (active) | PA-220 | 10.2.18-h6 | `https://frpan01.cpp-db.com/api/` | `~/.tokens/pan-fr` |
| FRPAN02 | FR firewall (passive) | PA-220 | 10.2.18-h6 | `https://frpan02.cpp-db.com/api/` | `~/.tokens/pan-fr` (same — HA pair shares token) |
| DCPANORAMA01 | Panorama management | Panorama (VM) | 11.2.10-h8 | `https://dcpanorama01.cpp-db.com/api/` | `~/.tokens/pan-panorama` |

_Versions last verified: 2026-05-27_

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

## GlobalProtect Client Management

GP client packages are managed on the firewall and pushed to endpoints by GlobalProtect gateway.

### API commands (type=op)

```bash
# Check for available versions (refreshes the list)
cmd=<request><global-protect-client><software><check/></software></global-protect-client></request>

# Download a specific version — returns job ID; poll until FIN
cmd=<request><global-protect-client><software><download><version>6.3.3-c1016</version></download></software></global-protect-client></request>

# Activate a downloaded version — returns job ID; poll until FIN
cmd=<request><global-protect-client><software><activate><version>6.3.3-c1016</version></activate></software></global-protect-client></request>

# List versions and download/active status
cmd=<request><global-protect-client><software><info/></software></global-protect-client></request>
```

- Download and activate on both HA peers in parallel — do **not** use `sync-to-peer` (slower than parallel direct downloads)
- Activate job completes in ~30–60 seconds; poll job status the same way as any other job

### Delete an old GP client version (SSH only)

```bash
ssh svcclaude@<host> << 'EOF'
delete global-protect-client version 6.3.3-c915
exit
EOF
```

- No confirmation prompt — the `y` is not needed and will cause "Unknown command: y"
- Verify with `info` after: `downloaded` should change to `no`

---

## Software Management

### Downloads and version listing (API)

```bash
# Check / refresh available versions
type=op  cmd=<request><system><software><check/></software></system></request>

# Download a version — returns job ID
type=op  cmd=<request><system><software><download><version>11.2.10-h8</version></download></software></system></request>
```

- Always run `check` before verifying downloaded state — the local list can be stale
- `check` API call can take >60 seconds on PA-220 — use `--max-time 120`
- Verify with `check` then confirm `<downloaded>yes</downloaded>` for target version
- After upgrading, software info may show no `[CURRENT]` version until `check` is re-run — this is cosmetic; confirm version via `show system info` instead

### Install, delete, reboot (SSH only — not exposed via API)

Use key-based SSH with stdin heredoc. On PAN-OS 10.2.x, always add `-o IdentitiesOnly=yes -o IdentityAgent=none -o PubkeyAcceptedAlgorithms=rsa-sha2-256` to avoid "Too many authentication failures" from the agent offering extra keys.

```bash
SSH_OPTS="-i ~/.tokens/svcclaude-key-rsa -o StrictHostKeyChecking=no -o PasswordAuthentication=no \
  -o IdentitiesOnly=yes -o IdentityAgent=none -o PubkeyAcceptedAlgorithms=rsa-sha2-256 -o ConnectTimeout=30"

# Install
ssh $SSH_OPTS svcclaude@<host> << 'EOF'
request system software install version 10.2.18-h6
y
exit
EOF

# Reboot — wrap with timeout 30 so the script doesn't hang when the session drops
timeout 30 ssh $SSH_OPTS svcclaude@<host> << 'EOF' || true
request restart system
y
exit
EOF
```

- `delete software version <ver>` — removes a downloaded image (SSH only)
- `request system software install version <ver>` — prompts for `y`; enqueues install job
- `request system software info` — lists all versions and downloaded status
- `request restart system` — prompts for `y`; exit code 255 on success (session drops with device)
- Poll install job via API: `type=op cmd=<show><jobs><id>JOBID</id></jobs></show>` until `<status>FIN</status>`
- **Never reboot before the install job reaches FIN** — rebooting mid-install leaves the device on an unrecognized intermediate version (observed: `10.2.18.2-50` after interrupting a 10.2.18-h6 install at 57%)
- Use **`pan/pan-upgrade.sh`** for automated installs — polls until FIN before rebooting

### Upgrade order for HA pairs

1. Download on both peers in parallel (API)
2. Run `software check` on both to refresh list if versions aren't showing
3. Install + reboot passive peer first using `pan-upgrade.sh`; wait for it to return to passive HA state
4. Install + reboot active peer; brief failover to other peer expected
5. Confirm both peers show matching version and `build-compat: Match` in HA state
6. Delete old version from both (SSH), verify via `software check` + info
- PA-220 reboots take ~20–25 minutes to come back on API after a 5-minute initial wait

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

## Disk Cleanup (PA-220 / PAN-OS 10.2.x)

### Show disk usage
```
show system pancfg-directory-usage
```

### debug pancfg-directory-usage clean — full syntax

```
debug pancfg-directory-usage clean config saved <filename>
debug pancfg-directory-usage clean dynamic-updates anti-virus update <filename>
debug pancfg-directory-usage clean dynamic-updates content update <filename>
debug pancfg-directory-usage clean software-images version <version>
```

- Filenames require tab-completion on an interactive SSH session — not discoverable via API or non-interactive SSH
- `dynamic-updates` subcommands operate on downloaded `.tgz` files in `mgmt/av-images` and `mgmt/content-images` only — NOT on the extracted packages in `updates/oldav` / `updates/oldcontent`
- `software-images version 10.2.0` is blocked ("Can't purge base image") while 10.2.18-h1 is installed — base image is always protected
- `debug software disk-usage cleanup deep threshold 90` errors on PA-220 10.2.x
- `debug software disk-usage aggressive-cleaning enable` — valid command but confirmation prompt reads from `/dev/tty`; must be answered interactively (`y`)

### What can be cleaned non-interactively
```bash
# Delete debug log files (SSH heredoc)
delete debug-log mp-log file *.1
delete debug-log mp-log file *.2
delete debug-log mp-log file *.3
delete debug-log mp-log file *.4
delete debug-log mp-log file *.old

# Delete a specific downloaded content package (SSH) — also auto-purges corresponding oldcontent dir
delete content update panupv2-all-contents-<version>.tgz

# Delete a specific downloaded AV package (SSH)
delete anti-virus update panup-all-antivirus-<version>.tgz

# Clear old content cache (API op or SSH)
delete content cache old-content
```

### What requires interactive SSH (tab-completion to find filenames/versions)
- `debug pancfg-directory-usage clean config saved <TAB>` — old saved configs (~41M on AU)
- `debug pancfg-directory-usage clean dynamic-updates anti-virus update <TAB>` — old downloaded AV .tgz packages
- `debug pancfg-directory-usage clean dynamic-updates content update <TAB>` — old downloaded content .tgz packages
- `delete global-protect-client image <TAB>` / `delete global-protect-client version <TAB>` — old GP client images (~551M)
- `debug software disk-usage aggressive-cleaning enable` → confirm `y`

### content-preview disk accumulation (PAN-300055)
Known bug: firewall accumulates large content-preview directories in `/opt/pancfg/mgmt/content-preview/<version>/` when an error occurs during content update cleanup. Normal size is ~19M per version; bug leaves behind 1GB+.
- `delete content preview <version>` — Invalid syntax on 10.2.x
- `delete content update <filename.tgz>` — removes the downloaded package but does NOT clear the preview directory
- Config xpath `/config/shared/content-preview` exists but does not contain version-specific entries — config delete won't help
- PAN-300055 not fixed in 10.2.18-h1 — watch future hotfix release notes
- Workaround: none found via non-interactive SSH; may require interactive session or TAC

### Non-deletable items
- `updates/oldav` and `updates/oldcontent` — extracted previously-installed packages; system-managed, not removable by user commands
- `updates/curav` and `updates/curcontent` — currently active packages
- Base software image (10.2.0) — protected while current version is installed

## Known Panorama Behaviors

- `get` on template-managed nodes returns empty (code 7) or merged config (code 19) — reads always work
- `set` fails with "may need to override template object" when name contains slashes or when truly template-locked
- Peer group modification requires web UI (template-managed); sub-nodes like redist-rules and aggregation are device-level
