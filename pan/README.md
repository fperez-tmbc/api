# PAN-OS XML API Field Notes

> ## ℹ️ `svcclaude` on PAN-OS is NOT affected by the AD decommission
>
> The **AD account** `CPP-DB\svcclaude` was decommissioned 2026-08-02, but PAN firewalls keep their
> own local user database, so the identically-named **PAN-OS local account is still valid**.
> Verified 2026-08-02 against AVSPAN01 and WHPAN01 — key auth succeeded and returned the
> `svcclaude@AVSPAN01(active)>` prompt.
>
> **Keep using `~/GitHub/.tokens/svcclaude-key` (ed25519) and `svcclaude-key-rsa` (RSA 4096).**
> Nothing in this document needs to change. Do not "fix" it by swapping in an AD account.



> **Patching / upgrade runbooks and scripts** live in the task-tracker project folder:
> `~/GitHub/task-tracker/projects/pan/pan-patching/`

## Devices & Tokens

| Device | Serial | Role | Model | PAN-OS Version | Base URL | Token file |
|--------|--------|------|-------|----------------|----------|------------|
| AVSPAN01 | | AVS firewall (active) | PA-VM (VM-300) | 11.2.13 | `https://avspan01.cpp-db.com/api/` | `~/.tokens/pan-avs` |
| AVSPAN02 | | AVS firewall (passive) | PA-VM (VM-300) | 11.2.13 | `https://avspan02.cpp-db.com/api/` | `~/.tokens/pan-avs` (same — HA pair shares token) |
| WHPAN01 | | WH firewall (active) | PA-460 | 11.2.13 | `https://whpan01.cpp-db.com/api/` | `~/.tokens/pan-wh` |
| WHPAN02 | | WH firewall (passive) | PA-460 | 11.2.13 | `https://whpan02.cpp-db.com/api/` | `~/.tokens/pan-wh` (same — HA pair shares token) |
| AUPAN01 | 012801036554 | AU firewall (active) | PA-220 | 10.2.18-h9 | `https://aupan01.cpp-db.com/api/` | `~/.tokens/pan-au` |
| AUPAN02 | 012801036577 | AU firewall (passive) | PA-220 | 10.2.18-h9 | `https://aupan02.cpp-db.com/api/` | `~/.tokens/pan-au` (same — HA pair shares token) |
| FRPAN01 | 012801036562 | FR firewall (active) | PA-220 | 10.2.18-h9 | `https://frpan01.cpp-db.com/api/` | `~/.tokens/pan-fr` |
| FRPAN02 | 012801036206 | FR firewall (passive) | PA-220 | 10.2.18-h9 | `https://frpan02.cpp-db.com/api/` | `~/.tokens/pan-fr` (same — HA pair shares token) |
| DCPANORAMA01 | | Panorama management | Panorama (VM) | 11.2.12 (unverified) | `https://dcpanorama01.cpp-db.com/api/` | `~/.tokens/pan-panorama` |

_Versions last verified: 2026-08-02 — all 8 firewalls confirmed live via `show system info`.
DCPANORAMA01 was **not** reachable that date (empty API response, no ICMP), so its 11.2.12 entry
is stale-as-of-2026-05-27, not a current reading. See `project-panorama-decommission` before
treating that as a fault._

Serial column is filled in as devices get audited — populated ones are confirmed from
`show system info`, blanks just mean not yet recorded. Serials matter for CSP licensing work
(auth codes are issued per-serial).

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

## Routing lookups

### ⚠️ The virtual-router name is NOT `DEFAULT` everywhere

| Site | VR name |
|------|---------|
| AVSPAN01/02 | `DEFAULT` |
| **WHPAN01/02** | **`CORE-ROUTER`** |
| **AUPAN01/02** | **`CORE-ROUTER`** |
| FRPAN01/02 | `DEFAULT` |

Guessing `DEFAULT` on WH or AU returns
`DEFAULT is invalid virtual-router.Current target-vsys is none` (code 17) — which reads like a vsys or
permissions problem and is neither. Confirm the name first:

