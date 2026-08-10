# Windows DNS — Field Notes


> ## WARNING: `svcclaude`'s AD rights were dismantled 2026-07-27
>
> The account was **not deleted everywhere** — the picture is mixed, so read carefully:
>
> | Where | State |
> |---|---|
> | `cpp-db.com` | **Exists, but powerless** — zero group memberships, zero delegated ACEs, removed from local Administrators on ~26 machines. Retained *only* so vCenter and the PAN firewalls can authenticate it. |
> | `cpp-web.com`, `opp.local`, `oppashapp.local`, `oppnewapp.local` | **Deleted outright.** |
> | PAN-OS local account | ✅ **Still works** — firewalls have their own user database. Key auth verified 2026-08-02 (AVSPAN01, WHPAN01). |
> | vCenter login | Retained by design — but see the password note below. |
>
> **Its password was rotated 2026-07-27**, so `~/GitHub/.tokens/svcclaude` holds a stale value.
> That is why auth fails with `Permission denied` / `The user name or password is incorrect` —
> it reads like a simple bad password, but the rights are gone too. **Do not retry it or burn
> lockout budget on it.**
>
> **Use instead:**
> - **WinRM as `CPP-DB\2fperez`** — `Invoke-Command -ComputerName <fqdn> -ScriptBlock {...}`.
>   `2fperez` is a Domain Admin in cpp-db.com. The proven day-to-day path.
> - **Azure Key Vault `kv-tmbc-secrets`** — `~/GitHub/.tokens/kv-get.sh <secret>`. Account names
>   live in each secret's Azure **tags**. DA per domain: `ntsupport` (cpp-db.com, cpp-web.com),
>   `#domain` (opp.local, oppashapp.local, oppnewapp.local).
>
> The transport-level patterns below (sshpass on Windows, `-EncodedCommand`, NetBIOS-vs-UPN,
> loopback workarounds) remain correct — substitute a live account in the examples.
> Full detail: `api/ssh/README.md`.

Internal DNS updates via SSH + PowerShell DnsServer cmdlets.

## Setup Requirements

### On SVDCDC01
1. **OpenSSH Server** must be installed and running (`sshd` service) ✓
2. **Authenticate as the domain's Domain Admin** — `cpp-db\ntsupport`, KV secret
   `da-cpp-db-com`. A DA already holds DnsAdmins-equivalent rights *and* write access to the
   AD-integrated zone records, so steps 2–4 of the old svcclaude setup (DnsAdmins membership,
   key deployment, `grant-dns-acl.ps1`) are **no longer prerequisites**.
3. **`grant-dns-acl.ps1` is retained for reference only.** It granted the retired svcclaude
   delegation Full Control on all zones across the three AD partitions (DomainDnsZones,
   ForestDnsZones, System). Do not run it to re-delegate svcclaude.
   - `CNF:` entries (replication conflict objects) always fail with "bad syntax" — expected and
     harmless, ignore them.

### Verifying access
```bash
zsh -c '
ENCODED=$(printf "dnscmd SVDCDC01.cpp-db.com /enumzones" | iconv -t UTF-16LE | base64 | tr -d "\n")
ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes 'cpp-db\\ntsupport'@SVDCDC01.cpp-db.com \
  "powershell -NonInteractive -EncodedCommand $ENCODED"
'
```

## Credentials

- **Retrieve:** `PASS=$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com)` — bare password string, never
  written to disk. Swap the secret name for the target zone's domain (see the skill's zone table).
- **SSH user:** `cpp-db\ntsupport` (or `<domain>\#domain` for the OPP domains)
- **One auth attempt per account, never loop** — these are Domain Admins.

## Default Server

`SVDCDC01.cpp-db.com` — override with `DNS_SERVER=other-dc.cpp-db.com`

## Script

`dns-update.sh` — wraps common DnsServer cmdlet operations.

| Operation | What it does |
|-----------|-------------|
| `add-cname` | Add a new CNAME record |
| `update-cname` | Update an existing CNAME's target (get/clone/set pattern) |
| `add-a` | Add a new A record |
| `update-a` | Update an existing A record's IP |
| `delete` | Delete a record (pass record type as target arg) |

TTL defaults to 3600 if not specified. Pass `0` to inherit zone default.

## How the Script Works

PowerShell commands are encoded as UTF-16LE base64 and passed via `-EncodedCommand` to avoid shell quoting conflicts between zsh and PowerShell.

## Update Pattern (get/clone/set)

Windows DNS requires the old record object for updates — you can't just overwrite by name. The pattern:
```powershell
$old = Get-DnsServerResourceRecord -ZoneName 'zone' -Name 'host' -RRType CName
$new = $old.Clone()
$new.RecordData.HostNameAlias = 'newtarget.com.'   # trailing dot required
Set-DnsServerResourceRecord -ZoneName 'zone' -OldInputObject $old -NewInputObject $new
```

## CNAME Target Trailing Dot

CNAME targets must be fully-qualified (trailing dot). The script appends it automatically if missing.

## Zones

Any zone hosted on the DNS server. Frank specifies the zone at request time. Common zones:
- `themyersbriggs.com`
- `cpp-db.com`

## Known Servers

| Server | Hostname | Notes |
|--------|----------|-------|
| Primary DC | SVDCDC01.cpp-db.com | Default |

## ⚠ These DCs also serve PUBLIC zones, which breaks public-record audits

Several public zones are **split-horizon** — served publicly by Cloudflare and internally by these
DCs. From a domain-joined Mac the system resolver answers from the *inside* view, so a public-record
audit silently reads the wrong zone.

Verified 2026-07-31: `dig +short NS opp.co.uk` returned `mkpdvdmc01.opp.local` /
`mkpdvdmc02.opp.local`. Probing "the authoritative NS" then reported
`_dmarc.assessment.opp.co.uk` as absent while Cloudflare plainly had the record.
`themyersbriggs.co` was unaffected — its `dig NS` returns Cloudflare — so **the failure is silent
and per-zone**, and you cannot assume it away.

**How to apply:** for any public DNS question, take the authoritative NS from the Cloudflare zone
object (`GET /zones?name=<zone>` → `name_servers[]`), never from `dig NS` against the system
resolver, and cross-check with `@1.1.1.1` / `@8.8.8.8`. Full set of answer-reading traps (wildcard
occlusion, chunked TXT, DKIM selector enumeration) is in `../cloudflare/README.md` under
**Reading DNS answers**.

Related: internal reverse zones are **/16-scoped and partial**, so an authoritative NXDOMAIN from
one domain's DCs is not evidence the record doesn't exist — the 10.x subnets are shared between
cpp-db.com and opp.local, each hosting only its own records. Query each domain's DNS in turn.
