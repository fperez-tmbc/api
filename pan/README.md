# PAN-OS XML API Field Notes

> **Patching / upgrade runbooks and scripts** live in the task-tracker project folder:
> `~/GitHub/task-tracker/projects/pan-patching/`

## Devices & Tokens

| Device | Role | Model | PAN-OS Version | Base URL | Token file |
|--------|------|-------|----------------|----------|------------|
| AVSPAN01 | AVS firewall (active) | PA-VM (VM-300) | 11.2.12 | `https://avspan01.cpp-db.com/api/` | `~/.tokens/pan-avs` |
| AVSPAN02 | AVS firewall (passive) | PA-VM (VM-300) | 11.2.12 | `https://avspan02.cpp-db.com/api/` | `~/.tokens/pan-avs` (same — HA pair shares token) |
| WHPAN01 | WH firewall (active) | PA-460 | 11.2.12 | `https://whpan01.cpp-db.com/api/` | `~/.tokens/pan-wh` |
| WHPAN02 | WH firewall (passive) | PA-460 | 11.2.12 | `https://whpan02.cpp-db.com/api/` | `~/.tokens/pan-wh` (same — HA pair shares token) |
| AUPAN01 | AU firewall (active) | PA-220 | 10.2.18-h6 | `https://aupan01.cpp-db.com/api/` | `~/.tokens/pan-au` |
| AUPAN02 | AU firewall (passive) | PA-220 | 10.2.18-h6 | `https://aupan02.cpp-db.com/api/` | `~/.tokens/pan-au` (same — HA pair shares token) |
| FRPAN01 | FR firewall (active) | PA-220 | 10.2.18-h6 | `https://frpan01.cpp-db.com/api/` | `~/.tokens/pan-fr` |
| FRPAN02 | FR firewall (passive) | PA-220 | 10.2.18-h6 | `https://frpan02.cpp-db.com/api/` | `~/.tokens/pan-fr` (same — HA pair shares token) |
| DCPANORAMA01 | Panorama management | Panorama (VM) | 11.2.12 | `https://dcpanorama01.cpp-db.com/api/` | `~/.tokens/pan-panorama` |

_Versions last verified: 2026-05-27_

- PA-220 (AUPAN, FRPAN) max supported PAN-OS is 10.2.x — no upgrade path to 11.x exists

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

**Usually unnecessary — `activate` auto-purges the prior version.** After activating a new
GP client version, the previously-active one is removed automatically; its API `downloaded`
flag flips to `no` within a few minutes (it can briefly still read `yes` right after activate —
that's API lag, not a failure). An explicit delete then reports
`No images match '['gpclient', '<ver>']' for purging` or `Server error : <ver> does not exist`
because there is nothing left to purge — expected, not an error.
(Verified fleet-wide 2026-07-16 upgrading c1016 → c1105: all 8 firewalls auto-purged c1016.)

If you do need to remove one that's genuinely still present:

```bash
# MUST be heredoc / piped stdin — `ssh host "delete ..."` returns empty and does NOT execute.
printf 'set cli pager off\ndelete global-protect-client version 6.3.3-c915\nexit\n' \
  | ssh -i ~/GitHub/.tokens/svcclaude-key <opts> svcclaude@<host>
```

- No confirmation prompt — the `y` is not needed and will cause "Unknown command: y"
- Verify with `info` after: `downloaded` should be `no`
- **PAN-OS SSH:** operational commands only run via heredoc/stdin, never as `ssh host "cmd"`.
- **zsh gotcha:** don't stuff flags into a scalar and run `ssh $SSH_OPTS ...` — zsh does NOT
  word-split unquoted scalars, so the entire string lands in `-i` ("Identity file … not
  accessible" → "Too many authentication failures"). Use a zsh array
  (`opts=(-o A -o B …); ssh -i KEY "${opts[@]}" …`) or inline every flag.

---

## Device Certificate (CDSS)

PAN device certificates are required for Cloud-Delivered Security Services (Threat Prevention, WildFire, URL Filtering, DNS Security, etc.). A missing/expired cert silently degrades those features. Certs are ~90-day and auto-renew while the device can reach PAN's cert cloud.

### Check status (API op — read-only)

```
type=op  cmd=<show><device-certificate><status></status></device-certificate></show>
```

Returns `Device certificate not found`, or `<validity>Valid</validity>` with `not_valid_after`.

### Install / fetch with OTP

- Correct command: `request certificate fetch otp <OTP>`
  - XML op: `<request><certificate><fetch><otp>OTP</otp></fetch></certificate></request>`
- **Gotcha:** `<fetch><pan-device-certificate>OTP</...>` is REJECTED on 11.2.x ("unexpected here"). The child element is `<otp>`, not `pan-device-certificate`.
- OTP is generated per-serial in the CSP: **Products → Device Certificates → Generate OTP → PAN-OS type**. 60-minute lifetime; the firewall makes **one** fetch attempt — if it fails, the OTP is spent and you regenerate. (A local XML syntax error does NOT consume the OTP — the job never runs.)
- **Per device, per HA peer** — device certs are NOT synced across an HA pair; fetch on each peer with its own OTP.
- **No commit and no failover** — management-plane fetch, installs instantly; safe on live HA pairs.
- Returns a job (`Device-certificate-fetch`); poll `<show><jobs><id>JOBID</id></jobs></show>` until `FIN`/`OK`. PA-220 (10.2.x) takes ~20–60s; PA-VM / Panorama / PA-460 are near-instant.
- Verify with the status op above (`<validity>Valid</validity>`).

_Fleet baseline 2026-07-07: all 9 devices carry valid device certs (AVS/AU/FR/Panorama fetched this date, WH pair already valid). Tied to PAN case 04101798._

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

> **zsh warning:** the `SSH_OPTS="…"; ssh $SSH_OPTS …` form below word-splits correctly in bash
> but NOT in zsh (Claude Code's shell). Under zsh the whole string collapses into the `-i` value
> and auth fails. Use `ssh ${=SSH_OPTS} …`, a `opts=(…)` array with `"${opts[@]}"`, or inline the flags.

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
- Use **`task-tracker/projects/pan-patching/pan-upgrade.sh`** for automated installs — polls until FIN before rebooting

### Upgrade order for HA pairs

1. Download on both peers in parallel (API)
2. Run `software check` on both to refresh list if versions aren't showing
3. Install + reboot passive peer first using `task-tracker/projects/pan-patching/pan-upgrade.sh`; wait for it to return to passive HA state
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

> **Moved to the knowledge-base repo:** `knowledge-base/procedures/pan-pa220-disk-cleanup.md`
>
> Full PA-220 disk-space troubleshooting lives there — `show system pancfg-directory-usage`,
> what's reclaimable non-interactively (superseded content/AV `.tgz`, debug logs) vs. what isn't
> (`oldcontent`/`oldav`, base image, the PAN-300055 `content-preview` bug), plus the frpan01
> worked example (2026-07-16).

## Known Panorama Behaviors

- `get` on template-managed nodes returns empty (code 7) or merged config (code 19) — reads always work
- `set` fails with "may need to override template object" when name contains slashes or when truly template-locked
- Peer group modification requires web UI (template-managed); sub-nodes like redist-rules and aggregation are device-level