```bash
type=config action=get \
  xpath=/config/devices/entry[@name='localhost.localdomain']/network/virtual-router
# take only TOP-LEVEL <entry name="..."> — a naive grep also picks up nested
# redist-profile / protocol entries, several of which are literally called "DEFAULT"
```

### `fib-lookup` output shape

```
type=op cmd=<test><routing><fib-lookup><virtual-router>VR</virtual-router><ip>IP</ip></fib-lookup></routing></test>
```

Returns `<dp>`, `<nh>` (nexthop *type*), `<interface>`, `<ip>` (nexthop address), `<src>`, `<metric>`.
**There is no `<dst>` element** — grepping for one yields empty on every lookup and looks like "no
route" fleet-wide. `<nh>drop</nh>` with no interface is the real no-route signal.

### Two traps that produce confidently wrong conclusions

**Probing `x.x.0.1` of a `/16` proves nothing.** A subnetted `/16` usually has no route for its own
first address, so the lookup falls through to the default route. Cost a wrong "no internal path" call on
`10.10.0.0/16` at WH, which is in fact connected on `ae2.20`. Use `show routing route` and check for a
covering supernet or contained subnets instead of inventing probe addresses.

**A default-route result means opposite things at different sites.** AVS's default nexthop is
`10.200.255.254`, the **core router**, so falling through to it is still an internal path. At WH/AU/FR
the default nexthop is a public ISP address (`50.189.23.210`, `14.201.118.133`, `77.158.160.9`), so
there the same result means no internal path and RFC1918 traffic dies upstream. Always resolve the
device's own default route first (`fib-lookup` on `8.8.8.8`) and compare against it.

## BGP (VR: DEFAULT on AVS/FR, CORE-ROUTER on WH/AU)

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

### Domain-based split tunnel — use this for anything with rotating IPs

The `split-tunneling` node has **four** siblings beyond `access-route`, and they are easy to miss
(GUI: Split Tunnel → **"Domain and Application"** tab, separate from the Access Route tab):

```
split-tunneling/
  access-route            <- destination CIDRs (the familiar one)
  exclude-access-route
  include-domains/list    <- domain-based INCLUDE
  exclude-domains/list
  include-applications
  exclude-applications
```

xpath: `.../entry[@name='EMPLOYEES']/split-tunneling/include-domains/list`

#### Element form: `<entry name="…">`, NOT `<member>`

Same trap as tunnel interface IPs. `<list><member>*.adp.com</member></list>` fails with
`include-domains -> list is invalid` (code 12). The list takes named entries:

```bash
XP="/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='vsys1']/global-protect/global-protect-gateway/entry[@name='GP_GATEWAY']/remote-user-tunnel-configs/entry[@name='EMPLOYEES']/split-tunneling"

curl -sk "https://avspan01.cpp-db.com/api/" \
  --data-urlencode "type=config" --data-urlencode "action=set" --data-urlencode "key=$TOKEN" \
  --data-urlencode "xpath=$XP/include-domains" \
  --data-urlencode "element=<list><entry name=\"*.salesforce.com\"/><entry name=\"salesforce.com\"/></list>"
```

Remove one entry (this is the rollback):
`action=delete xpath=$XP/include-domains/list/entry[@name='*.adp.com']` — leaves `<list/>`, i.e. the
original empty state. `action=complete` for schema introspection on these nodes returns
`Internal error` (code 3), so build the element on the candidate and read it back instead.

**Wildcards:** `*.adp.com` matches subdomains but **not** the parent, so add both `*.adp.com` and
`adp.com`. (`*adp.com` — no dot — matches both, but also matches anything ending in `adp.com`.)

**Verified on AVSPAN01 2026-08-05:** PAN-OS **11.2.13**. Requires GP app **5.2+** (**6.1+** on
Linux); all 56 connected users were on 6.3.x. Requires tunnel-mode (`<tunnel-mode>yes</tunnel-mode>`
— already set). Portal agent `split-tunnel-option` is `network-traffic`, which is correct; `both`
would additionally domain-split DNS itself.

#### ⚠️ Windows domain-based split tunnel is TCP-only

Per PAN docs: **no UDP, no ICMP** for domain-based rules on Windows (macOS uses network extensions,
Linux is domain/route only — no application rules). On this fleet **52 of 56 users are Windows**.

This is the thing to weigh before replacing a CIDR with a domain: an `access-route` entry captures
every protocol, a domain entry captures TCP. **QUIC (UDP 443) will silently egress locally** rather
than tunnel. So for entries that exist specifically so a SaaS sees the office egress IP, a domain
entry is necessary-but-maybe-not-sufficient — verify with real traffic before dropping the CIDR.

Also: a domain rule can only match traffic that resolved a hostname. **Traffic to a literal IP never
matches** — so SSH-by-IP entries (the AWS Lightsail /32s) must stay as `access-route` CIDRs forever.

**Capacity:** 200 entries max per include/exclude domain list in the gateway config. Hosting a
split-tunnel config file on a web server raises the ceiling to 1,000 domains+routes.

**When to prefer it over `access-route`:** any SaaS endpoint whose IPs rotate. Example that forced
the question — `api.sparkpost.com` resolves to **rotating AWS IPs on a 60 s TTL**: 18 unique
addresses across 18 different /16s in a 5-minute sample, spanning 34/8, 35/8, 44/8, 52/8, 54/8.
Pinning that by CIDR would mean tunnelling most of AWS us-west-2. A domain entry handles it.

**They had already drifted.** Confirmed 2026-08-05: `themyersbriggs.my.salesforce.com` and
`themyersbriggs.lightning.force.com` resolve to Salesforce Hyperforce `155.226.145.x`, which is in
**none** of the four pinned SFDC ranges (`96.43.144.0/20`, `136.146.0.0/15`, `182.50.76.0/22`,
`204.14.232.0/21`) — only `login.salesforce.com` still lands in `136.146.0.0/15`. Treat every
IP-pinned SaaS entry as suspect until re-resolved.

#### ⚠️ Domain entries did NOT tunnel — verify before trusting them

Added on AVS 2026-08-05 and **they did not work**. On the only client running the new config (macOS
26.6, GP 6.3.3-1105, reconnected immediately after the commit), the tunnel carried internal DNS and
Kerberos only — zero traffic to `*.adp.com` hosts. Client-side cause unresolved; suspect the macOS
network-extension path. **Do not remove a working `access-route` CIDR on the assumption its domain
equivalent covers it.** Prove the domain rule first, on a client that has actually reconnected.

#### The verification trap: clients cache the pushed config

**GP clients keep their split-tunnel config until they reconnect.** After the CIDRs were removed,
other users' Salesforce/ADP traffic kept tunneling — which looked like proof the domain rules worked.
It was stale client config. Only sessions whose `login-time` is *after* the commit are valid test
subjects:

```bash
type=op cmd=<show><global-protect-gateway><current-user/></global-protect-gateway></show>
# read login-time per session; ignore anyone who hasn't reconnected since the commit
```

Confirm tunneling from the firewall side, not the app's behaviour — a page that loads may simply be
egressing locally. Look for the flow in the traffic log with `natsrc` = the GP egress
(`20.95.36.96` here):

```
type=log log-type=traffic query=(addr.src in 10.255.200.0/24) and (addr.dst in 170.146.0.0/16)
```

#### Deployed state — FLEET ALIGNED 2026-08-05 (AVS jobs 343–359, WH 626, FR 352, AU 352)

**All four sites now run one baseline: 11 `access-route` entries + `api.sparkpost.com`.** AVS carries a
12th entry, `10.201.0.0/22`, and that is the only difference anywhere in the fleet. Both HA peers match
at every site; `pending-changes` is `no` on all 8.

```
10.10.0.0/16   10.200.0.0/16      170.146.0.0/16     + AVS only: 10.201.0.0/22
10.30.0.0/16   13.216.79.214/32   172.31.255.0/24
10.50.240.0/22 54.165.9.173/32    192.168.192.0/19
10.70.0.0/16   54.243.189.17/32
```

AVS reached this over six commits (343 added 6 domain entries; 346 removed 19 CIDRs and broke ADP; 349
restored the Salesforce CIDRs and swapped the ADP slices for the `/16`; 353 tested exact ADP FQDNs; 356
removed all 4 Salesforce CIDRs; 359 dropped the ADP FQDNs and added `api.sparkpost.com`). WH/AU/FR were
then aligned to it in one `edit` + one `set` each. Salesforce is now entirely out of the split tunnel
fleet-wide, by IP and by domain, because the pins were stale and the domain rules don't tunnel.

**`10.201.0.0/22` is Azure/AVS break-glass and belongs on AVS only.** It has no route in any routing
table, which makes it look dead — it isn't. On AVS it is an address object `N-10.201.0.0_22` plus NAT
rule `TO_AZURE-AVS_NETS` (from `GLOBALPROTECT`+`TRUST` → `UNTRUST`, source-translated to
`10.200.255.253/30` on `ethernet1/1`), and AVS's default route uses that same interface, so the default
route *is* the Azure path. WH/AU/FR have **zero** references to `10.201.` anywhere and their default
routes point at local ISPs, so the same entry there would send RFC1918 to an ISP and look like
break-glass exists when it doesn't. Do not add it to close the fleet-consistency gap.

Full per-entry identification, restore blocks per site, and the ADP/Salesforce history are in
`task-tracker/projects/pan/pan-split-tunnel-review/README.md`.

**Removing the ADP CIDRs broke ADP Time & Attendance for ~20 minutes** (job 346, 15:40–15:59 EDT).
That module enforces an IP allowlist and otherwise returns *"Access denied… from a location that is
not authorized by your company."* It is the entire reason ADP is in the split tunnel. The four narrow
ranges **were working**; trading them for an unproven `*.adp.com` domain entry took the routes away
with nothing functional behind them.

**ADP needs the whole `/16`, not slices.** `170.146.0.0/16` is entirely ADP's own netblock
(`ADP-ESNET`, whois-verified), and it's a strict superset of the four ranges that worked. ADP's front
door `online.adp.com` (CNAME `oneline.gslb2.adp.com`) actively rotates — observed flipping `.93.123`
→ `.104.12` inside one 16-second sample — and both `time.adp.com` and `workforcenow.adp.com` are 301
redirects to it. A real post-fix session tunneled to `.102.193`, `.92.217`, `.93.123` and `.104.12`;
only the first was covered before. Verified working 15:59 EDT.

**PAN logs are EDT; Frank and his Mac are PDT.** Add 3 hours to a local screenshot/file timestamp
before comparing it to a firewall job or log time. Getting this backwards inverts before/after
conclusions. `<show><clock/></show>` returned empty on AVSPAN01, so use a log `receive_time` instead.

Removing an IP list is one `action=edit` on `$XP/access-route` with an `<access-route>` element
containing every member you want to survive — `edit` replaces the node, so include the keepers.
Capture the original members first and diff against them; the exact 19 removed here, plus per-entry
identification of the whole list, are in
`task-tracker/projects/pan/pan-split-tunnel-review/README.md`.

**Log retention will not tell you what's unused.** AVSPAN01 keeps only ~26 hours of traffic logs, so
a split tunnel entry showing zero hits is unproven, not dead. Don't propose removals from that.

**Caveats before changing this:** it affects every connected EMPLOYEES user (56 at time of
writing) and needs a commit. HA is active-passive and `running-sync: synchronized`, so a commit on
the active peer propagates — but verify both peers per the usual PAN discipline.

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

## Licensing / Subscription Renewals

### Check what's licensed and when it expires (API op — read-only)

```
type=op  cmd=<request><license><info></info></license></request>
```

Each `<entry>` carries `feature`, `expires`, `expired`, and `authcode` — so you can match an auth
code from a Palo Alto order confirmation straight against what the box actually has.

### Renewals do NOT need to be applied to the firewall

This is the big one. When a `PAN-*-R` (renewal) auth code arrives by email from
`ORDERS@PALOALTONETWORKS.COM`, **there is nothing to do on the device.** Palo Alto applies the
renewal to the CSP entitlement and the firewall picks up the new expiry on its own. The order PDF
says so explicitly: _"Subscription and support renewals do not need to be re-activated; therefore,
no further action is required."_ Same for converting an eval to production.

Do not run `request license fetch` or paste renewal codes into the GUI expecting to "activate"
them. Just verify with `request license info` that the expiry moved out.

New (non-renewal) subscriptions and hardware registrations DO require activation.

### Auth codes are issued per-serial

An order confirmation lists one auth code per serial per SKU. For an HA pair that means the codes
come in matched sets — 2 peers × 2 SKUs = 4 codes — and each code is bound to one serial. Always
map code → serial before assuming an order covers the pair; the serial column in
**Devices & Tokens** above is there for exactly this. Don't infer which site an order is for from
the site name, because the email/PDF only identifies devices by serial.

### Worked example — order 41062928 (FR pair, verified 2026-08-02)

Renewal of ATP + Premium support on the FR PA-220s, covering 08/04/2026 – 08/03/2027:

| Auth Code | Part Number | Serial | Device |
|-----------|-------------|--------|--------|
| 33930938 | PAN-PA-220-ATP-R | 012801036562 | FRPAN01 |
| 32594197 | PAN-SVC-PREM-220-R | 012801036562 | FRPAN01 |
| 31760800 | PAN-PA-220-ATP-R | 012801036206 | FRPAN02 |
| 61840664 | PAN-SVC-PREM-220-R | 012801036206 | FRPAN02 |

All four were already live on the devices with no action taken — `request license info` showed the
matching `authcode` values and Aug 04 2027 expiries. Confirms the renewal behavior above.

### Fleet expiry snapshot (verified 2026-08-02)

| Site | Features | Expires |
|------|----------|---------|
| AVS (both peers) | Adv Threat Prevention, PA-VM, Premium, Threat Prevention | Dec 25, 2026 |
| WH (both peers) | PAN-DB URL Filtering, Threat Prevention | Dec 29, 2026 |
| WH (both peers) | Premium | Nov 20, 2026 |
| AU (both peers) | PAN-DB URL Filtering, Premium, Threat Prevention | **Aug 4, 2026** |
| FR (both peers) | Adv URL Filtering, PAN-DB URL Filtering | Feb 5, 2027 |
| FR (both peers) | Adv Threat Prevention, Premium, Threat Prevention | Aug 4, 2027 |

Notes:
- **AU expired Aug 4 2026 — deliberately not renewed.** Confirmed with Frank 2026-08-03: the AU
  office shuts down later in 2026 and all AU licenses are being allowed to lapse. Do not open
  renewal tickets for AU. Its content/AV/URL-filtering are frozen as of that date; final content
  version is `9128-10169` (see below).
- **AU content is permanently stuck at 9128-10169** (Jul 23 2026) — the PAN-300055 disk bug blocked
  the `9131-10176` install and the fix needs a TAC root session, which expired with Premium support.
  Full write-up in `knowledge-base/procedures/pan-pa220-disk-cleanup.md`. This is a known accepted
  state, not something to re-investigate.
- **Checking versions on a PA-220 whose content is stuck:** `current=no` in
  `<request><content><upgrade><info/></upgrade></content></request>` means "not running", which
  includes newer downloaded-but-not-installed packages. Never feed that flag straight into a
  cleanup — see the warning in the disk-cleanup procedure.
- **FR URL Filtering (Feb 5 2027)** is on a different cycle than FR threat/support (Aug 4 2027).
  Two separate renewals per year for that site.
- WH shows an expired **Software warranty** (Feb 20, 2022). Cosmetic on a PA-460 under active
  Premium support; not a gap to chase.
- FR now carries **Advanced** Threat Prevention on both peers, not classic-only. Earlier notes
  claiming ATP is AVS-exclusive are out of date.

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
- Use **`task-tracker/projects/pan/pan-patching/pan-upgrade.sh`** for automated installs — polls until FIN before rebooting

### Upgrade order for HA pairs

1. Download on both peers in parallel (API)
2. Run `software check` on both to refresh list if versions aren't showing
3. Install + reboot passive peer first using `task-tracker/projects/pan/pan-patching/pan-upgrade.sh`; wait for it to return to passive HA state
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
- **Check `<check><pending-changes></pending-changes></check>` before committing.** A commit flushes
  the whole candidate config, so any half-finished work another admin left uncommitted ships with
  your change. Verify `no` first.
- PA-220 commits run **5–7 minutes** and sit at `progress=0%` for the first 2–4 of them. That is
  normal, not a hang. Poll with a >2 min tool timeout or the polling loop dies before the job does.

### HA pairs serialize commits — you cannot do both peers at once

Committing on one peer enqueues an **HA-Sync job on the other**, and while that runs the second peer
rejects config writes with:

```
<response status="error" code="13"><msg><line>A commit is pending. Please try again later.</line></msg></response>
```

On a PA-220 pair that HA-Sync took **~4.5 minutes** (observed AU, 2026-08-04). The sequence that
works:

1. Edit + commit peer A; poll to FIN.
2. Poll the **HA-Sync job that appears on peer B** to FIN (`show jobs all`, type `HA-Sync`).
3. Only then edit + commit peer B.

Budget ~15 minutes for a two-peer config change on PA-220s. Code 13 here is a retry-later, not a
permissions or syntax problem — don't go hunting for a template override.

### Verifying a committed change

`<show><config><running><xpath>…</xpath></running></config></show>` returns
`<msg><line>No such node</line></msg>` — that op does not accept an xpath filter this way, and the
error is about the command, **not** a missing setting. Don't read it as the change having vanished.

Verify instead with `type=config action=get` on the xpath plus a pending-changes check. Before a
commit the returned nodes carry `admin="…" dirtyId="1" time="…"` attributes; after a successful
commit those attributes are gone and `pending-changes` is `no`. Absent attributes + `no` = committed.

> ### ⚠️ The dirty-attribute grep trap — hit twice now
>
> Watch for those attributes when grepping. `grep -oE "<update-schedule>"` silently matches nothing
> once the tag becomes `<update-schedule admin="…" dirtyId="1">`. Match `<update-schedule[^>]*>`.
>
> **This applies to `<member>` too, and it bites hardest mid-change.** Verifying an uncommitted
> `access-route` edit with `grep -c '<member>'` returns **0** — not because the edit failed but because
> every member is now `<member admin="2fperez" dirtyId="4" time="…">`. It reads exactly like you just
> wiped a production list. (Happened 2026-08-05 during the GP split-tunnel cleanup.)
>
> Always parse attribute-tolerantly, and prefer diffing against a captured list over counting:
>
> ```bash
> routes() { curl -sk "https://$1/api/" --data-urlencode "type=config" --data-urlencode "action=get" \
>   --data-urlencode "key=$TOKEN" --data-urlencode "xpath=$XP/access-route" \
>   | grep -oE '<member[^>]*>[^<]+</member>' | sed -E 's/<member[^>]*>//;s#</member>##'; }
> ```
>
> The counts flip back to matching a plain `<member>` grep after commit, which is why this only ever
> shows up in pre-commit verification and looks like a disaster when it does.

## Dynamic Update Schedules

xpath: `/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/update-schedule`

Child nodes exist only for what's actually scheduled — typically `threats` and `anti-virus`. Nodes
for `wildfire` / `url-database` are absent when those aren't licensed.

```
type=config  action=get  xpath=<above>
```

Each node holds `<recurring><daily><at>HH:MM</at><action>download-and-install</action></daily></recurring>`.

### `update-schedule` is device-local — HA config sync does NOT carry it

Confirmed on the AU pair 2026-08-04: after a full HA-Sync completed from the peer that had been
changed, the other peer **still had its original schedule**. This is also why HA peers routinely show
different update times (AU ran 23:00/23:30 on one and 00:00/00:30 on the other for years).

Consequence: **you must set this explicitly on both peers.** Changing one and trusting HA sync leaves
the other still updating, silently.

### Disabling the schedules

Use the GUI-equivalent "None" recurrence rather than deleting the nodes — it keeps the structure, so
re-enabling is one `edit` per node instead of rebuilding.

```bash
XB="/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/update-schedule"
for node in threats anti-virus; do
  curl -sk "https://<host>/api/" \
    --data-urlencode "type=config" --data-urlencode "action=edit" \
    --data-urlencode "key=$TOKEN" \
    --data-urlencode "xpath=$XB/$node/recurring" \
    --data-urlencode "element=<recurring><none/></recurring>"
done
# then commit, and see the HA serialization note under Commit before doing the second peer
```

Use `action=edit` (replaces the node), not `action=set` — `recurring` is a choice node and a merge
can leave `daily` sitting alongside `none`.

Re-enable by editing the same xpath back to the `<daily>` form.

> **Do not take device config snapshots.** Frank does not want `<save><config><to>…</to></config></save>`
> restore points left on the firewalls (told 2026-08-05). Get safety from verifying `pending-changes`
> is `no`, building and reading back the **candidate** config, and rehearsing the reversal on the
> candidate before committing. Delete a stray one with
> `<delete><config><saved>FILE</saved></config></delete>`.

**Record the original `at` times per peer** before changing them — they differ between peers, so
you need the per-peer values written down to do a targeted re-enable.

### When to disable

Once a site's Threat Prevention / support licenses lapse, the schedules keep firing and failing
nightly, adding noise to the job log. Disabling is cleanup, not a functional change — it doesn't
touch traffic.

**Done on AU 2026-08-04** (both peers, licenses lapsed that day; commit jobs #310 / #308). Snapshot
`pre-disable-updates-20260804.xml` on each. Note that AU's content installs had been failing nightly
anyway (PAN-300055), while AV installs were still succeeding right up to the change.

AU pre-change values, for a targeted re-enable (both were `download-and-install`):

| Device | threats | anti-virus |
|--------|---------|------------|
| AUPAN01 | daily 23:00 | daily 23:30 |
| AUPAN02 | daily 00:00 | daily 00:30 |

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

## Reaching mgmt APIs from AWS (or any across-tunnel source)

The firewall **mgmt IPs are transit-reachable behind the TRUST zone** (via the core router), not directly on a dataplane interface — so a flow from a remote zone (e.g. `AWS-TMBC`) to a mgmt IP is a normal `<remote-zone> → TRUST` flow needing a security rule + routing. It is NOT an out-of-band dead end.

Diagnose (read-only):
- `test routing fib-lookup virtual-router DEFAULT ip <srcIP>` per firewall → does it have a **return route** to the source? (Only the hub that terminates the tunnel will, until you redistribute.)
- `test security-policy-match from <zone> to TRUST source <srcIP> destination <mgmtIP> protocol 6 destination-port 443` → empty `<result>` = no rule = implicit deny = silent drop/timeout.

Fix (verified 2026-07-23 for the AWS config-backup Lambda; hub `avspan01`):
1. Security rule at the **hub only** (spokes already trust hub-sourced traffic): `from <zone> to [TRUST + spoke zones]`, scoped address objects, service `service-https`.
2. Redistribute the source prefix into **OSPF** (redist-profile matching the dest prefix → ospf `export-rules` entry, `new-path-type ext-1`). Spokes are OSPF-adjacent to the hub and learn it as O1; this fixes the reply path for both hub-local and remote mgmt in one change.

Full writeup: `task-tracker/projects/pan-config-backup-aws/README.md`.
